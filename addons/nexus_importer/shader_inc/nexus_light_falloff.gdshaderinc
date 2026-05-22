// Nexus B2G shared shader include.
float nexus_light_falloff_apply_smooth(float falloff_strength, float falloff_smooth, float falloff_ray_len) {
	if (falloff_smooth <= 0.0) {
		return falloff_strength;
	}
	float squared = falloff_ray_len * falloff_ray_len;
	return falloff_strength * squared / (falloff_smooth + squared);
}

float nexus_light_falloff_quadratic(float falloff_strength, float falloff_smooth, float falloff_ray_len) {
	return nexus_light_falloff_apply_smooth(falloff_strength, falloff_smooth, falloff_ray_len);
}

float nexus_light_falloff_linear(float falloff_strength, float falloff_smooth, float falloff_ray_len) {
	float s = nexus_light_falloff_apply_smooth(falloff_strength, falloff_smooth, falloff_ray_len);
	return s * falloff_ray_len;
}

float nexus_light_falloff_constant(float falloff_strength, float falloff_smooth, float falloff_ray_len) {
	float s = nexus_light_falloff_apply_smooth(falloff_strength, falloff_smooth, falloff_ray_len);
	return s * falloff_ray_len * falloff_ray_len;
}
