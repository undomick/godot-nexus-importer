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

float voronoi_n_sphere_radius(VoronoiParams params, float coord)
{
  float cellPosition = floor(coord);
  float localPosition = coord - cellPosition;

  float closestPoint = 0.0;
  float closestPointOffset = 0.0;
  float minDistance = 3.402823466e+38;
  for (int i = -1; i <= 1; i++) {
    float cellOffset = i;
    float pointPosition = cellOffset +
                          hash_float_to_float(cellPosition + cellOffset) * params.randomness;
    float distanceToPoint = abs(pointPosition - localPosition);
    if (distanceToPoint < minDistance) {
      minDistance = distanceToPoint;
      closestPoint = pointPosition;
      closestPointOffset = cellOffset;
    }
  }

  minDistance = 3.402823466e+38;
  float closestPointToClosestPoint = 0.0;
  for (int i = -1; i <= 1; i++) {
    if (i == 0) {
      continue;
    }
    float cellOffset = i + closestPointOffset;
    float pointPosition = cellOffset +
                          hash_float_to_float(cellPosition + cellOffset) * params.randomness;
    float distanceToPoint = abs(closestPoint - pointPosition);
    if (distanceToPoint < minDistance) {
      minDistance = distanceToPoint;
      closestPointToClosestPoint = pointPosition;
    }
  }

  return abs(closestPointToClosestPoint - closestPoint) / 2.0;
}

void nexus_tex_voronoi_n_sphere_radius_1d(vec3 coord,
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

  params.feature = SHD_VORONOI_N_SPHERE_RADIUS;
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

  outRadius = voronoi_n_sphere_radius(params, w);
}
