// Nexus B2G shared shader include.
vec3 nexus_node_bump(
	float strength,
	float dist,
	float filter_width,
	float height,
	vec2 height_xy,
	vec3 N_world,
	vec3 dPdx,
	vec3 dPdy
) {
	vec3 N = normalize(N_world);
	vec3 Rx = cross(dPdy, N);
	vec3 Ry = cross(N, dPdx);
	float det = dot(dPdx, Rx);
	vec2 dHd = height_xy - vec2(height);
	vec3 surfgrad = dHd.x * Rx + dHd.y * Ry;
	strength = max(strength, 0.0);
	vec3 result = normalize(filter_width * abs(det) * N - dist * sign(det) * surfgrad);
	return normalize(mix(N, result, clamp(strength, 0.0, 1.0)));
}
