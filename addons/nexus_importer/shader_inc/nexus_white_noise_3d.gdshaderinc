// Nexus B2G shared shader include.
void nexus_white_noise_3d(vec3 vector, float w, out float value, out vec4 color)
{
  value = hash_vec3_to_float(vector);
  color = vec4(hash_vec3_to_vec3(vector), 1.0);
}
