#[compute]
#version 450

// Edge-aware denoise of the low-res cloud buffer (a-trous style 3x3 tent filter, run in several
// passes with a doubling tap offset). Taps only contribute if they sit on a similar cloud surface
// and scene surface, so silhouettes are not smeared.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src_cloud;
layout(set = 0, binding = 1) uniform sampler2D data_tex;   // x scene dist, y front, z back, w clipped
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D dst_cloud;

layout(push_constant, std430) uniform Params {
	vec4 a;  // xy = low-res size, z = tap offset (texels), w = edge sharpness
} pc;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(pc.a.xy);
	if (any(greaterThanEqual(id, size))) {
		return;
	}
	int off = int(pc.a.z);
	vec4 c0 = texelFetch(src_cloud, id, 0);
	vec4 d0 = texelFetch(data_tex, id, 0);

	vec4 accum = c0 * 4.0;
	float wsum = 4.0;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			if (dx == 0 && dy == 0) {
				continue;
			}
			ivec2 tap = clamp(id + ivec2(dx, dy) * off, ivec2(0), size - ivec2(1));
			float kw = (dx == 0 || dy == 0) ? 2.0 : 1.0;
			vec4 c = texelFetch(src_cloud, tap, 0);
			vec4 d = texelFetch(data_tex, tap, 0);
			float rel_front = abs(d.y - d0.y) / max(min(d.y, d0.y), 50.0);
			float rel_scene = abs(d.x - d0.x) / max(min(d.x, d0.x), 1.0);
			float s = exp2(-min(rel_front + rel_scene, 4.0) * pc.a.w);
			accum += c * kw * s;
			wsum += kw * s;
		}
	}
	imageStore(dst_cloud, id, accum / wsum);
}
