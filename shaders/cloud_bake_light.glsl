#[compute]
#version 450

// Bakes lighting for ONE cell version (one slot of one ring level's light atlas):
//   R = sun transmittance            exp(-opticalDepth toward sun)
//   G = optical depth toward sun     (raw, unitless; the march turns it into several multiple-scattering octaves)
//   B = sky visibility               mean transmittance over a few upward directions
// The rays travel through the whole loaded block, looking each position up in the cell table (the density of
// whatever ring level the neighbouring cell currently has), so shadows cross cell borders. Beyond the block, or
// in a cell with no density yet, the sky is treated as clear.
//
// Work can be split into Z-slice chunks (cell.w = first slice). A "sun only" re-bake (steps.z = 1) keeps the
// stored sky visibility and only recomputes R and G, at about half the cost: used when the sun moves.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;

#define CLOUD_NO_SCENE
#include "./cloud_common.comp"

layout(rgba16f, set = 0, binding = 1) uniform restrict image3D out_light;

layout(push_constant, std430) uniform Params {
	vec4 cell;    // xy = position of this cell in the block (cells from its minimum corner), z = texels per cell, w = first Z slice
	vec4 slot;    // xy = slot (column, row) in the light atlas, z = sun steps, w = ambient steps
	vec4 sun;     // xyz = direction TOWARD the sun (world), w = extinction (per metre)
	vec4 steps;   // x = sun step length (m), y = ambient step length (m), z = 1 for a sun-only re-bake
} pc;

// gp = position in the block in cells, h = height 0..1
float optical_depth(vec2 gp, float h, vec3 dir_world, float step_len, int steps) {
	float n = u.grid_a.w;
	vec2 dg = dir_world.xz * step_len / u.grid_a.z;
	float dh = dir_world.y * step_len / u.vol_extent.y;
	float od = 0.0;
	for (int i = 1; i <= steps; i++) {
		float fi = float(i) - 0.5;
		vec2 q = gp + dg * fi;
		float qh = h + dh * fi;
		if (qh < 0.0 || qh > 1.0) {
			break; // left the slab
		}
		if (q.x < 0.0 || q.y < 0.0 || q.x >= n || q.y >= n) {
			break; // left the loaded block
		}
		ivec2 c = ivec2(floor(q));
		vec4 e = u.cell_c[c.y * int(n) + c.x];
		if (e.w < 0.5) {
			continue; // that cell has no density yet
		}
		int lv = int(e.x + 0.5);
		od += density_lv(lv, atlas_uvw(u.lvl_d[lv], e.yz, q - vec2(c), qh));
	}
	return od * step_len * pc.sun.w;
}

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	id.z += int(pc.cell.w + 0.5);
	ivec3 atlas = imageSize(out_light);
	int res = int(pc.cell.z + 0.5);
	int stride = res + 2;
	if (id.x >= stride || id.y >= stride || id.z >= atlas.z) {
		return;
	}
	ivec3 texel = ivec3(ivec2(pc.slot.xy) * stride + id.xy, id.z);
	vec2 f = (vec2(id.xy) - 1.0 + 0.5) / float(res);   // slightly outside 0..1 in the gutter
	float h = (float(id.z) + 0.5) / float(atlas.z);
	vec2 gp = pc.cell.xy + f;

	float od_sun = optical_depth(gp, h, normalize(pc.sun.xyz), pc.steps.x, int(pc.slot.z));
	float t_sun = exp(-od_sun);

	if (pc.steps.z > 0.5) {
		// sun moved: sky visibility does not depend on the sun, so keep it
		float keep_vis = imageLoad(out_light, texel).b;
		imageStore(out_light, texel, vec4(t_sun, min(od_sun, 60000.0), keep_vis, 1.0));
		return;
	}

	vec3 dirs[5] = vec3[5](
		vec3(0.0, 1.0, 0.0),
		normalize(vec3(1.0, 1.0, 0.0)),
		normalize(vec3(-1.0, 1.0, 0.0)),
		normalize(vec3(0.0, 1.0, 1.0)),
		normalize(vec3(0.0, 1.0, -1.0)));
	float vis = 0.0;
	for (int i = 0; i < 5; i++) {
		vis += exp(-optical_depth(gp, h, dirs[i], pc.steps.y, int(pc.slot.w)));
	}
	vis /= 5.0;

	imageStore(out_light, texel, vec4(t_sun, min(od_sun, 60000.0), vis, 1.0));
}
