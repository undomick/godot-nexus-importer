// Nexus B2G shared shader include.
float length_squared(vec2 a) { return dot(a, a); }
float length_squared(vec3 a) { return dot(a, a); }






const int SHD_GABOR_TYPE_2D = 0;
const int SHD_GABOR_TYPE_3D = 1;


const int IMPULSES_COUNT = 8;


vec2 compute_2d_gabor_kernel(vec2 position, float frequency, float orientation)
{
  float distance_squared = length_squared(position);
  float hann_window = 0.5 + 0.5 * cos(PI * distance_squared);
  float gaussian_envelop = exp(-PI * distance_squared);
  float windowed_gaussian_envelope = gaussian_envelop * hann_window;

  vec2 frequency_vector = frequency * vec2(cos(orientation), sin(orientation));
  float angle = 2.0 * PI * dot(position, frequency_vector);
  vec2 phasor = vec2(cos(angle), sin(angle));

  return windowed_gaussian_envelope * phasor;
}


float compute_2d_gabor_standard_deviation()
{
  float integral_of_gabor_squared = 0.25;
  float second_moment = 0.5;
  return sqrt(float(IMPULSES_COUNT) * second_moment * integral_of_gabor_squared);
}


vec2 compute_2d_gabor_noise_cell(
    vec2 cell, vec2 position, float frequency, float isotropy, float base_orientation)

{
  vec2 noise = vec2(0.0);
  for (int i = 0; i < IMPULSES_COUNT; ++i) {
    
    vec3 seed_for_orientation = vec3(cell, float(i * 3));
    vec3 seed_for_kernel_center = vec3(cell, float(i * 3 + 1));
    vec3 seed_for_weight = vec3(cell, float(i * 3 + 2));

    
    float random_orientation = (hash_vec3_to_float(seed_for_orientation) - 0.5) * PI;
    float orientation = base_orientation + random_orientation * isotropy;

    vec2 kernel_center = hash_vec3_to_vec2(seed_for_kernel_center);
    vec2 position_in_kernel_space = position - kernel_center;

    
    if (length_squared(position_in_kernel_space) >= 1.0) {
      continue;
    }

    
    float weight = hash_vec3_to_float(seed_for_weight) < 0.5 ? -1.0 : 1.0;

    noise += weight * compute_2d_gabor_kernel(position_in_kernel_space, frequency, orientation);
  }
  return noise;
}


vec2 compute_2d_gabor_noise(vec2 coordinates,
                              float frequency,
                              float isotropy,
                              float base_orientation)
{
  vec2 cell_position = floor(coordinates);
  vec2 local_position = coordinates - cell_position;

  vec2 sum = vec2(0.0);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 cell_offset = vec2(float(i), float(j));

      vec2 current_cell_position = cell_position + cell_offset;
      vec2 position_in_cell_space = local_position - cell_offset;

      sum += compute_2d_gabor_noise_cell(
          current_cell_position, position_in_cell_space, frequency, isotropy, base_orientation);
    }
  }

  return sum;
}


vec2 compute_3d_gabor_kernel(vec3 position, float frequency, vec3 orientation)
{
  float distance_squared = length_squared(position);
  float hann_window = 0.5 + 0.5 * cos(PI * distance_squared);
  float gaussian_envelop = exp(-PI * distance_squared);
  float windowed_gaussian_envelope = gaussian_envelop * hann_window;

  vec3 frequency_vector = frequency * orientation;
  float angle = 2.0 * PI * dot(position, frequency_vector);
  vec2 phasor = vec2(cos(angle), sin(angle));

  return windowed_gaussian_envelope * phasor;
}


float compute_3d_gabor_standard_deviation()
{
  float integral_of_gabor_squared = 1.0 / (4.0 * 1.4142135623730951);
  float second_moment = 0.5;
  return sqrt(float(IMPULSES_COUNT) * second_moment * integral_of_gabor_squared);
}


vec3 compute_3d_orientation(vec3 orientation, float isotropy, vec4 seed)
{
  
  if (isotropy == 0.0) {
    return orientation;
  }

  
  float inclination = acos(orientation.z);
  float azimuth = sign(orientation.y) * acos(orientation.x / length(orientation.xy));

  
  vec2 random_angles = hash_vec4_to_vec2(seed) * PI;
  inclination += random_angles.x * isotropy;
  azimuth += random_angles.y * isotropy;

  
  return vec3(
      sin(inclination) * cos(azimuth), sin(inclination) * sin(azimuth), cos(inclination));
}

vec2 compute_3d_gabor_noise_cell(
    vec3 cell, vec3 position, float frequency, float isotropy, vec3 base_orientation)

{
  vec2 noise = vec2(0.0);
  for (int i = 0; i < IMPULSES_COUNT; ++i) {
    
    vec4 seed_for_orientation = vec4(cell, float(i * 3));
    vec4 seed_for_kernel_center = vec4(cell, float(i * 3 + 1));
    vec4 seed_for_weight = vec4(cell, float(i * 3 + 2));

    vec3 orientation = compute_3d_orientation(base_orientation, isotropy, seed_for_orientation);

    vec3 kernel_center = hash_vec4_to_vec3(seed_for_kernel_center);
    vec3 position_in_kernel_space = position - kernel_center;

    
    if (length_squared(position_in_kernel_space) >= 1.0) {
      continue;
    }

    
    float weight = hash_vec4_to_float(seed_for_weight) < 0.5 ? -1.0 : 1.0;

    noise += weight * compute_3d_gabor_kernel(position_in_kernel_space, frequency, orientation);
  }
  return noise;
}


vec2 compute_3d_gabor_noise(vec3 coordinates,
                              float frequency,
                              float isotropy,
                              vec3 base_orientation)
{
  vec3 cell_position = floor(coordinates);
  vec3 local_position = coordinates - cell_position;

  vec2 sum = vec2(0.0);
  for (int k = -1; k <= 1; k++) {
    for (int j = -1; j <= 1; j++) {
      for (int i = -1; i <= 1; i++) {
        vec3 cell_offset = vec3(float(i), float(j), float(k));
        vec3 current_cell_position = cell_position + cell_offset;
        vec3 position_in_cell_space = local_position - cell_offset;
        sum += compute_3d_gabor_noise_cell(
            current_cell_position, position_in_cell_space, frequency, isotropy, base_orientation);
      }
    }
  }

  return sum;
}

void nexus_tex_gabor(vec3 coordinates,
                    float scale,
                    float frequency,
                    float anisotropy,
                    float orientation_2d,
                    vec3 orientation_3d,
                    int type,
                    out float output_value,
                    out float output_phase,
                    out float output_intensity)
{
  vec3 scaled_coordinates = coordinates * scale;
  float isotropy = 1.0 - clamp(anisotropy, 0.0, 1.0);
  frequency = max(0.001, frequency);

  vec2 phasor = vec2(0.0);
  float standard_deviation = 1.0;
  if (type == SHD_GABOR_TYPE_2D) {
    phasor = compute_2d_gabor_noise(scaled_coordinates.xy, frequency, isotropy, orientation_2d);
    standard_deviation = compute_2d_gabor_standard_deviation();
  }
  else if (type == SHD_GABOR_TYPE_3D) {
    vec3 orientation = normalize(orientation_3d);
    phasor = compute_3d_gabor_noise(scaled_coordinates, frequency, isotropy, orientation);
    standard_deviation = compute_3d_gabor_standard_deviation();
  }

  
  float normalization_factor = 6.0 * standard_deviation;

  
  output_value = (phasor.y / normalization_factor) * 0.5 + 0.5;

  
  output_phase = (atan(phasor.y, phasor.x) + PI) / (2.0 * PI);

  
  output_intensity = length(phasor) / normalization_factor;
}
