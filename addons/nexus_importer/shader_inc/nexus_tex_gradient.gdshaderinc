// Nexus B2G shared shader include.
float calc_gradient(vec3 p, int gradient_type)
{
  float x, y, z;
  x = p.x;
  y = p.y;
  z = p.z;
  if (gradient_type == 0) {
    return x;
  }
  else if (gradient_type == 1) {
    float r = max(x, 0.0);
    return r * r;
  }
  else if (gradient_type == 2) {
    float r = min(max(x, 0.0), 1.0);
    float t = r * r;
    return (3.0 * t - 2.0 * t * r);
  }
  else if (gradient_type == 3) {
    return (x + y) * 0.5;
  }
  else if (gradient_type == 4) {
    return atan(y, x) / (PI * 2.0) + 0.5;
  }
  else {
    float r = max(0.999999 - sqrt(x * x + y * y + z * z), 0.0);
    if (gradient_type == 5) {
      return r * r;
    }
    else if (gradient_type == 6) {
      return r;
    }
  }
  return 0.0;
}

void nexus_tex_gradient(vec3 co, float gradient_type, out vec4 color, out float fac)
{
  float f = calc_gradient(co, int(gradient_type));
  f = clamp(f, 0.0, 1.0);

  color = vec4(f, f, f, 1.0);
  fac = f;
}
