#[compute]
#version 450

// Generates ONE cell of the streamed cloud grid into its slot of an atlas (R16F).
// With a gutter, each slot is (res + 2) texels wide: a one-texel border holds the neighbouring cells' values (the
// same noise field sampled just outside the cell), so linear filtering across a cell border is seamless.
//
// Every cell samples the SAME infinite noise field at its own world coordinates (cell index + position
// inside the cell). Neighbouring cells therefore agree exactly along their shared border and the clouds
// never repeat. (A different random seed per cell would cut the clouds off at every border.)
//
// Four weather channels drive the look:
//   coverage  where clouds are (and how empty the gaps are)
//   type      0 = flat stratus sheets, 0.5 = cumulus, 1 = tall towering clouds with flat tops
//   scale     0 = big billows, 1 = small puffs
//   height    how high the cloud TOPS reach: from very low to very high
// An override cell replaces the procedural channels with painted textures (R = coverage, G = type,
// B = scale; height map R = height) that cover the cell exactly, blending back to the procedural field
// within `blend margin` of the cell edge so authored cells do not seam against their neighbours.
//
// Optional shape modifiers (misc yzw, packed because push constants are limited to 128 bytes):
//   warping  the shape noise (and optionally the coverage) is sampled at positions pushed around by another,
//            smooth noise: swirled, torn shapes instead of round blobs. Everything stays a function of world
//            position, so cells still match seamlessly.
//   anvils   towering clouds spread outward and flatten near their tops, like thunderheads.
//
// Texture axes of the atlas: x = world X, y = world Z, z = height through the slab (0..1).
// Work is issued a few Z slices per frame (first slice in extent.w) so it never stalls the GPU.

#include "./cloud_noise.comp"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;

layout(r16f, set = 0, binding = 0) uniform restrict writeonly image3D out_density;
layout(set = 0, binding = 1) uniform sampler2D weather_tex;
layout(set = 0, binding = 2) uniform sampler2D height_tex;

const int NOISE_WRAP = 4096;   // the noise only repeats after this many cells (tens of thousands of km)

layout(push_constant, std430) uniform Params {
	vec4 cell;        // xy = cell index wrapped to 0..4095, zw = atlas slot of this cell
	vec4 shape;       // x = coverage bias, y = base cells per cell, z = coverage cells per cell, w = coverage softness
	vec4 extent;      // x = cell size (m), y = slab thickness (m), z = override blend margin (0..0.5), w = first Z slice
	vec4 weather_a;   // x = type cells, y = scale cells, z = type bias, w = type variation
	vec4 weather_b;   // x = scale bias, y = scale variation, z = use weather map (0/1), w = seed
	vec4 height_a;    // x = height cells, y = height bias, z = height variation, w = height influence
	vec4 height_b;    // x = top roughness, y = height contrast, z = use height map (0/1), w = texels per cell
	vec4 misc;        // x = gutter texels on each side (0 or 1)
	                  // y = warp strength (0 = off)
	                  // z = warp cells per cell (integer part) + warp coverage * 0.99 (fraction)
	                  // w = 0 = anvils off, else anvil height in % of the cloud (integer part) + strength * 0.99 (fraction)
} pc;

float spread(float v) {
	// fbm values cluster around 0.5; stretch them so the channel actually varies across the map
	return clamp((v - 0.5) * 2.5 + 0.5, 0.0, 1.0);
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	id.z += int(pc.extent.w);
	ivec3 atlas = imageSize(out_density);
	int pad = int(pc.misc.x + 0.5);
	int res = int(pc.height_b.w + 0.5);
	int stride = res + 2 * pad;
	if (id.x >= stride || id.y >= stride || id.z >= atlas.z) {
		return;
	}
	ivec3 texel = ivec3(ivec2(pc.cell.zw) * stride + id.xy, id.z);

	uint seed = uint(pc.weather_b.w);
	vec2 f = (vec2(id.xy) - float(pad) + 0.5) / float(res);   // position inside the cell, 0..1 (slightly outside in the gutter)
	float h = (float(id.z) + 0.5) / float(atlas.z);    // height through the slab, 0..1
	vec2 pos = pc.cell.xy + f;                         // position in cell units (index wrapped, so values stay small)

	int base_cells = int(pc.shape.y);
	int cov_cells = int(pc.shape.z);
	int type_cells = int(pc.weather_a.x);
	int scale_cells = int(pc.weather_a.y);
	int height_cells = int(pc.height_a.x);
	float aspect = pc.extent.y / pc.extent.x;          // keeps noise features roughly isotropic in metres

	// Override blend weight: 0 at the cell edge (fully procedural), 1 past the blend margin (fully painted).
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float bw = pc.extent.z > 0.0 ? smoothstep(0.0, pc.extent.z, edge) : 1.0;
	if (edge < 0.0) {
		bw = 0.0;   // gutter texels: the neighbouring cell's field, not this cell's painted map
	}
	vec2 fm = clamp(f, 0.0, 1.0);

	// ---- domain warp: a smooth 3-channel noise that pushes the sample positions around
	float warp_amt = pc.misc.y;
	vec3 wn = vec3(0.0);
	float warp_cov = 0.0;
	if (warp_amt > 0.0) {
		int warp_cells = max(int(floor(pc.misc.z)), 1);
		warp_cov = clamp(fract(pc.misc.z) / 0.99, 0.0, 1.0);
		int wper = warp_cells * NOISE_WRAP;
		vec3 wp = vec3(pos * float(warp_cells), h * float(warp_cells) * aspect);
		wn = vec3(
			fbm_gradient(wp + vec3(0.0, 0.0, 31.7), wper, 3, seed + 503u),
			fbm_gradient(wp + vec3(0.0, 0.0, 57.3), wper, 3, seed + 601u),
			fbm_gradient(wp + vec3(0.0, 0.0, 83.9), wper, 3, seed + 709u));
		wn = clamp((wn - 0.5) * 2.5, -1.0, 1.0);   // roughly -1..1
	}

	// ---- weather channels (procedural, optionally replaced by painted maps)
	// coverage warp is measured in coverage features, so the same setting means the same at any coverage_cells
	vec2 cpos = pos + wn.xy * (warp_amt * warp_cov / float(max(cov_cells, 1)));
	float cov_noise = fbm_gradient(vec3(cpos * float(cov_cells), 3.7), cov_cells * NOISE_WRAP, 3, seed + 101u);
	float tn = spread(fbm_gradient(vec3(pos * float(type_cells), 9.1), type_cells * NOISE_WRAP, 2, seed + 211u));
	float sn = spread(fbm_gradient(vec3(pos * float(scale_cells), 5.3), scale_cells * NOISE_WRAP, 2, seed + 307u));
	float type_v = clamp(pc.weather_a.z + (tn - 0.5) * 2.0 * pc.weather_a.w, 0.0, 1.0);
	float scale_v = clamp(pc.weather_b.x + (sn - 0.5) * 2.0 * pc.weather_b.y, 0.0, 1.0);
	if (pc.weather_b.z > 0.5) {
		vec3 wm = textureLod(weather_tex, fm, 0.0).rgb;
		cov_noise = mix(cov_noise, wm.r, bw);
		type_v = mix(type_v, wm.g, bw);
		scale_v = mix(scale_v, wm.b, bw);
	}
	cov_noise += (pc.shape.x - 0.5) * 0.8;
	float soft = max(pc.shape.w, 0.01);
	float cover = smoothstep(0.5 - soft, 0.5 + soft, cov_noise);

	// ---- height channel: how high this column's cloud top reaches (0 very low .. 1 very high)
	float hn = fbm_gradient(vec3(pos * float(height_cells), 13.7), height_cells * NOISE_WRAP, 4, seed + 401u);
	float stretched = clamp((hn - 0.5) * pc.height_b.y + 0.5, 0.0, 1.0);
	float height_v = clamp(pc.height_a.y + (stretched - 0.5) * 2.0 * pc.height_a.z, 0.0, 1.0);
	if (pc.height_b.z > 0.5) {
		float hm = textureLod(height_tex, fm, 0.0).r;
		float painted = clamp(pc.height_a.y + (hm - 0.5) * 2.0 * pc.height_a.z, 0.0, 1.0);
		height_v = mix(height_v, painted, bw);
	}

	// ---- shape noise: two feature sizes blended by the scale channel
	// shape warp is measured in base-noise features: warp strength 1 = pushed up to about one feature width
	vec2 spos = pos + wn.xy * (warp_amt / float(max(base_cells, 1)));
	vec3 sp = vec3(spos * float(base_cells), h * float(base_cells) * aspect + wn.z * warp_amt * 0.5 + 11.3);
	float g_big = fbm_gradient(sp, base_cells * NOISE_WRAP, 4, seed);
	float g_small = fbm_gradient(sp * 2.0, base_cells * 2 * NOISE_WRAP, 4, seed + 17u);
	float w_big = fbm_worley(sp, base_cells * NOISE_WRAP, 2, seed + 53u);
	float w_small = fbm_worley(sp * 2.0, base_cells * 2 * NOISE_WRAP, 2, seed + 71u);
	float g = mix(g_big, g_small, scale_v);
	float w = mix(w_big, w_small, scale_v);
	float pw = clamp(remap(g, 0.0, 1.0, w, 1.0), 0.0, 1.0);

	// ---- cloud top height: the type's own profile, overridden by the height channel, then billowed
	float t = type_v;
	float top_cu = mix(0.35, 1.0, cover);
	float top_type = t < 0.5 ? mix(0.28, top_cu, t * 2.0) : mix(top_cu, 1.0, (t - 0.5) * 2.0);
	float top_height = mix(0.10, 0.92, height_v);
	float top = mix(top_type, top_height, pc.height_a.w);
	// anvils: only towering types get one; a_col = how much this column's cloud spreads out at the top
	float a_col = 0.0;
	float anvil_h = 0.25;
	if (pc.misc.w > 0.5) {
		anvil_h = clamp(floor(pc.misc.w) / 100.0, 0.02, 0.9);
		a_col = clamp(fract(pc.misc.w) / 0.99, 0.0, 1.0) * smoothstep(0.6, 0.9, t);
	}
	top += (g - 0.5) * 3.0 * pc.height_b.x * (1.0 - 0.8 * a_col);   // anvils have flat tops
	top = clamp(top, 0.06, 0.97);

	float top_soft = t < 0.5 ? mix(0.15, 0.30, t * 2.0) : mix(0.30, 0.12, (t - 0.5) * 2.0);
	top_soft *= mix(1.0, 0.4, a_col);
	top_soft = min(top_soft, top * 0.8);
	float hprof = smoothstep(0.0, 0.12, h) * (1.0 - smoothstep(top - top_soft, top, h));

	// Within the top anvil_h of the cloud, coverage grows outward (in noise space, so it follows the tower's
	// outline) and the column below stays as it was: a mushroom / thunderhead silhouette.
	float rel_h = h / max(top, 1e-3);
	float anvil_w = a_col * smoothstep(1.0 - anvil_h, 1.0 - anvil_h * 0.5, rel_h);
	if (anvil_w > 0.0) {
		float spread_cov = smoothstep(0.5 - soft, 0.5 + soft, cov_noise + anvil_w * 0.12);
		cover = max(cover, spread_cov);
	}

	// ---- density
	float d = pw * hprof * mix(0.6, 1.0, cover);
	float thresh = mix(0.62, 0.30, cover);
	thresh = mix(thresh, thresh * 0.7, 1.0 - smoothstep(0.0, 0.5, t));   // stratus: fuller sheets
	float gain = mix(1.0, 1.25, smoothstep(0.5, 1.0, t));                // towering: denser cores
	d = clamp((d * gain - thresh) / (1.0 - thresh), 0.0, 1.0);
	d *= smoothstep(0.02, 0.15, cover);

	imageStore(out_density, texel, vec4(d));
}
