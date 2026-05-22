// Nexus B2G shared shader include.
void nexus_white_noise_1d(vec3 vector, float w, out float value, out vec4 color)
{
  value = hash_float_to_float(w);
  color = vec4(hash_float_to_vec3(w), 1.0);
}
