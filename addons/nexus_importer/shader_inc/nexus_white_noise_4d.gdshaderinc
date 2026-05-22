// Nexus B2G shared shader include.
void nexus_white_noise_4d(vec3 vector, float w, out float value, out vec4 color)
{
  value = hash_vec4_to_float(vec4(vector, w));
  color = vec4(hash_vec4_to_vec3(vec4(vector, w)), 1.0);
}
