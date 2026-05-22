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

float voronoi_distance(vec4 a, vec4 b, VoronoiParams params)
{
  if (params.metric == SHD_VORONOI_EUCLIDEAN) {
    return distance(a, b);
  }
  else if (params.metric == SHD_VORONOI_MANHATTAN) {
    return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z) + abs(a.w - b.w);
  }
  else if (params.metric == SHD_VORONOI_CHEBYCHEV) {
    return max(abs(a.x - b.x), max(abs(a.y - b.y), max(abs(a.z - b.z), abs(a.w - b.w))));
  }
  else if (params.metric == SHD_VORONOI_MINKOWSKI) {
    return pow(pow(abs(a.x - b.x), params.exponent) + pow(abs(a.y - b.y), params.exponent) +
                   pow(abs(a.z - b.z), params.exponent) + pow(abs(a.w - b.w), params.exponent),
               1.0 / params.exponent);
  }
  else {
    return 0.0;
  }
}

float voronoi_n_sphere_radius(VoronoiParams params, vec4 coord)
{
  vec4 cellPosition_f = floor(coord);
  vec4 localPosition = coord - cellPosition_f;
  ivec4 cellPosition = ivec4(cellPosition_f);

  vec4 closestPoint = vec4(0.0);
  ivec4 closestPointOffset = ivec4(0);
  float minDistance = 3.402823466e+38;
  for (int u = -1; u <= 1; u++) {
    for (int k = -1; k <= 1; k++) {
      for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
          ivec4 cellOffset = ivec4(i, j, k, u);
          vec4 pointPosition = vec4(cellOffset) +
                                 hash_int4_to_vec4(cellPosition + cellOffset) * params.randomness;
          float distanceToPoint = distance(pointPosition, localPosition);
          if (distanceToPoint < minDistance) {
            minDistance = distanceToPoint;
            closestPoint = pointPosition;
            closestPointOffset = cellOffset;
          }
        }
      }
    }
  }

  minDistance = 3.402823466e+38;
  vec4 closestPointToClosestPoint = vec4(0.0);
  for (int u = -1; u <= 1; u++) {
    for (int k = -1; k <= 1; k++) {
      for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
          if (i == 0 && j == 0 && k == 0 && u == 0) {
            continue;
          }
          ivec4 cellOffset = ivec4(i, j, k, u) + closestPointOffset;
          vec4 pointPosition = vec4(cellOffset) +
                                 hash_int4_to_vec4(cellPosition + cellOffset) * params.randomness;
          float distanceToPoint = distance(closestPoint, pointPosition);
          if (distanceToPoint < minDistance) {
            minDistance = distanceToPoint;
            closestPointToClosestPoint = pointPosition;
          }
        }
      }
    }
  }

  return distance(closestPointToClosestPoint, closestPoint) / 2.0;
}

void nexus_tex_voronoi_n_sphere_radius_4d(vec3 coord,
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
  coord *= scale;

  outRadius = voronoi_n_sphere_radius(params, vec4(coord, w));
}
