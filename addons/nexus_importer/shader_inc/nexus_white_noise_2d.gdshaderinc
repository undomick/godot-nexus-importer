// Nexus B2G shared shader include.
void nexus_white_noise_2d(vec3 vector, float w, out float value, out vec4 color)
{
  value = hash_vec2_to_float(vector.xy);
  color = vec4(hash_vec2_to_vec3(vector.xy), 1.0);
}
