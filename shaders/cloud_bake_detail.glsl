#[compute]
#version 450

// Small tileable worley fbm used at render time to erode cloud edges.

#include "./cloud_noise.comp"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 4) in;

layout(r8, set = 0, binding = 0) uniform restrict writeonly image3D out_detail;

layout(push_constant, std430) uniform Params {
	vec4 size_seed;   // xyz = texture size, w = seed
	vec4 cells;       // x = cells per tile
} pc;

void main() {
	ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = ivec3(pc.size_seed.xyz);
	if (any(greaterThanEqual(id, size))) {
		return;
	}
	int cells = int(pc.cells.x);
	vec3 p = (vec3(id) + 0.5) / vec3(size) * float(cells);

	// Unlike the base volume, the detail texture wraps in all three axes.
	float n = 0.0;
	float amp = 0.5, norm = 0.0;
	int period = cells;
	vec3 q = p;
	for (int o = 0; o < 3; o++) {
		n += amp * worley_noise(q, ivec3(period), uint(pc.size_seed.w) + uint(o) * 13u);
		norm += amp;
		amp *= 0.5;
		q *= 2.0;
		period *= 2;
	}
	n /= norm;
	imageStore(out_detail, id, vec4(clamp(n * 1.25 - 0.1, 0.0, 1.0)));
}
