// Nexus B2G shared shader include.
float nexus_smootherstep_f(float edge0, float edge1, float x) {
	float t = clamp((edge1 != edge0) ? ((x - edge0) / (edge1 - edge0)) : 0.0, 0.0, 1.0);
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float nexus_map_range_linear_f(
	float value, float from_min, float from_max, float to_min, float to_max
) {
	if (from_max == from_min) {
		return 0.0;
	}
	return to_min + ((value - from_min) / (from_max - from_min)) * (to_max - to_min);
}

float nexus_map_range_stepped_f(
	float value, float from_min, float from_max, float to_min, float to_max, float steps
) {
	if (from_max == from_min) {
		return 0.0;
	}
	float factor = (value - from_min) / (from_max - from_min);
	factor = (steps > 0.0) ? floor(factor * (steps + 1.0)) / steps : 0.0;
	return to_min + factor * (to_max - to_min);
}

float nexus_map_range_smoothstep_f(
	float value, float from_min, float from_max, float to_min, float to_max
) {
	if (from_max == from_min) {
		return 0.0;
	}
	float factor = (from_min > from_max)
		? 1.0 - smoothstep(from_max, from_min, value)
		: smoothstep(from_min, from_max, value);
	return to_min + factor * (to_max - to_min);
}

float nexus_map_range_smootherstep_f(
	float value, float from_min, float from_max, float to_min, float to_max
) {
	if (from_max == from_min) {
		return 0.0;
	}
	float factor = (from_min > from_max)
		? 1.0 - nexus_smootherstep_f(from_max, from_min, value)
		: nexus_smootherstep_f(from_min, from_max, value);
	return to_min + factor * (to_max - to_min);
}
vec3 nexus_map_range_linear_v(
	vec3 value, vec3 from_min, vec3 from_max, vec3 to_min, vec3 to_max, bool use_clamp
) {
	vec3 factor = nexus_safe_divide(value - from_min, from_max - from_min);
	vec3 result = to_min + factor * (to_max - to_min);
	if (use_clamp) {
		result.x = (to_min.x > to_max.x)
			? clamp(result.x, to_max.x, to_min.x) : clamp(result.x, to_min.x, to_max.x);
		result.y = (to_min.y > to_max.y)
			? clamp(result.y, to_max.y, to_min.y) : clamp(result.y, to_min.y, to_max.y);
		result.z = (to_min.z > to_max.z)
			? clamp(result.z, to_max.z, to_min.z) : clamp(result.z, to_min.z, to_max.z);
	}
	return result;
}

vec3 nexus_map_range_stepped_v(
	vec3 value, vec3 from_min, vec3 from_max, vec3 to_min, vec3 to_max, vec3 steps, bool use_clamp
) {
	vec3 factor = nexus_safe_divide(value - from_min, from_max - from_min);
	factor = nexus_safe_divide(floor(factor * (steps + vec3(1.0))), steps);
	vec3 result = to_min + factor * (to_max - to_min);
	if (use_clamp) {
		result.x = (to_min.x > to_max.x)
			? clamp(result.x, to_max.x, to_min.x) : clamp(result.x, to_min.x, to_max.x);
		result.y = (to_min.y > to_max.y)
			? clamp(result.y, to_max.y, to_min.y) : clamp(result.y, to_min.y, to_max.y);
		result.z = (to_min.z > to_max.z)
			? clamp(result.z, to_max.z, to_min.z) : clamp(result.z, to_min.z, to_max.z);
	}
	return result;
}

vec3 nexus_map_range_smoothstep_v(
	vec3 value, vec3 from_min, vec3 from_max, vec3 to_min, vec3 to_max
) {
	vec3 factor = nexus_safe_divide(value - from_min, from_max - from_min);
	factor = clamp(factor, 0.0, 1.0);
	factor = (3.0 - 2.0 * factor) * (factor * factor);
	return to_min + factor * (to_max - to_min);
}

vec3 nexus_map_range_smootherstep_v(
	vec3 value, vec3 from_min, vec3 from_max, vec3 to_min, vec3 to_max
) {
	vec3 factor = nexus_safe_divide(value - from_min, from_max - from_min);
	factor = clamp(factor, 0.0, 1.0);
	factor = factor * factor * factor * (factor * (factor * 6.0 - 15.0) + 10.0);
	return to_min + factor * (to_max - to_min);
}
