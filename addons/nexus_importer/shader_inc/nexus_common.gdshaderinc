// Nexus B2G shared shader include.
float safe_divide(float a, float b) {
	return (b != 0.0) ? (a / b) : 0.0;
}

vec2 safe_divide(vec2 a, float b) {
	return (b != 0.0) ? (a / b) : vec2(0.0);
}

vec3 safe_divide(vec3 a, float b) {
	return (b != 0.0) ? (a / b) : vec3(0.0);
}

vec4 safe_divide(vec4 a, float b) {
	return (b != 0.0) ? (a / b) : vec4(0.0);
}

vec3 safe_divide(vec3 a, vec3 b) {
	return vec3(
		b.x != 0.0 ? a.x / b.x : 0.0,
		b.y != 0.0 ? a.y / b.y : 0.0,
		b.z != 0.0 ? a.z / b.z : 0.0
	);
}

vec3 nexus_safe_divide(vec3 a, vec3 b) {
	return safe_divide(a, b);
}
float nexus_clamp_minmax_f(float v, float lo, float hi) {
	return (v < lo) ? lo : ((v > hi) ? hi : v);
}
