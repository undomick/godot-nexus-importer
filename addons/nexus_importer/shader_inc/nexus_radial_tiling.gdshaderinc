// Nexus B2G shared shader include.
float nexus_rt_sqr(float x) { return x * x; }

vec4 nexus_calculate_out_variables_irregular_circular(bool calculate_r_gon_parameter_field,
                                           bool calculate_max_unit_parameter,
                                           bool normalize_r_gon_parameter,
                                           float r_gon_sides,
                                           float r_gon_roundness,
                                           vec2 coord,
                                           float l_coord)
{


  float x_axis_A_coord = atan(coord.y, coord.x) + float(coord.y < float(0.0)) * TAU;
  float segment_divider_A_angle_bisector = PI / r_gon_sides;
  float segment_divider_A_next_segment_divider = float(2.0) * segment_divider_A_angle_bisector;
  float segment_id = floor(x_axis_A_coord / segment_divider_A_next_segment_divider);
  float segment_divider_A_coord = x_axis_A_coord -
                                  segment_id * segment_divider_A_next_segment_divider;
  float segment_divider_A_bevel_start = segment_divider_A_angle_bisector -
                                        atan((float(1.0) - r_gon_roundness) *
                                              tan(segment_divider_A_angle_bisector));

  float last_angle_bisector_A_x_axis = PI -
                                       floor(r_gon_sides) * segment_divider_A_angle_bisector;
  float last_segment_divider_A_x_axis = float(2.0) * last_angle_bisector_A_x_axis;
  float inner_last_bevel_start_A_x_axis = last_angle_bisector_A_x_axis -
                                          atan((float(1.0) - r_gon_roundness) *
                                                tan(last_angle_bisector_A_x_axis));
  float l_last_circle_radius = r_gon_roundness * tan(last_angle_bisector_A_x_axis) /
                               tan(float(0.5) * (segment_divider_A_angle_bisector +
                                                  last_angle_bisector_A_x_axis));
  vec2 last_circle_center = vec2(
      (cos(inner_last_bevel_start_A_x_axis) /
       cos(last_angle_bisector_A_x_axis - inner_last_bevel_start_A_x_axis)) -
          l_last_circle_radius * cos(last_angle_bisector_A_x_axis),
      l_last_circle_radius * sin(last_angle_bisector_A_x_axis) -
          (sin(inner_last_bevel_start_A_x_axis) /
           cos(last_angle_bisector_A_x_axis - inner_last_bevel_start_A_x_axis)));
  vec2 outer_last_bevel_start = last_circle_center +
                                  l_last_circle_radius *
                                      vec2(cos(segment_divider_A_angle_bisector),
                                                  sin(segment_divider_A_angle_bisector));
  float x_axis_A_outer_last_bevel_start = atan(outer_last_bevel_start.y /
                                                outer_last_bevel_start.x);
  float outer_last_bevel_start_A_angle_bisector = segment_divider_A_angle_bisector -
                                                  x_axis_A_outer_last_bevel_start;

  if ((x_axis_A_coord >= x_axis_A_outer_last_bevel_start) &&
      (x_axis_A_coord < TAU - last_segment_divider_A_x_axis - x_axis_A_outer_last_bevel_start))
  {
    float bevel_start_A_angle_bisector = segment_divider_A_angle_bisector -
                                         segment_divider_A_bevel_start;

    if (((segment_divider_A_coord >= segment_divider_A_bevel_start) &&
         (segment_divider_A_coord <
          segment_divider_A_next_segment_divider - segment_divider_A_bevel_start)) ||
        (x_axis_A_coord >=
         TAU - last_segment_divider_A_x_axis - segment_divider_A_bevel_start) ||
        (x_axis_A_coord < segment_divider_A_bevel_start))
    {
      

      float l_angle_bisector = float(0.0);
      float r_gon_parameter = float(0.0);
      float max_unit_parameter = float(0.0);

      l_angle_bisector = l_coord *
                         cos(segment_divider_A_angle_bisector - segment_divider_A_coord);

      float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                         segment_divider_A_bevel_start;

      if ((x_axis_A_coord >=
           TAU - last_segment_divider_A_x_axis - segment_divider_A_angle_bisector) ||
          (x_axis_A_coord < segment_divider_A_angle_bisector))
      {
        

        float effective_roundness = float(1.0) - tan(segment_divider_A_angle_bisector -
                                                      x_axis_A_outer_last_bevel_start) /
                                                     tan(segment_divider_A_angle_bisector);
        float spline_start_outer_last_bevel_start = (float(1.0) - effective_roundness) *
                                                    x_axis_A_outer_last_bevel_start;

        if ((calculate_r_gon_parameter_field)) {
          r_gon_parameter = l_angle_bisector * tan(abs(segment_divider_A_angle_bisector -
                                                          segment_divider_A_coord));
          if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(outer_last_bevel_start_A_angle_bisector) +
                spline_start_outer_last_bevel_start *
                    (float(0.5) * l_angle_bisector + float(0.5)) +
                effective_roundness * x_axis_A_outer_last_bevel_start;

            r_gon_parameter /= normalize_based_on_l_angle_bisector;
          }
        }
      }
      else {
        

        float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                           segment_divider_A_bevel_start;

        if ((calculate_r_gon_parameter_field)) {
          r_gon_parameter = l_angle_bisector * tan(abs(segment_divider_A_angle_bisector -
                                                          segment_divider_A_coord));
          if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(bevel_start_A_angle_bisector) +
                spline_start_A_bevel_start * (float(0.5) * l_angle_bisector + float(0.5)) +
                r_gon_roundness * segment_divider_A_bevel_start;

            r_gon_parameter /= normalize_based_on_l_angle_bisector;
          }
        }
      }

      if ((calculate_r_gon_parameter_field)) {
        r_gon_parameter = l_angle_bisector *
                          tan(abs(segment_divider_A_angle_bisector - segment_divider_A_coord));
        if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
          r_gon_parameter *= -float(1.0);
        }

        if (normalize_r_gon_parameter) {
          if ((x_axis_A_coord >=
               TAU - last_segment_divider_A_x_axis - segment_divider_A_angle_bisector) ||
              (x_axis_A_coord < segment_divider_A_angle_bisector))
          {
            

            float effective_roundness = float(1.0) - tan(segment_divider_A_angle_bisector -
                                                          x_axis_A_outer_last_bevel_start) /
                                                         tan(segment_divider_A_angle_bisector);
            float spline_start_outer_last_bevel_start = (float(1.0) - effective_roundness) *
                                                        x_axis_A_outer_last_bevel_start;

            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(outer_last_bevel_start_A_angle_bisector) +
                spline_start_outer_last_bevel_start *
                    (float(0.5) * l_angle_bisector + float(0.5)) +
                effective_roundness * x_axis_A_outer_last_bevel_start;

            r_gon_parameter /= normalize_based_on_l_angle_bisector;
          }
          else {
            

            float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                               segment_divider_A_bevel_start;

            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(bevel_start_A_angle_bisector) +
                spline_start_A_bevel_start * (float(0.5) * l_angle_bisector + float(0.5)) +
                r_gon_roundness * segment_divider_A_bevel_start;

            r_gon_parameter /= normalize_based_on_l_angle_bisector;
          }
        }
      }
      if ((calculate_max_unit_parameter)) {
        max_unit_parameter = tan(bevel_start_A_angle_bisector) + spline_start_A_bevel_start +
                             r_gon_roundness * segment_divider_A_bevel_start;
      }
      return vec4(l_angle_bisector,
                         r_gon_parameter,
                         max_unit_parameter,
                         segment_id * segment_divider_A_next_segment_divider +
                             segment_divider_A_angle_bisector);
    }
    else {
      

      
      float nearest_segment_divider_SA_coord = segment_divider_A_coord -
                                               float(segment_divider_A_coord >
                                                     segment_divider_A_angle_bisector) *
                                                   segment_divider_A_next_segment_divider;
      float l_angle_bisector = float(0.0);
      float r_gon_parameter = float(0.0);
      float max_unit_parameter = float(0.0);

      float l_circle_center = (float(1.0) - r_gon_roundness) /
                              cos(segment_divider_A_angle_bisector);
      float l_coord_R_l_bevel_start = cos(nearest_segment_divider_SA_coord) * l_circle_center +
                                      sqrt(nexus_rt_sqr(cos(nearest_segment_divider_SA_coord) *
                                                l_circle_center) +
                                            nexus_rt_sqr(r_gon_roundness) - nexus_rt_sqr(l_circle_center));

      l_angle_bisector = l_coord / l_coord_R_l_bevel_start;

      float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                         segment_divider_A_bevel_start;

      if ((calculate_r_gon_parameter_field)) {
        float coord_A_bevel_start = segment_divider_A_bevel_start -
                                    abs(nearest_segment_divider_SA_coord);
        r_gon_parameter = l_coord * sin(bevel_start_A_angle_bisector);

        if (coord_A_bevel_start < spline_start_A_bevel_start) {
          r_gon_parameter += l_coord * cos(bevel_start_A_angle_bisector) * coord_A_bevel_start +
                             float(0.5) *
                                 (float(1.0) - l_coord * cos(bevel_start_A_angle_bisector)) *
                                 nexus_rt_sqr(coord_A_bevel_start) / spline_start_A_bevel_start;
        }
        else {
          r_gon_parameter += spline_start_A_bevel_start *
                                 (float(0.5) * l_coord * cos(bevel_start_A_angle_bisector) -
                                  float(0.5)) +
                             coord_A_bevel_start;
        }
        if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
          r_gon_parameter *= -float(1.0);
        }
        if (normalize_r_gon_parameter) {
          float normalize_based_on_l_angle_bisector =
              l_angle_bisector * tan(bevel_start_A_angle_bisector) +
              spline_start_A_bevel_start * (float(0.5) * l_angle_bisector + float(0.5)) +
              r_gon_roundness * segment_divider_A_bevel_start;
          float normalize_based_on_l_coord =
              l_coord * sin(bevel_start_A_angle_bisector) +
              spline_start_A_bevel_start *
                  (float(0.5) * l_coord * cos(bevel_start_A_angle_bisector) + float(0.5)) +
              r_gon_roundness * segment_divider_A_bevel_start;

          
          r_gon_parameter /= mix(normalize_based_on_l_angle_bisector,
                                 normalize_based_on_l_coord,
                                 coord_A_bevel_start / segment_divider_A_bevel_start);
        }
      }
      if ((calculate_max_unit_parameter)) {
        max_unit_parameter = tan(bevel_start_A_angle_bisector) + spline_start_A_bevel_start +
                             r_gon_roundness * segment_divider_A_bevel_start;
      }
      return vec4(l_angle_bisector,
                         r_gon_parameter,
                         max_unit_parameter,
                         segment_id * segment_divider_A_next_segment_divider +
                             segment_divider_A_angle_bisector);
    }
  }
  else {
    float inner_last_bevel_start_A_last_angle_bisector = last_angle_bisector_A_x_axis -
                                                         inner_last_bevel_start_A_x_axis;

    if ((x_axis_A_coord >=
         TAU - last_segment_divider_A_x_axis + inner_last_bevel_start_A_x_axis) &&
        (x_axis_A_coord < TAU - inner_last_bevel_start_A_x_axis))
    {
      

      float l_angle_bisector = float(0.0);
      float r_gon_parameter = float(0.0);
      float max_unit_parameter = float(0.0);

      float l_angle_bisector_R_l_last_angle_bisector = cos(segment_divider_A_angle_bisector) /
                                                       cos(last_angle_bisector_A_x_axis);
      float l_last_angle_bisector = l_coord *
                                    cos(last_angle_bisector_A_x_axis - segment_divider_A_coord);

      l_angle_bisector = l_angle_bisector_R_l_last_angle_bisector * l_last_angle_bisector;

      float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                         inner_last_bevel_start_A_x_axis;

      if ((calculate_r_gon_parameter_field)) {
        r_gon_parameter = l_angle_bisector_R_l_last_angle_bisector * l_last_angle_bisector *
                          tan(abs(last_angle_bisector_A_x_axis - segment_divider_A_coord));
        if (segment_divider_A_coord < last_angle_bisector_A_x_axis) {
          r_gon_parameter *= -float(1.0);
        }
        if (normalize_r_gon_parameter) {
          float normalize_based_on_l_l_angle_bisector =
              l_angle_bisector_R_l_last_angle_bisector *
              (l_last_angle_bisector * tan(inner_last_bevel_start_A_last_angle_bisector) +
               spline_start_A_bevel_start * (float(0.5) * l_last_angle_bisector + float(0.5)) +
               r_gon_roundness * inner_last_bevel_start_A_x_axis);

          r_gon_parameter /= normalize_based_on_l_l_angle_bisector;
        }
      }
      if ((calculate_max_unit_parameter)) {
        max_unit_parameter = tan(inner_last_bevel_start_A_last_angle_bisector) +
                             l_angle_bisector_R_l_last_angle_bisector *
                                 (spline_start_A_bevel_start *
                                      ((float(0.5) / l_angle_bisector_R_l_last_angle_bisector) +
                                       float(0.5)) +
                                  r_gon_roundness * inner_last_bevel_start_A_x_axis);
      }
      return vec4(l_angle_bisector,
                         r_gon_parameter,
                         max_unit_parameter,
                         segment_id * segment_divider_A_next_segment_divider +
                             last_angle_bisector_A_x_axis);
    }
    else {
      

      
      float nearest_segment_divider_MSA_coord = atan(coord.y, coord.x);
      if ((x_axis_A_coord >=
           TAU - last_segment_divider_A_x_axis - x_axis_A_outer_last_bevel_start) &&
          (x_axis_A_coord < TAU - last_angle_bisector_A_x_axis))
      {
        nearest_segment_divider_MSA_coord += last_segment_divider_A_x_axis;
        nearest_segment_divider_MSA_coord *= -float(1.0);
      }
      float l_angle_bisector = float(0.0);
      float r_gon_parameter = float(0.0);
      float max_unit_parameter = float(0.0);
      float x_axis_A_angle_bisector = float(0.0);

      float l_coord_R_l_last_angle_bisector =
          sin(nearest_segment_divider_MSA_coord) * last_circle_center.y +
          cos(nearest_segment_divider_MSA_coord) * last_circle_center.x +
          sqrt(nexus_rt_sqr(sin(nearest_segment_divider_MSA_coord) * last_circle_center.y +
                    cos(nearest_segment_divider_MSA_coord) * last_circle_center.x) +
                nexus_rt_sqr(l_last_circle_radius) - nexus_rt_sqr(last_circle_center.x) - nexus_rt_sqr(last_circle_center.y));
      float l_angle_bisector_R_l_last_angle_bisector = cos(segment_divider_A_angle_bisector) /
                                                       cos(last_angle_bisector_A_x_axis);
      float l_last_angle_bisector = l_coord / l_coord_R_l_last_angle_bisector;

      l_angle_bisector = l_angle_bisector_R_l_last_angle_bisector * l_last_angle_bisector;

      if (nearest_segment_divider_MSA_coord < float(0.0)) {
        

        float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                           inner_last_bevel_start_A_x_axis;

        if ((calculate_r_gon_parameter_field)) {
          float coord_A_bevel_start = inner_last_bevel_start_A_x_axis -
                                      abs(nearest_segment_divider_MSA_coord);
          r_gon_parameter = l_angle_bisector_R_l_last_angle_bisector * l_coord *
                            sin(inner_last_bevel_start_A_last_angle_bisector);

          if (coord_A_bevel_start < spline_start_A_bevel_start) {
            r_gon_parameter +=
                l_angle_bisector_R_l_last_angle_bisector *
                (l_coord * cos(inner_last_bevel_start_A_last_angle_bisector) *
                     coord_A_bevel_start +
                 float(0.5) *
                     (float(1.0) - l_coord * cos(inner_last_bevel_start_A_last_angle_bisector)) *
                     nexus_rt_sqr(coord_A_bevel_start) / spline_start_A_bevel_start);
          }
          else {
            r_gon_parameter += l_angle_bisector_R_l_last_angle_bisector *
                               (spline_start_A_bevel_start *
                                    (float(0.5) * l_coord *
                                         cos(inner_last_bevel_start_A_last_angle_bisector) -
                                     float(0.5)) +
                                coord_A_bevel_start);
          }
          if (segment_divider_A_coord < last_angle_bisector_A_x_axis) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            float normalize_based_on_l_l_angle_bisector =
                l_last_angle_bisector * tan(inner_last_bevel_start_A_last_angle_bisector) +
                spline_start_A_bevel_start * (float(0.5) * l_last_angle_bisector + float(0.5)) +
                r_gon_roundness * inner_last_bevel_start_A_x_axis;
            float normalize_based_on_l_coord =
                l_coord * sin(inner_last_bevel_start_A_last_angle_bisector) +
                spline_start_A_bevel_start *
                    (float(0.5) * l_coord * cos(inner_last_bevel_start_A_last_angle_bisector) +
                     float(0.5)) +
                r_gon_roundness * inner_last_bevel_start_A_x_axis;

            
            r_gon_parameter /= l_angle_bisector_R_l_last_angle_bisector *
                               mix(normalize_based_on_l_l_angle_bisector,
                                   normalize_based_on_l_coord,
                                   coord_A_bevel_start / inner_last_bevel_start_A_x_axis);
          }
        }
        if ((calculate_max_unit_parameter)) {
          max_unit_parameter = tan(inner_last_bevel_start_A_last_angle_bisector) +
                               l_angle_bisector_R_l_last_angle_bisector *
                                   (spline_start_A_bevel_start *
                                        ((float(0.5) / l_angle_bisector_R_l_last_angle_bisector) +
                                         float(0.5)) +
                                    r_gon_roundness * inner_last_bevel_start_A_x_axis);
        }
        x_axis_A_angle_bisector = segment_id * segment_divider_A_next_segment_divider +
                                  last_angle_bisector_A_x_axis;
      }
      else {
        

        float effective_roundness = float(1.0) - tan(segment_divider_A_angle_bisector -
                                                      x_axis_A_outer_last_bevel_start) /
                                                     tan(segment_divider_A_angle_bisector);
        float spline_start_outer_last_bevel_start = (float(1.0) - effective_roundness) *
                                                    x_axis_A_outer_last_bevel_start;

        if ((calculate_r_gon_parameter_field)) {
          float coord_A_bevel_start = x_axis_A_outer_last_bevel_start -
                                      abs(nearest_segment_divider_MSA_coord);
          r_gon_parameter = l_coord * sin(outer_last_bevel_start_A_angle_bisector);

          if (coord_A_bevel_start < spline_start_outer_last_bevel_start) {
            r_gon_parameter += l_coord * cos(outer_last_bevel_start_A_angle_bisector) *
                                   coord_A_bevel_start +
                               float(0.5) *
                                   (float(1.0) -
                                    l_coord * cos(outer_last_bevel_start_A_angle_bisector)) *
                                   nexus_rt_sqr(coord_A_bevel_start) / spline_start_outer_last_bevel_start;
          }
          else {
            r_gon_parameter += spline_start_outer_last_bevel_start *
                                   (float(0.5) * l_coord *
                                        cos(outer_last_bevel_start_A_angle_bisector) -
                                    float(0.5)) +
                               coord_A_bevel_start;
          }
          if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(outer_last_bevel_start_A_angle_bisector) +
                spline_start_outer_last_bevel_start *
                    (float(0.5) * l_angle_bisector + float(0.5)) +
                effective_roundness * x_axis_A_outer_last_bevel_start;
            float normalize_based_on_l_coord =
                l_coord * sin(outer_last_bevel_start_A_angle_bisector) +
                spline_start_outer_last_bevel_start *
                    (float(0.5) * l_coord * cos(outer_last_bevel_start_A_angle_bisector) +
                     float(0.5)) +
                effective_roundness * x_axis_A_outer_last_bevel_start;

            
            r_gon_parameter /= mix(normalize_based_on_l_angle_bisector,
                                   normalize_based_on_l_coord,
                                   coord_A_bevel_start / x_axis_A_outer_last_bevel_start);
          }
        }
        if ((calculate_max_unit_parameter)) {
          float bevel_start_A_angle_bisector = segment_divider_A_angle_bisector -
                                               segment_divider_A_bevel_start;
          float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                             segment_divider_A_bevel_start;

          max_unit_parameter = tan(bevel_start_A_angle_bisector) + spline_start_A_bevel_start +
                               r_gon_roundness * segment_divider_A_bevel_start;
        }
        x_axis_A_angle_bisector = segment_id * segment_divider_A_next_segment_divider +
                                  segment_divider_A_angle_bisector;
      }
      return vec4(
          l_angle_bisector, r_gon_parameter, max_unit_parameter, x_axis_A_angle_bisector);
    }
  }
}

 vec4 nexus_calculate_out_variables(bool calculate_r_gon_parameter_field,
                                          bool calculate_max_unit_parameter,
                                          bool normalize_r_gon_parameter,
                                          float r_gon_sides,
                                          float r_gon_roundness,
                                          vec2 coord)
{


  float l_coord = sqrt(nexus_rt_sqr(coord.x) + nexus_rt_sqr(coord.y));
  vec4 out_variables;

  if (fract(r_gon_sides) == float(0.0)) {
    float x_axis_A_coord = atan(coord.y, coord.x) + float(coord.y < float(0.0)) * TAU;
    float segment_divider_A_angle_bisector = PI / r_gon_sides;
    float segment_divider_A_next_segment_divider = float(2.0) * segment_divider_A_angle_bisector;
    float segment_id = floor(x_axis_A_coord / segment_divider_A_next_segment_divider);
    float segment_divider_A_coord = x_axis_A_coord -
                                    segment_id * segment_divider_A_next_segment_divider;

    if (r_gon_roundness == float(0.0)) {
      

      float l_angle_bisector = float(0.0);
      float r_gon_parameter = float(0.0);
      float max_unit_parameter = float(0.0);

      l_angle_bisector = l_coord *
                         cos(segment_divider_A_angle_bisector - segment_divider_A_coord);

      if ((calculate_r_gon_parameter_field)) {
        r_gon_parameter = l_angle_bisector *
                          tan(abs(segment_divider_A_angle_bisector - segment_divider_A_coord));
        if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
          r_gon_parameter *= -float(1.0);
        }
        if (normalize_r_gon_parameter && (r_gon_sides != float(2.0))) {
          r_gon_parameter /= l_angle_bisector * tan(segment_divider_A_angle_bisector);
        }
      }
      if ((calculate_max_unit_parameter)) {
        max_unit_parameter = (r_gon_sides != float(2.0)) ? tan(segment_divider_A_angle_bisector) :
                                                           float(0.0);
      }
      out_variables = vec4(l_angle_bisector,
                                  r_gon_parameter,
                                  max_unit_parameter,
                                  segment_id * segment_divider_A_next_segment_divider +
                                      segment_divider_A_angle_bisector);
    }
    else if (r_gon_roundness == float(1.0)) {
      

      float r_gon_parameter = float(0.0);
      if ((calculate_r_gon_parameter_field)) {
        r_gon_parameter = abs(segment_divider_A_angle_bisector - segment_divider_A_coord);
        if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
          r_gon_parameter *= -float(1.0);
        }
        if (normalize_r_gon_parameter) {
          r_gon_parameter /= segment_divider_A_angle_bisector;
        }
      }
      out_variables = vec4(l_coord,
                                  r_gon_parameter,
                                  segment_divider_A_angle_bisector,
                                  segment_id * segment_divider_A_next_segment_divider +
                                      segment_divider_A_angle_bisector);
    }
    else {
      float segment_divider_A_bevel_start = segment_divider_A_angle_bisector -
                                            atan((float(1.0) - r_gon_roundness) *
                                                  tan(segment_divider_A_angle_bisector));
      float bevel_start_A_angle_bisector = segment_divider_A_angle_bisector -
                                           segment_divider_A_bevel_start;

      if ((segment_divider_A_coord >=
           segment_divider_A_next_segment_divider - segment_divider_A_bevel_start) ||
          (segment_divider_A_coord < segment_divider_A_bevel_start))
      {
        

        
        float nearest_segment_divider_SA_coord = segment_divider_A_coord -
                                                 float(segment_divider_A_coord >
                                                       segment_divider_A_angle_bisector) *
                                                     segment_divider_A_next_segment_divider;
        float l_angle_bisector = float(0.0);
        float r_gon_parameter = float(0.0);
        float max_unit_parameter = float(0.0);

        float l_circle_center = (float(1.0) - r_gon_roundness) /
                                cos(segment_divider_A_angle_bisector);
        float l_coord_R_l_bevel_start = cos(nearest_segment_divider_SA_coord) * l_circle_center +
                                        sqrt(nexus_rt_sqr(cos(nearest_segment_divider_SA_coord) *
                                                  l_circle_center) +
                                              nexus_rt_sqr(r_gon_roundness) - nexus_rt_sqr(l_circle_center));

        l_angle_bisector = l_coord / l_coord_R_l_bevel_start;

        float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                           segment_divider_A_bevel_start;

        if ((calculate_r_gon_parameter_field)) {
          float coord_A_bevel_start = segment_divider_A_bevel_start -
                                      abs(nearest_segment_divider_SA_coord);
          r_gon_parameter = l_coord * sin(bevel_start_A_angle_bisector);

          if (coord_A_bevel_start < spline_start_A_bevel_start) {
            r_gon_parameter += l_coord * cos(bevel_start_A_angle_bisector) * coord_A_bevel_start +
                               float(0.5) *
                                   (float(1.0) - l_coord * cos(bevel_start_A_angle_bisector)) *
                                   nexus_rt_sqr(coord_A_bevel_start) / spline_start_A_bevel_start;
          }
          else {
            r_gon_parameter += spline_start_A_bevel_start *
                                   (float(0.5) * l_coord * cos(bevel_start_A_angle_bisector) -
                                    float(0.5)) +
                               coord_A_bevel_start;
          }
          if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(bevel_start_A_angle_bisector) +
                spline_start_A_bevel_start * (float(0.5) * l_angle_bisector + float(0.5)) +
                r_gon_roundness * segment_divider_A_bevel_start;
            float normalize_based_on_l_coord =
                l_coord * sin(bevel_start_A_angle_bisector) +
                spline_start_A_bevel_start *
                    (float(0.5) * l_coord * cos(bevel_start_A_angle_bisector) + float(0.5)) +
                r_gon_roundness * segment_divider_A_bevel_start;

            
            r_gon_parameter /= mix(normalize_based_on_l_angle_bisector,
                                   normalize_based_on_l_coord,
                                   coord_A_bevel_start / segment_divider_A_bevel_start);
          }
        }
        if ((calculate_max_unit_parameter)) {
          max_unit_parameter = tan(bevel_start_A_angle_bisector) + spline_start_A_bevel_start +
                               r_gon_roundness * segment_divider_A_bevel_start;
        }
        out_variables = vec4(l_angle_bisector,
                                    r_gon_parameter,
                                    max_unit_parameter,
                                    segment_id * segment_divider_A_next_segment_divider +
                                        segment_divider_A_angle_bisector);
      }
      else {
        

        float l_angle_bisector = float(0.0);
        float r_gon_parameter = float(0.0);
        float max_unit_parameter = float(0.0);

        l_angle_bisector = l_coord *
                           cos(segment_divider_A_angle_bisector - segment_divider_A_coord);

        float spline_start_A_bevel_start = (float(1.0) - r_gon_roundness) *
                                           segment_divider_A_bevel_start;

        if ((calculate_r_gon_parameter_field)) {
          r_gon_parameter = l_angle_bisector * tan(abs(segment_divider_A_angle_bisector -
                                                          segment_divider_A_coord));
          if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            float normalize_based_on_l_angle_bisector =
                l_angle_bisector * tan(bevel_start_A_angle_bisector) +
                spline_start_A_bevel_start * (float(0.5) * l_angle_bisector + float(0.5)) +
                r_gon_roundness * segment_divider_A_bevel_start;

            r_gon_parameter /= normalize_based_on_l_angle_bisector;
          }
        }
        if ((calculate_max_unit_parameter)) {
          max_unit_parameter = tan(bevel_start_A_angle_bisector) + spline_start_A_bevel_start +
                               r_gon_roundness * segment_divider_A_bevel_start;
        }
        out_variables = vec4(l_angle_bisector,
                                    r_gon_parameter,
                                    max_unit_parameter,
                                    segment_id * segment_divider_A_next_segment_divider +
                                        segment_divider_A_angle_bisector);
      }
    }
  }
  else {
    if (r_gon_roundness == float(0.0)) {
      float x_axis_A_coord = atan(coord.y, coord.x) + float(coord.y < float(0.0)) * TAU;
      float segment_divider_A_angle_bisector = PI / r_gon_sides;
      float segment_divider_A_next_segment_divider = float(2.0) * segment_divider_A_angle_bisector;
      float segment_id = floor(x_axis_A_coord / segment_divider_A_next_segment_divider);
      float segment_divider_A_coord = x_axis_A_coord -
                                      segment_id * segment_divider_A_next_segment_divider;

      float last_angle_bisector_A_x_axis = PI -
                                           floor(r_gon_sides) * segment_divider_A_angle_bisector;
      float last_segment_divider_A_x_axis = float(2.0) * last_angle_bisector_A_x_axis;

      if (x_axis_A_coord < TAU - last_segment_divider_A_x_axis) {
        

        float l_angle_bisector = float(0.0);
        float r_gon_parameter = float(0.0);
        float max_unit_parameter = float(0.0);

        l_angle_bisector = l_coord *
                           cos(segment_divider_A_angle_bisector - segment_divider_A_coord);
        if ((calculate_r_gon_parameter_field)) {
          r_gon_parameter = l_angle_bisector * tan(abs(segment_divider_A_angle_bisector -
                                                          segment_divider_A_coord));
          if (segment_divider_A_coord < segment_divider_A_angle_bisector) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            r_gon_parameter /= l_angle_bisector * tan(segment_divider_A_angle_bisector);
          }
        }
        if ((calculate_max_unit_parameter)) {
          max_unit_parameter = tan(segment_divider_A_angle_bisector);
        }
        out_variables = vec4(l_angle_bisector,
                                    r_gon_parameter,
                                    max_unit_parameter,
                                    segment_id * segment_divider_A_next_segment_divider +
                                        segment_divider_A_angle_bisector);
      }
      else {
        

        float l_angle_bisector = float(0.0);
        float r_gon_parameter = float(0.0);
        float max_unit_parameter = float(0.0);

        float l_angle_bisector_R_l_last_angle_bisector = cos(segment_divider_A_angle_bisector) /
                                                         cos(last_angle_bisector_A_x_axis);
        float l_last_angle_bisector = l_coord *
                                      cos(last_angle_bisector_A_x_axis - segment_divider_A_coord);

        l_angle_bisector = l_angle_bisector_R_l_last_angle_bisector * l_last_angle_bisector;

        if ((calculate_r_gon_parameter_field)) {
          r_gon_parameter = l_angle_bisector_R_l_last_angle_bisector * l_last_angle_bisector *
                            tan(abs(last_angle_bisector_A_x_axis - segment_divider_A_coord));
          if (segment_divider_A_coord < last_angle_bisector_A_x_axis) {
            r_gon_parameter *= -float(1.0);
          }
          if (normalize_r_gon_parameter) {
            r_gon_parameter /= l_angle_bisector_R_l_last_angle_bisector * l_last_angle_bisector *
                               tan(last_angle_bisector_A_x_axis);
          }
        }
        if ((calculate_max_unit_parameter)) {
          max_unit_parameter = tan(last_angle_bisector_A_x_axis);
        }
        out_variables = vec4(l_angle_bisector,
                                    r_gon_parameter,
                                    max_unit_parameter,
                                    segment_id * segment_divider_A_next_segment_divider +
                                        last_angle_bisector_A_x_axis);
      }
    }

    else {
      out_variables = nexus_calculate_out_variables_irregular_circular(calculate_r_gon_parameter_field,
                                                                 calculate_max_unit_parameter,
                                                                 normalize_r_gon_parameter,
                                                                 r_gon_sides,
                                                                 r_gon_roundness,
                                                                 coord,
                                                                 l_coord);
    }
  }

  if ((coord.x == float(0.0)) && (coord.y == float(0.0))) {
    
    out_variables.y = float(0.0);
  }

  if (normalize_r_gon_parameter) {
    
    out_variables.y = float(0.5) * out_variables.y + float(0.5);
  }
  else {
    out_variables.x -= float(1.0);
  }

  return out_variables;
}

 float nexus_calculate_out_segment_id(float r_gon_sides, vec2 coord)
{
  return floor(r_gon_sides *
                ((atan(coord.y, coord.x) / TAU) + float(coord.y < float(0.0))));
}

void nexus_radial_tiling(vec2 coord, float sides, float roundness, bool normalize_flag,
	out vec3 segment_coordinates, out float segment_id, out float segment_width, out float segment_rotation)
{
	float sides_clamped = max(sides, 2.0);
	float roundness_clamped = clamp(roundness, 0.0, 1.0);
	vec4 out_variables = nexus_calculate_out_variables(
		true, true, normalize_flag, sides_clamped, roundness_clamped, coord);
	segment_coordinates = vec3(out_variables.y, out_variables.x, 0.0);
	segment_width = out_variables.z;
	segment_rotation = out_variables.w;
	segment_id = nexus_calculate_out_segment_id(sides_clamped, coord);
}
