#[compute]
#version 450

// Low-resolution raymarch of the baked static cloud volume.
// Outputs:
//   out_cloud: premultiplied cloud colour + alpha for the ray (up to the opaque scene surface)
//   out_data : x = scene distance, y = first cloud distance, z = last cloud distance,
//              w = 1 if the ray was cut short by scene geometry inside the cloud range
// The composite uses out_data to work out how much cloud lies in front of ANY surface depth,
// so meshes inside or behind clouds are obscured correctly.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "./cloud_common.comp"

layout(set = 0, binding = 1) uniform sampler2D depth_tex;
layout(set = 0, binding = 4) uniform sampler3D detail_tex;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image2D out_cloud;
layout(rgba32f, set = 0, binding = 6) uniform restrict writeonly image2D out_data;

// Light atlases, one per ring level (see cloud_common.comp for the density ones).
layout(set = 0, binding = 12) uniform sampler3D light_l0;
layout(set = 0, binding = 13) uniform sampler3D light_l1;
layout(set = 0, binding = 14) uniform sampler3D light_l2;
layout(set = 0, binding = 15) uniform sampler3D light_l3;

vec4 light_lv(int lv, vec3 uvw) {
	if (lv == 0) {
		return textureLod(light_l0, uvw, 0.0);
	}
	if (lv == 1) {
		return textureLod(light_l1, uvw, 0.0);
	}
	if (lv == 2) {
		return textureLod(light_l2, uvw, 0.0);
	}
	return textureLod(light_l3, uvw, 0.0);
}

vec4 grid_light(GridHit g) {
	vec4 l = light_lv(int(g.l_a.w + 0.5), g.l_a.xyz);
	if (g.w > 0.0) {
		l = mix(l, light_lv(int(g.l_b.w + 0.5), g.l_b.xyz), g.w);
	}
	return l;
}

const float DENSITY_EPS = 0.002;

float ign(vec2 p, float frame) {
	p += frame * 5.588238;
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// Henyey-Greenstein with the 4*PI factor removed (isotropic == 1.0).
float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5);
}

float sample_density(GridHit g, vec3 world_pos, float t) {
	if (!g.ok || g.h < 0.0 || g.h > 1.0) {
		return 0.0;
	}
	float d = apply_effectors(world_pos, grid_density(g));
	if (d > 0.0 && u.detail.y > 0.0) {
		float fade = 1.0 - smoothstep(u.detail.z, u.detail.w, t);
		if (fade > 0.0) {
			float n = textureLod(detail_tex, (world_pos + u.detail_off.xyz) / u.detail.x, 0.0).r;
			float erode = (1.0 - n) * u.detail.y * fade;
			d = clamp((d - erode) / max(1.0 - erode, 0.001), 0.0, 1.0);
		}
	}
	return d * distance_fade(t);
}

// Density without the fine detail erosion (cheap): used for light visibility.
float base_density(vec3 world_pos) {
	GridHit g = grid_tex(world_pos);
	if (!g.ok || g.h < 0.0 || g.h > 1.0) {
		return 0.0;
	}
	return apply_effectors(world_pos, grid_density(g));
}

// Light arriving at a point inside the cloud from the (up to 6) point lights: lightning, weapon fire...
// Each light is attenuated by distance and by a 3-sample estimate of the cloud between it and the point.
vec3 light_in_cloud(vec3 pos) {
	int n = int(u.counts.y);
	vec3 sum = vec3(0.0);
	for (int i = 0; i < n; i++) {
		vec4 lp = u.light_pos[i];
		vec3 to_light = lp.xyz - pos;
		float dist = length(to_light);
		if (dist > lp.w) {
			continue;
		}
		float win = 1.0 - (dist * dist) / (lp.w * lp.w);
		win *= win;
		float core = max(u.light_col[i].a, 1.0);
		float att = win / (1.0 + (dist * dist) / (core * core));

		float seg = dist / 3.0;
		float od = 0.0;
		for (int k = 0; k < 3; k++) {
			od += base_density(pos + to_light * ((float(k) + 0.5) / 3.0)) * seg;
		}
		od *= u.vol_extent.w;
		// part direct, part diffused, so a flash deep in a cloud still lights its surroundings
		float vis = 0.5 * exp(-od) + 0.5 * exp(-od * 0.25);
		sum += u.light_col[i].rgb * att * vis;
	}
	return sum;
}

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 low_size = ivec2(u.view.xy);
	if (any(greaterThanEqual(id, low_size))) {
		return;
	}

	vec2 uv = (vec2(id) + 0.5) / u.view.xy;
	ivec2 full_size = ivec2(u.misc.xy);
	ivec2 full_id = clamp(ivec2(uv * u.misc.xy), ivec2(0), full_size - ivec2(1));
	float scene_dist = scene_distance(uv, texelFetch(depth_tex, full_id, 0).r);

	vec3 ro = u.cam_to_world[3].xyz;
	vec3 rd = view_dir_world(uv);

	// Intersect the ray with the cloud slab.
	float y0 = u.vol_origin.y;
	float y1 = y0 + u.vol_extent.y;
	float t0 = 0.0;
	float t1_slab = u.march.w;
	bool hit = true;
	if (abs(rd.y) < 1e-5) {
		hit = ro.y >= y0 && ro.y <= y1;
	} else {
		float ta = (y0 - ro.y) / rd.y;
		float tb = (y1 - ro.y) / rd.y;
		t0 = max(0.0, min(ta, tb));
		t1_slab = min(t1_slab, max(ta, tb));
		hit = t1_slab > t0;
	}
	bool clipped = scene_dist < t1_slab;
	float t1 = min(t1_slab, scene_dist);
	hit = hit && t1 > t0;

	if (!hit) {
		imageStore(out_cloud, id, vec4(0.0));
		imageStore(out_data, id, vec4(scene_dist, 0.0, 0.0, clipped ? 1.0 : 0.0));
		return;
	}

	float jitter = ign(vec2(id), u.view.z) * u.misc.w;
	float t = t0 + jitter * u.march.y * (1.0 + t0 * u.march.z);

	float cos_t = dot(rd, normalize(u.sun_dir.xyz));
	float phase = mix(hg(cos_t, u.look.x), hg(cos_t, u.look.y), u.look.z);

	// Multiple scattering (Wrenninge-style octaves, as in Frostbite / Nubis). Octave n treats the light as having
	// scattered n extra times: it is attenuated less (a^n), contributes less (b^n) and is less directional (c^n).
	// The phase only depends on the view/sun angle, so every octave's phase is worked out once per pixel here.
	int ms_octaves = int(u.counts.z + 0.5);
	float ms_a = u.counts.w;
	float ms_b = u.march2.z;
	float ms_c = u.march2.w;
	float ms_phase[4] = float[4](phase, 1.0, 1.0, 1.0);
	{
		float c = ms_c;
		for (int o = 1; o < 4; o++) {
			ms_phase[o] = mix(hg(cos_t, u.look.x * c), hg(cos_t, u.look.y * c), u.look.z);
			c *= ms_c;
		}
	}

	vec3 col = vec3(0.0);
	float trans = 1.0;
	float dist_acc = 0.0;
	float w_acc = 0.0;
	float front = -1.0;
	float back = 0.0;
	int max_steps = int(u.march.x);

	bool inside = false;     // currently marching through cloud with the fine in-cloud step
	bool refining = false;   // backed up after an empty-space overshoot; creeping forward to find the surface
	float refine_end = 0.0;
	float last_step = 0.0;

	for (int i = 0; i < max_steps; i++) {
		if (t >= t1) {
			break;
		}
		vec3 pos = ro + rd * t;
		float big = min(u.march.y * (1.0 + t * u.march.z), 500.0);
		big = effector_step_cap(pos, big);
		float fine = min(max(big / 6.0, 2.0), u.march2.x);

		GridHit g = grid_tex(pos);
		float d = sample_density(g, pos, t);

		if (d > DENSITY_EPS) {
			if (!inside && !refining && last_step > u.march2.x) {
				// A large empty-space step landed inside cloud: go back and approach the surface in small steps.
				refine_end = t;
				t -= last_step;
				refining = true;
				last_step = 0.0;
				continue;
			}
			inside = true;
			refining = false;
		} else {
			inside = false;
		}

		float step_len = refining ? fine : (inside ? min(big, u.march2.x) : big);
		step_len = min(step_len, t1 - t + 0.01);

		if (d > DENSITY_EPS) {
			float ext = d * u.vol_extent.w;
			float step_t = exp(-ext * step_len);

			vec4 L = grid_light(g);
			float h = clamp(g.h, 0.0, 1.0);
			float powder = 1.0 - exp(-d * 4.0);
			float od_sun = L.g;
			float sun_e;
			if (ms_octaves <= 0) {
				sun_e = L.r * phase + exp(-od_sun * 0.25) * 0.35;   // the original single-lobe approximation
			} else {
				sun_e = 0.0;
				float a = 1.0;
				float b = 1.0;
				for (int o = 0; o < 4; o++) {
					if (o >= ms_octaves) {
						break;
					}
					sun_e += b * exp(-od_sun * a) * ms_phase[o];
					a *= ms_a;
					b *= ms_b;
				}
			}
			vec3 sun = u.sun_color.rgb * sun_e * mix(1.0, powder, u.look.w);
			vec3 amb = mix(u.ground_ambient.rgb, u.sky_ambient.rgb, h) * L.b;
			vec3 lights = light_in_cloud(pos);

			float contrib = trans * (1.0 - step_t);
			col += (sun + amb + lights) * contrib;
			dist_acc += t * contrib;
			w_acc += contrib;
			if (front < 0.0) {
				front = t;
			}
			back = min(t + step_len, t1);
			trans *= step_t;
			if (trans < 0.01) {
				trans = 0.0;
				break;
			}
		}

		t += step_len;
		last_step = step_len;
		if (refining && t >= refine_end) {
			refining = false;
		}
	}

	float alpha = 1.0 - trans;
	float hit_dist = w_acc > 0.0 ? dist_acc / w_acc : 0.0;
	float fog_mix = 1.0 - exp(-hit_dist * u.fog_color.a);
	col = mix(col, u.fog_color.rgb * alpha, fog_mix);

	imageStore(out_cloud, id, vec4(col, alpha));
	imageStore(out_data, id, vec4(scene_dist, max(front, 0.0), back, clipped ? 1.0 : 0.0));
}
