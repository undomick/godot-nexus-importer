// Nexus B2G shared shader include.
vec3 nexus_rgb_to_hsv(vec3 rgb) {
	float cmax = max(rgb.r, max(rgb.g, rgb.b));
	float cmin = min(rgb.r, min(rgb.g, rgb.b));
	float cdelta = cmax - cmin;
	float v = cmax;
	float s;
	float h;
	if (cmax != 0.0) {
		s = cdelta / cmax;
	} else {
		return vec3(0.0, 0.0, 0.0);
	}
	if (s != 0.0) {
		vec3 c = (vec3(cmax) - rgb) / cdelta;
		if (rgb.r == cmax) {
			h = c.b - c.g;
		} else if (rgb.g == cmax) {
			h = 2.0 + c.r - c.b;
		} else {
			h = 4.0 + c.g - c.r;
		}
		h /= 6.0;
		if (h < 0.0) {
			h += 1.0;
		}
	} else {
		h = 0.0;
	}
	return vec3(h, s, v);
}

vec3 nexus_hsv_to_rgb(vec3 hsv) {
	float h = hsv.x;
	float s = hsv.y;
	float v = hsv.z;
	if (s == 0.0) {
		return vec3(v);
	}
	if (h == 1.0) {
		h = 0.0;
	}
	h *= 6.0;
	float sector = floor(h);
	float f = h - sector;
	float p = v * (1.0 - s);
	float q = v * (1.0 - s * f);
	float t = v * (1.0 - s * (1.0 - f));
	if (sector == 0.0) {
		return vec3(v, t, p);
	}
	if (sector == 1.0) {
		return vec3(q, v, p);
	}
	if (sector == 2.0) {
		return vec3(p, v, t);
	}
	if (sector == 3.0) {
		return vec3(p, q, v);
	}
	if (sector == 4.0) {
		return vec3(t, p, v);
	}
	return vec3(v, p, q);
}

vec3 nexus_hue_saturation_color(vec3 color_in, float hue_off, float sat_mul, float val_mul, float blend_fac) {
	vec3 hsv_work = nexus_rgb_to_hsv(color_in);
	hsv_work.x = fract(hsv_work.x + hue_off + 0.5);
	hsv_work.y = clamp(hsv_work.y * sat_mul, 0.0, 1.0);
	hsv_work.z *= val_mul;
	vec3 adjusted = nexus_hsv_to_rgb(hsv_work);
	adjusted = blend_fac * adjusted + (1.0 - blend_fac) * color_in;
	return max(adjusted, vec3(0.0));
}
vec3 nexus_mix_blend(float t, vec3 col1, vec3 col2) {
	return mix(col1, col2, t);
}

vec3 nexus_mix_darken(float t, vec3 col1, vec3 col2) {
	return mix(col1, min(col1, col2), t);
}

vec3 nexus_mix_multiply(float t, vec3 col1, vec3 col2) {
	return mix(col1, col1 * col2, t);
}

float nexus_mix_burn_channel(float t, float col1, float col2) {
	float tmp = (1.0 - t) + t * col2;
	if (tmp <= 0.0) {
		return 0.0;
	}
	tmp = 1.0 - (1.0 - col1) / tmp;
	return clamp(tmp, 0.0, 1.0);
}

vec3 nexus_mix_burn(float t, vec3 col1, vec3 col2) {
	return vec3(
		nexus_mix_burn_channel(t, col1.r, col2.r),
		nexus_mix_burn_channel(t, col1.g, col2.g),
		nexus_mix_burn_channel(t, col1.b, col2.b)
	);
}

vec3 nexus_mix_lighten(float t, vec3 col1, vec3 col2) {
	return mix(col1, max(col1, col2), t);
}

vec3 nexus_mix_screen(float t, vec3 col1, vec3 col2) {
	float tm = 1.0 - t;
	vec3 one = vec3(1.0);
	return one - (vec3(tm) + t * (one - col2)) * (one - col1);
}

float nexus_mix_dodge_channel(float t, float col1, float col2) {
	if (col1 == 0.0) {
		return 0.0;
	}
	float tmp = 1.0 - t * col2;
	if (tmp <= 0.0) {
		return 1.0;
	}
	tmp = col1 / tmp;
	return clamp(tmp, 0.0, 1.0);
}

vec3 nexus_mix_dodge(float t, vec3 col1, vec3 col2) {
	return vec3(
		nexus_mix_dodge_channel(t, col1.r, col2.r),
		nexus_mix_dodge_channel(t, col1.g, col2.g),
		nexus_mix_dodge_channel(t, col1.b, col2.b)
	);
}

vec3 nexus_mix_add(float t, vec3 col1, vec3 col2) {
	return mix(col1, col1 + col2, t);
}

float nexus_mix_overlay_channel(float t, float col1, float col2) {
	float tm = 1.0 - t;
	if (col1 < 0.5) {
		return col1 * (tm + 2.0 * t * col2);
	}
	return 1.0 - (tm + 2.0 * t * (1.0 - col2)) * (1.0 - col1);
}

vec3 nexus_mix_overlay(float t, vec3 col1, vec3 col2) {
	return vec3(
		nexus_mix_overlay_channel(t, col1.r, col2.r),
		nexus_mix_overlay_channel(t, col1.g, col2.g),
		nexus_mix_overlay_channel(t, col1.b, col2.b)
	);
}

vec3 nexus_mix_soft_light(float t, vec3 col1, vec3 col2) {
	float tm = 1.0 - t;
	vec3 one = vec3(1.0);
	vec3 scr = one - (one - col2) * (one - col1);
	return tm * col1 + t * ((one - col1) * col2 * col1 + col1 * scr);
}

vec3 nexus_mix_linear_light(float t, vec3 col1, vec3 col2) {
	return col1 + t * (2.0 * col2 - vec3(1.0));
}

vec3 nexus_mix_difference(float t, vec3 col1, vec3 col2) {
	return mix(col1, abs(col1 - col2), t);
}

vec3 nexus_mix_exclusion(float t, vec3 col1, vec3 col2) {
	return max(mix(col1, col1 + col2 - 2.0 * col1 * col2, t), vec3(0.0));
}

vec3 nexus_mix_subtract(float t, vec3 col1, vec3 col2) {
	return mix(col1, col1 - col2, t);
}

float nexus_mix_divide_channel(float t, float col1, float col2) {
	float tm = 1.0 - t;
	if (col2 != 0.0) {
		return tm * col1 + t * col1 / col2;
	}
	return col1;
}

vec3 nexus_mix_divide(float t, vec3 col1, vec3 col2) {
	return vec3(
		nexus_mix_divide_channel(t, col1.r, col2.r),
		nexus_mix_divide_channel(t, col1.g, col2.g),
		nexus_mix_divide_channel(t, col1.b, col2.b)
	);
}

vec3 nexus_mix_hue(float t, vec3 col1, vec3 col2) {
	vec3 outcol = col1;
	vec3 hsv2 = nexus_rgb_to_hsv(col2);
	if (hsv2.y != 0.0) {
		vec3 hsv = nexus_rgb_to_hsv(outcol);
		hsv.x = hsv2.x;
		outcol = mix(outcol, nexus_hsv_to_rgb(hsv), t);
	}
	return outcol;
}

vec3 nexus_mix_saturation(float t, vec3 col1, vec3 col2) {
	float tm = 1.0 - t;
	vec3 outcol = col1;
	vec3 hsv = nexus_rgb_to_hsv(outcol);
	if (hsv.y != 0.0) {
		vec3 hsv2 = nexus_rgb_to_hsv(col2);
		hsv.y = tm * hsv.y + t * hsv2.y;
		outcol = nexus_hsv_to_rgb(hsv);
	}
	return outcol;
}

vec3 nexus_mix_value(float t, vec3 col1, vec3 col2) {
	float tm = 1.0 - t;
	vec3 hsv = nexus_rgb_to_hsv(col1);
	vec3 hsv2 = nexus_rgb_to_hsv(col2);
	hsv.z = tm * hsv.z + t * hsv2.z;
	return nexus_hsv_to_rgb(hsv);
}

vec3 nexus_mix_color(float t, vec3 col1, vec3 col2) {
	vec3 outcol = col1;
	vec3 hsv2 = nexus_rgb_to_hsv(col2);
	if (hsv2.y != 0.0) {
		vec3 hsv = nexus_rgb_to_hsv(outcol);
		hsv.x = hsv2.x;
		hsv.y = hsv2.y;
		outcol = mix(outcol, nexus_hsv_to_rgb(hsv), t);
	}
	return outcol;
}
