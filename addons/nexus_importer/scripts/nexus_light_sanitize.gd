class_name NexusLightSanitize
extends RefCounted

## Sanitize nexus_light metadata before applying Godot Light3D properties.

const MIN_RANGE := 0.001
const MIN_SHADOW_RANGE := 0.05
const DEFAULT_FINITE_RANGE := 40.0
const MIN_SPOT_ANGLE := 0.1
const MAX_SPOT_ANGLE := 179.9
const MIN_AREA_AXIS := 0.01
const DEFAULT_AREA_ATTENUATION := 1.0
const VALID_AREA_SHAPES := ["SQUARE", "DISK", "RECTANGLE", "ELLIPSE"]
const DEFAULT_DIR_SHADOW_DISTANCE := 100.0
const MIN_BASIS_DETERMINANT := 0.000001

static func sanitize_nexus_light_dict(data: Dictionary) -> Dictionary:
	var out := data.duplicate(true)
	var light_type := str(out.get("type", ""))

	match light_type:
		"point", "spot":
			out["range"] = _sanitize_finite_range(out.get("range", DEFAULT_FINITE_RANGE))
		"area":
			_sanitize_area_light(out)
		"sun":
			if _shadow_enabled(out) and not out.has("directional_shadow_max_distance"):
				out["directional_shadow_max_distance"] = DEFAULT_DIR_SHADOW_DISTANCE

	if light_type == "spot":
		out["spot_angle_deg"] = clampf(float(out.get("spot_angle_deg", 45.0)), MIN_SPOT_ANGLE, MAX_SPOT_ANGLE)

	if _shadow_enabled(out):
		if light_type in ["point", "spot", "area"]:
			var range_key := "range" if light_type != "area" else "area_range"
			var current_range := float(out.get(range_key, DEFAULT_FINITE_RANGE))
			out[range_key] = maxf(current_range, MIN_SHADOW_RANGE)
		if light_type == "sun" and out.has("directional_shadow_max_distance"):
			out["directional_shadow_max_distance"] = maxf(
				float(out["directional_shadow_max_distance"]),
				MIN_SHADOW_RANGE,
			)

	if out.has("gobo") and out["gobo"] is Dictionary:
		var gobo: Dictionary = out["gobo"].duplicate(true)
		var gobo_mode := str(gobo.get("mode", ""))
		if gobo_mode == "projector" and not _shadow_enabled(out):
			if light_type == "point":
				gobo["skip_projector"] = true
			elif light_type == "area":
				gobo["skip_projector"] = true
		out["gobo"] = gobo

	return out

static func sanitize_light_transform(transform: Transform3D) -> Transform3D:
	return NexusTransformSanitize.sanitize(transform, "light")

static func clamp_omni_range(value: float) -> float:
	return maxf(value, MIN_RANGE)

static func clamp_spot_range(value: float) -> float:
	return maxf(value, MIN_RANGE)

static func clamp_spot_angle(value: float) -> float:
	return clampf(value, MIN_SPOT_ANGLE, MAX_SPOT_ANGLE)

static func clamp_area_range(value: float, shadow_enabled: bool = false) -> float:
	var floor_value := MIN_SHADOW_RANGE if shadow_enabled else MIN_RANGE
	return maxf(value, floor_value)

static func clamp_area_size(size: Vector2) -> Vector2:
	return Vector2(maxf(size.x, MIN_AREA_AXIS), maxf(size.y, MIN_AREA_AXIS))

static func _sanitize_finite_range(value: Variant) -> float:
	var parsed := float(value)
	if parsed <= MIN_RANGE:
		return DEFAULT_FINITE_RANGE
	return parsed

static func _sanitize_area_size(value: Variant) -> Array:
	if (value is Array or value is PackedFloat32Array) and value.size() >= 2:
		var clamped := clamp_area_size(Vector2(float(value[0]), float(value[1])))
		return [clamped.x, clamped.y]
	return [1.0, 1.0]

static func _sanitize_area_light(out: Dictionary) -> void:
	out["area_range"] = _sanitize_finite_range(out.get("area_range", DEFAULT_FINITE_RANGE))
	out["area_size"] = _sanitize_area_size(out.get("area_size", [1.0, 1.0]))
	if out.has("area_shape"):
		out["area_shape"] = _sanitize_area_shape(out["area_shape"])
	if out.has("area_attenuation"):
		out["area_attenuation"] = _sanitize_area_attenuation(out["area_attenuation"])
	if out.has("area_normalize_energy"):
		out["area_normalize_energy"] = bool(out["area_normalize_energy"])
	if out.has("area_shadow_normal_bias"):
		out["area_shadow_normal_bias"] = maxf(float(out["area_shadow_normal_bias"]), 0.0)
	if out.has("light_size"):
		out["light_size"] = maxf(float(out["light_size"]), 0.0)

static func _sanitize_area_shape(value: Variant) -> String:
	var shape := str(value).to_upper()
	if shape in VALID_AREA_SHAPES:
		return shape
	return "SQUARE"

static func _sanitize_area_attenuation(value: Variant) -> float:
	var parsed := float(value)
	if not is_finite(parsed):
		return DEFAULT_AREA_ATTENUATION
	return maxf(parsed, 0.0)

static func _shadow_enabled(data: Dictionary) -> bool:
	return bool(data.get("shadow_enabled", data.get("use_shadow", false)))
