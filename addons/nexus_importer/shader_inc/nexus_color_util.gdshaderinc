// Nexus B2G shared shader include.
mat3 _nexus_euler_xyz(vec3 e) {
	float cx = cos(e.x); float sx = sin(e.x);
	float cy = cos(e.y); float sy = sin(e.y);
	float cz = cos(e.z); float sz = sin(e.z);
	mat3 rx = mat3(
		vec3(1.0, 0.0, 0.0),
		vec3(0.0, cx, -sx),
		vec3(0.0, sx, cx)
	);
	mat3 ry = mat3(
		vec3(cy, 0.0, sy),
		vec3(0.0, 1.0, 0.0),
		vec3(-sy, 0.0, cy)
	);
	mat3 rz = mat3(
		vec3(cz, -sz, 0.0),
		vec3(sz, cz, 0.0),
		vec3(0.0, 0.0, 1.0)
	);
	return rz * ry * rx;
}
vec3 nexus_blackbody_rgb(float kelvin) {
	kelvin = clamp(kelvin, 800.0, 12000.0);
	float t = kelvin * 0.01;
	float r = (t <= 66.0) ? 1.0 : clamp(1.292936186063745 * pow(t - 60.0, -0.1332047592), 0.0, 1.0);
	float g = (t <= 66.0)
		? clamp(0.390081578769019 * log(max(t, 1e-6)) - 0.631841443788627, 0.0, 1.0)
		: clamp(1.129890860895294 * pow(t - 60.0, -0.0755148492), 0.0, 1.0);
	float b = (t >= 66.0)
		? 1.0
		: (t <= 19.0)
			? 0.0
			: clamp(0.543206789110193 * log(t - 10.0) - 1.19625408994438, 0.0, 1.0);
	return vec3(r, g, b);
}
vec3 nexus_wavelength_rgb(float wavelength_nm) {
	float w = clamp(wavelength_nm, 380.0, 780.0);
	vec3 rgb;
	if (w >= 380.0 && w < 440.0) {
		rgb = vec3(-(w - 440.0) / (440.0 - 380.0), 0.0, 1.0);
	} else if (w < 490.0) {
		rgb = vec3(0.0, (w - 440.0) / (490.0 - 440.0), 1.0);
	} else if (w < 510.0) {
		rgb = vec3(0.0, 1.0, -(w - 510.0) / (510.0 - 490.0));
	} else if (w < 580.0) {
		rgb = vec3((w - 510.0) / (580.0 - 510.0), 1.0, 0.0);
	} else if (w < 645.0) {
		rgb = vec3(1.0, -(w - 645.0) / (645.0 - 580.0), 0.0);
	} else {
		rgb = vec3(1.0, 0.0, 0.0);
	}
	float s = 1.0;
	if (w >= 380.0 && w < 420.0) {
		s = 0.3 + 0.7 * (w - 380.0) / (420.0 - 380.0);
	} else if (w > 700.0) {
		s = 0.3 + 0.7 * (780.0 - w) / (780.0 - 700.0);
	}
	return rgb * s;
}
vec3 nexus_brightness_contrast(vec3 color_in, float bright_in, float contrast_in) {
	float a = 1.0 + contrast_in;
	float b = bright_in - contrast_in * 0.5;
	return max(vec3(a) * color_in + vec3(b), vec3(0.0));
}
vec3 nexus_gamma_color(vec3 color_in, float gamma_in) {
	if (gamma_in == 0.0) {
		return vec3(1.0);
	}
	return vec3(
		color_in.r > 0.0 ? pow(color_in.r, gamma_in) : color_in.r,
		color_in.g > 0.0 ? pow(color_in.g, gamma_in) : color_in.g,
		color_in.b > 0.0 ? pow(color_in.b, gamma_in) : color_in.b
	);
}
