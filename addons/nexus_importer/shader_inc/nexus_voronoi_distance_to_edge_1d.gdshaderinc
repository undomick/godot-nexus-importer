// Nexus B2G shared shader include.
const int SHD_VORONOI_EUCLIDEAN = 0;
const int SHD_VORONOI_MANHATTAN = 1;
const int SHD_VORONOI_CHEBYCHEV = 2;
const int SHD_VORONOI_MINKOWSKI = 3;

const int SHD_VORONOI_F1 = 0;
const int SHD_VORONOI_F2 = 1;
const int SHD_VORONOI_SMOOTH_F1 = 2;
const int SHD_VORONOI_DISTANCE_TO_EDGE = 3;
const int SHD_VORONOI_N_SPHERE_RADIUS = 4;

struct VoronoiParams {
  float scale;
  float detail;
  float roughness;
  float lacunarity;
  float smoothness;
  float exponent;
  float randomness;
  float max_distance;
  bool normalize;
  int feature;
  int metric;
};

struct VoronoiOutput {
  float Distance;
  vec3 Color;
  vec4 Position;
};

float voronoi_distance(float a, float b)
{
  return abs(a - b);
}

vec4 voronoi_position(float coord)
{
  return vec4(0.0, 0.0, 0.0, coord);
}

VoronoiOutput voronoi_f1(VoronoiParams params, float coord)
{
  float cellPosition = floor(coord);
  float localPosition = coord - cellPosition;

  float minDistance = 3.402823466e+38;
  float targetOffset = 0.0;
  float targetPosition = 0.0;
  for (int i = -1; i <= 1; i++) {
    float cellOffset = i;
    float pointPosition = cellOffset +
                          hash_float_to_float(cellPosition + cellOffset) * params.randomness;
    float distanceToPoint = voronoi_distance(pointPosition, localPosition);
    if (distanceToPoint < minDistance) {
      targetOffset = cellOffset;
      minDistance = distanceToPoint;
      targetPosition = pointPosition;
    }
  }

  VoronoiOutput octave;
  octave.Distance = minDistance;
  octave.Color = hash_float_to_vec3(cellPosition + targetOffset);
  octave.Position = voronoi_position(targetPosition + cellPosition);
  return octave;
}

VoronoiOutput voronoi_f2(VoronoiParams params, float coord)
{
  float cellPosition = floor(coord);
  float localPosition = coord - cellPosition;

  float distanceF1 = 3.402823466e+38;
  float distanceF2 = 3.402823466e+38;
  float offsetF1 = 0.0;
  float positionF1 = 0.0;
  float offsetF2 = 0.0;
  float positionF2 = 0.0;
  for (int i = -1; i <= 1; i++) {
    float cellOffset = i;
    float pointPosition = cellOffset +
                          hash_float_to_float(cellPosition + cellOffset) * params.randomness;
    float distanceToPoint = voronoi_distance(pointPosition, localPosition);
    if (distanceToPoint < distanceF1) {
      distanceF2 = distanceF1;
      distanceF1 = distanceToPoint;
      offsetF2 = offsetF1;
      offsetF1 = cellOffset;
      positionF2 = positionF1;
      positionF1 = pointPosition;
    }
    else if (distanceToPoint < distanceF2) {
      distanceF2 = distanceToPoint;
      offsetF2 = cellOffset;
      positionF2 = pointPosition;
    }
  }

  VoronoiOutput octave;
  octave.Distance = distanceF2;
  octave.Color = hash_float_to_vec3(cellPosition + offsetF2);
  octave.Position = voronoi_position(positionF2 + cellPosition);
  return octave;
}

VoronoiOutput voronoi_smooth_f1(VoronoiParams params, float coord)
{
  float cellPosition = floor(coord);
  float localPosition = coord - cellPosition;

  float smoothDistance = 0.0;
  float smoothPosition = 0.0;
  vec3 smoothColor = vec3(0.0);
  float h = -1.0;
  for (int i = -2; i <= 2; i++) {
    float cellOffset = i;
    float pointPosition = cellOffset +
                          hash_float_to_float(cellPosition + cellOffset) * params.randomness;
    float distanceToPoint = voronoi_distance(pointPosition, localPosition);
    h = h == -1.0 ?
            1.0 :
            smoothstep(
                0.0, 1.0, 0.5 + 0.5 * (smoothDistance - distanceToPoint) / params.smoothness);
    float correctionFactor = params.smoothness * h * (1.0 - h);
    smoothDistance = mix(smoothDistance, distanceToPoint, h) - correctionFactor;
    correctionFactor /= 1.0 + 3.0 * params.smoothness;
    vec3 cellColor = hash_float_to_vec3(cellPosition + cellOffset);
    smoothColor = mix(smoothColor, cellColor, h) - correctionFactor;
    smoothPosition = mix(smoothPosition, pointPosition, h) - correctionFactor;
  }

  VoronoiOutput octave;
  octave.Distance = smoothDistance;
  octave.Color = smoothColor;
  octave.Position = voronoi_position(cellPosition + smoothPosition);
  return octave;
}

VoronoiOutput fractal_voronoi_x_fx(VoronoiParams params, float coord)
{
  float amplitude = 1.0;
  float max_amplitude = 0.0;
  float scale = 1.0;

  VoronoiOutput Output;
  Output.Distance = 0.0;
  Output.Color = vec3(0.0, 0.0, 0.0);
  Output.Position = vec4(0.0, 0.0, 0.0, 0.0);
  bool zero_input = params.detail == 0.0 || params.roughness == 0.0;

  for (int i = 0; i <= int(ceil(params.detail)); ++i) {
    VoronoiOutput octave;
    if (params.feature == SHD_VORONOI_F2) {
      octave = voronoi_f2(params, coord * scale);
    }
    else if (params.feature == SHD_VORONOI_SMOOTH_F1 && params.smoothness != 0.0) {
      octave = voronoi_smooth_f1(params, coord * scale);
    }
    else {
      octave = voronoi_f1(params, coord * scale);
    }

    if (zero_input) {
      max_amplitude = 1.0;
      Output = octave;
      break;
    }
    else if (float(i) <= params.detail) {
      max_amplitude += amplitude;
      Output.Distance += octave.Distance * amplitude;
      Output.Color += octave.Color * amplitude;
      Output.Position = mix(Output.Position, octave.Position / scale, amplitude);
      scale *= params.lacunarity;
      amplitude *= params.roughness;
    }
    else {
      float remainder = params.detail - floor(params.detail);
      if (remainder != 0.0) {
        max_amplitude = mix(max_amplitude, max_amplitude + amplitude, remainder);
        Output.Distance = mix(
            Output.Distance, Output.Distance + octave.Distance * amplitude, remainder);
        Output.Color = mix(Output.Color, Output.Color + octave.Color * amplitude, remainder);
        Output.Position = mix(
            Output.Position, mix(Output.Position, octave.Position / scale, amplitude), remainder);
      }
    }
  }

  if (params.normalize) {
    Output.Distance /= max_amplitude * params.max_distance;
    Output.Color /= max_amplitude;
  }

  Output.Position = safe_divide(Output.Position, params.scale);

  return Output;
}

float voronoi_distance_to_edge(VoronoiParams params, float coord)
{
  float cellPosition = floor(coord);
  float localPosition = coord - cellPosition;

  float midPointPosition = hash_float_to_float(cellPosition) * params.randomness;
  float leftPointPosition = -1.0 + hash_float_to_float(cellPosition - 1.0) * params.randomness;
  float rightPointPosition = 1.0 + hash_float_to_float(cellPosition + 1.0) * params.randomness;
  float distanceToMidLeft = abs((midPointPosition + leftPointPosition) / 2.0 - localPosition);
  float distanceToMidRight = abs((midPointPosition + rightPointPosition) / 2.0 - localPosition);

  return min(distanceToMidLeft, distanceToMidRight);
}

float fractal_voronoi_distance_to_edge(VoronoiParams params, float coord)
  {
    float amplitude = 1.0;
    float max_amplitude = params.max_distance;
    float scale = 1.0;
    float distance = 8.0;

    bool zero_input = params.detail == 0.0 || params.roughness == 0.0;

    for (int i = 0; i <= int(ceil(params.detail)); ++i) {
      float octave_distance = voronoi_distance_to_edge(params, coord * scale);

      if (zero_input) {
        distance = octave_distance;
        break;
      }
      else if (float(i) <= params.detail) {
        max_amplitude = mix(max_amplitude, params.max_distance / scale, amplitude);
        distance = mix(distance, min(distance, octave_distance / scale), amplitude);
        scale *= params.lacunarity;
        amplitude *= params.roughness;
      }
      else {
        float remainder = params.detail - floor(params.detail);
        if (remainder != 0.0) {
          float lerp_amplitude = mix(max_amplitude, params.max_distance / scale, amplitude);
          max_amplitude = mix(max_amplitude, lerp_amplitude, remainder);
          float lerp_distance = mix(distance, min(distance, octave_distance / scale), amplitude);
          distance = mix(distance, min(distance, lerp_distance), remainder);
        }
      }
    }

    if (params.normalize) {
      distance /= max_amplitude;
    }

    return distance;
}

void nexus_tex_voronoi_distance_to_edge_1d(vec3 coord,
                                          float w,
                                          float scale,
                                          float detail,
                                          float roughness,
                                          float lacunarity,
                                          float smoothness,
                                          float exponent,
                                          float randomness,
                                          float metric,
                                          float normalize,
                                          out float outDistance,
                                          out vec4 outColor,
                                          out vec3 outPosition,
                                          out float outW,
                                          out float outRadius)
{
  VoronoiParams params;

  params.feature = SHD_VORONOI_DISTANCE_TO_EDGE;
  params.metric = int(metric);
  params.scale = scale;
  params.detail = clamp(detail, 0.0, 15.0);
  params.roughness = clamp(roughness, 0.0, 1.0);
  params.lacunarity = lacunarity;
  params.smoothness = clamp(smoothness / 2.0, 0.0, 0.5);
  params.exponent = exponent;
  params.randomness = clamp(randomness, 0.0, 1.0);
  params.max_distance = 0.0;
params.normalize = bool(normalize);

  w *= scale;

  params.max_distance = 0.5 + 0.5 * params.randomness;
  outDistance = fractal_voronoi_distance_to_edge(params, w);
}
