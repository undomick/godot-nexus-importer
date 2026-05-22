// Nexus B2G shared shader include.
#define NEXUS_CURVE_TEX_WIDTH 256.0
#define NEXUS_CURVE_TEX_LAST_IDX (255)

float nexus_curve_tex_lookup(float at, sampler2D curve_tex, bool extrapolate) {
	int table_size = int(NEXUS_CURVE_TEX_WIDTH);
	if (extrapolate && (at < 0.0 || at > 1.0)) {
		float t0;
		float dy;
		float f = at;
		if (f < 0.0) {
			t0 = texelFetch(curve_tex, ivec2(0, 0), 0).r;
			dy = t0 - texelFetch(curve_tex, ivec2(1, 0), 0).r;
			f = -f;
		} else {
			t0 = texelFetch(curve_tex, ivec2(NEXUS_CURVE_TEX_LAST_IDX, 0), 0).r;
			dy = t0 - texelFetch(curve_tex, ivec2(NEXUS_CURVE_TEX_LAST_IDX - 1, 0), 0).r;
			f = f - 1.0;
		}
		return t0 + dy * f * (NEXUS_CURVE_TEX_WIDTH - 1.0);
	}
	float ff = clamp(at, 0.0, 1.0) * (NEXUS_CURVE_TEX_WIDTH - 1.0);
	int i = int(ff);
	if (i < 0) {
		i = 0;
	}
	if (i >= table_size) {
		i = table_size - 1;
	}
	float t = ff - float(i);
	float result = texelFetch(curve_tex, ivec2(i, 0), 0).r;
	if (t > 0.0 && i + 1 < table_size) {
		result = mix(result, texelFetch(curve_tex, ivec2(i + 1, 0), 0).r, t);
	}
	return result;
}

float nexus_curve_xyz_channel(float at, sampler2D curve_xyz, int channel, bool extrapolate) {
	int table_size = int(NEXUS_CURVE_TEX_WIDTH);
	if (extrapolate && (at < 0.0 || at > 1.0)) {
		float t0;
		float dy;
		float f = at;
		if (f < 0.0) {
			vec4 s0 = texelFetch(curve_xyz, ivec2(0, 0), 0);
			vec4 s1 = texelFetch(curve_xyz, ivec2(1, 0), 0);
			if (channel == 0) {
				t0 = s0.r;
				dy = t0 - s1.r;
			} else if (channel == 1) {
				t0 = s0.g;
				dy = t0 - s1.g;
			} else {
				t0 = s0.b;
				dy = t0 - s1.b;
			}
			f = -f;
		} else {
			vec4 s0 = texelFetch(curve_xyz, ivec2(NEXUS_CURVE_TEX_LAST_IDX, 0), 0);
			vec4 s1 = texelFetch(curve_xyz, ivec2(NEXUS_CURVE_TEX_LAST_IDX - 1, 0), 0);
			if (channel == 0) {
				t0 = s0.r;
				dy = t0 - s1.r;
			} else if (channel == 1) {
				t0 = s0.g;
				dy = t0 - s1.g;
			} else {
				t0 = s0.b;
				dy = t0 - s1.b;
			}
			f = f - 1.0;
		}
		return t0 + dy * f * (NEXUS_CURVE_TEX_WIDTH - 1.0);
	}
	float ff = clamp(at, 0.0, 1.0) * (NEXUS_CURVE_TEX_WIDTH - 1.0);
	int i = int(ff);
	if (i < 0) {
		i = 0;
	}
	if (i >= table_size) {
		i = table_size - 1;
	}
	float t = ff - float(i);
	vec4 s = texelFetch(curve_xyz, ivec2(i, 0), 0);
	float result;
	if (channel == 0) {
		result = s.r;
	} else if (channel == 1) {
		result = s.g;
	} else {
		result = s.b;
	}
	if (t > 0.0 && i + 1 < table_size) {
		vec4 s_next = texelFetch(curve_xyz, ivec2(i + 1, 0), 0);
		if (channel == 0) {
			result = mix(result, s_next.r, t);
		} else if (channel == 1) {
			result = mix(result, s_next.g, t);
		} else {
			result = mix(result, s_next.b, t);
		}
	}
	return result;
}
