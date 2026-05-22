// Nexus B2G shared shader include.
void nexus_tex_checker(vec3 co, vec4 color1, vec4 color2, float scale, out vec4 color, out float fac)
{
  vec3 p = co * scale;
  p = (p + 0.000001) * 0.999999;
  int xi = int(abs(floor(p.x)));
  int yi = int(abs(floor(p.y)));
  int zi = int(abs(floor(p.z)));
  bool check = ((mod(float(xi), 2.0) == mod(float(yi), 2.0)) == (mod(float(zi), 2.0) == 0.0));
  color = check ? color1 : color2;
  fac = check ? 1.0 : 0.0;
}
