@tool
extends Object

## Converts nexus_light metadata to OmniLight3D, SpotLight3D, DirectionalLight3D or AreaLight3D.

const BLENDER_WATTS_TO_GODOT := 0.01
const DIRECTIONAL_ENERGY_CAP := 5.0
const DEFAULT_SHADOW_BIAS := 0.03
const AREA_LIGHT_CLASS := "AreaLight3D"

func process(node: Node, meta: Dictionary, root: Node) -> bool:
	if not meta.has("nexus_light"):
		return false

	var light_data: Dictionary = NexusLightSanitize.sanitize_nexus_light_dict(meta["nexus_light"])
	var parent = node.get_parent()
	if not parent:
		return false

	var new_light: Light3D = null
	match light_data.get("type"):
		"point":
			new_light = OmniLight3D.new()
		"spot":
			new_light = SpotLight3D.new()
		"sun":
			new_light = DirectionalLight3D.new()
		"area":
			if ClassDB.class_exists(AREA_LIGHT_CLASS):
				new_light = ClassDB.instantiate(AREA_LIGHT_CLASS) as Light3D
			else:
				push_warning(
					"Nexus Importer: AreaLight3D requires Godot 4.7+. Using OmniLight3D fallback for '%s'."
					% node.name
				)
				new_light = OmniLight3D.new()
		_:
			push_warning("Nexus Importer: Unknown light type '%s'" % light_data.get("type"))
			return false

	new_light.name = node.name
	new_light.transform = NexusLightSanitize.sanitize_light_transform(node.transform)
	_apply_common_props(new_light, light_data)

	if new_light is OmniLight3D:
		_apply_omni_props(new_light as OmniLight3D, light_data)
	elif new_light is SpotLight3D:
		_apply_spot_props(new_light as SpotLight3D, light_data)
	elif new_light is DirectionalLight3D:
		_apply_directional_props(new_light as DirectionalLight3D, light_data)
	elif _is_area_light(new_light):
		_apply_area_props(new_light, light_data)

	_apply_gobo(new_light, light_data)
	_apply_node_visibility_props(new_light, meta)

	parent.remove_child(node)
	parent.add_child(new_light)
	new_light.owner = root
	node.free()
	return true

func _apply_common_props(light: Light3D, data: Dictionary) -> void:
	var c_arr = data.get("color", [1.0, 1.0, 1.0])
	if c_arr is Array and c_arr.size() >= 3:
		light.light_color = Color(c_arr[0], c_arr[1], c_arr[2])
	else:
		light.light_color = Color.WHITE

	var raw_energy = float(data.get("energy", 1000.0))
	if data.has("godot_energy"):
		light.light_energy = float(data["godot_energy"])
	else:
		light.light_energy = raw_energy * BLENDER_WATTS_TO_GODOT
		if light is DirectionalLight3D:
			light.light_energy = min(light.light_energy, DIRECTIONAL_ENERGY_CAP)

	var shadow_enabled = data.get("shadow_enabled", data.get("use_shadow", false))
	light.shadow_enabled = bool(shadow_enabled)
	light.shadow_bias = float(data.get("shadow_bias", DEFAULT_SHADOW_BIAS))
	light.shadow_blur = float(data.get("shadow_blur", 1.0))
	if data.has("shadow_normal_bias"):
		light.shadow_normal_bias = float(data["shadow_normal_bias"])
	if data.has("shadow_transmittance_bias"):
		light.shadow_transmittance_bias = float(data["shadow_transmittance_bias"])
	if data.has("shadow_opacity"):
		light.shadow_opacity = float(data["shadow_opacity"])
	if data.has("shadow_caster_mask"):
		light.shadow_caster_mask = int(data["shadow_caster_mask"])
	if data.has("shadow_reverse_cull_face"):
		light.shadow_reverse_cull_face = bool(data["shadow_reverse_cull_face"])

	if data.has("light_indirect_energy"):
		light.light_indirect_energy = float(data["light_indirect_energy"])
	if data.has("light_volumetric_fog_energy"):
		light.light_volumetric_fog_energy = float(data["light_volumetric_fog_energy"])
	if data.has("light_specular"):
		light.light_specular = float(data["light_specular"])
	if data.has("light_bake_mode"):
		light.light_bake_mode = int(data["light_bake_mode"])
	if data.has("light_cull_mask"):
		light.light_cull_mask = int(data["light_cull_mask"])
	if data.has("light_negative"):
		light.light_negative = bool(data["light_negative"])

func _apply_node_visibility_props(light: Light3D, meta: Dictionary) -> void:
	if meta.has("visible"):
		light.visible = bool(meta["visible"])
	if meta.has("cast_shadow") and str(meta["cast_shadow"]) == "OFF":
		light.shadow_enabled = false

func _apply_omni_props(light: OmniLight3D, data: Dictionary) -> void:
	light.omni_range = NexusLightSanitize.clamp_omni_range(float(data.get("range", 5.0)))
	if data.has("light_size"):
		light.light_size = maxf(float(data["light_size"]), 0.0)
	if data.has("omni_attenuation"):
		light.omni_attenuation = float(data["omni_attenuation"])
	if str(data.get("omni_shadow_mode", "")) == "DUAL_PARABOLOID":
		light.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	else:
		light.omni_shadow_mode = OmniLight3D.SHADOW_CUBE

func _apply_spot_props(light: SpotLight3D, data: Dictionary) -> void:
	light.spot_range = NexusLightSanitize.clamp_spot_range(float(data.get("range", 5.0)))
	light.spot_angle = NexusLightSanitize.clamp_spot_angle(float(data.get("spot_angle_deg", 45.0)))
	light.spot_angle_attenuation = float(data.get("spot_softness", 1.0))
	if data.has("light_size"):
		light.light_size = maxf(float(data["light_size"]), 0.0)
	if data.has("spot_attenuation"):
		light.spot_attenuation = float(data["spot_attenuation"])

func _apply_directional_props(light: DirectionalLight3D, data: Dictionary) -> void:
	if data.has("light_angular_distance"):
		light.light_angular_distance = float(data["light_angular_distance"])
	if data.has("light_size"):
		light.light_size = float(data["light_size"])
	if light.shadow_enabled:
		var shadow_distance = float(
			data.get("directional_shadow_max_distance", NexusLightSanitize.DEFAULT_DIR_SHADOW_DISTANCE)
		)
		light.directional_shadow_max_distance = maxf(shadow_distance, NexusLightSanitize.MIN_RANGE)

func _apply_area_props(light: Light3D, data: Dictionary) -> void:
	var area_size = data.get("area_size", [1.0, 1.0])
	if area_size is Array and area_size.size() >= 2:
		light.area_size = NexusLightSanitize.clamp_area_size(
			Vector2(float(area_size[0]), float(area_size[1]))
		)
	else:
		light.area_size = Vector2(1.0, 1.0)

	var shadow_enabled := bool(data.get("shadow_enabled", data.get("use_shadow", false)))
	light.area_range = NexusLightSanitize.clamp_area_range(
		float(data.get("area_range", 5.0)),
		shadow_enabled,
	)
	if data.has("area_attenuation"):
		light.area_attenuation = float(data["area_attenuation"])
	if data.has("area_normalize_energy"):
		light.area_normalize_energy = bool(data["area_normalize_energy"])
	if data.has("area_shadow_normal_bias") and not data.has("shadow_normal_bias"):
		light.shadow_normal_bias = float(data["area_shadow_normal_bias"])

	if data.has("light_size"):
		var pcss_size = float(data["light_size"])
		light.light_size = pcss_size if pcss_size > 0.0 else 0.5

func _apply_gobo(light: Light3D, data: Dictionary) -> void:
	if not data.has("gobo"):
		return

	var gobo: Dictionary = data["gobo"]
	if gobo.get("skip_projector", false):
		return

	var raw_tex_path := str(gobo.get("texture_path", ""))
	var tex_path := NexusUtils.validate_index_path(raw_tex_path)
	if tex_path.is_empty():
		if not raw_tex_path.is_empty():
			push_warning(
				"Nexus Importer: Rejected unsafe gobo texture path '%s' on light '%s'."
				% [raw_tex_path, light.name]
			)
		return

	var texture = load(tex_path)
	if texture == null:
		push_warning("Nexus Importer: Failed to load gobo texture '%s'." % tex_path)
		return

	var mode = str(gobo.get("mode", "projector"))
	var emission_strength = float(gobo.get("emission_strength", 1.0))
	var warnings = gobo.get("warnings", [])
	if warnings is Array:
		for warning in warnings:
			push_warning("Nexus Importer: Light '%s' gobo: %s" % [light.name, str(warning)])

	if _is_area_light(light) and mode == "area_surface":
		light.set("area_texture", texture)
		if emission_strength > 0.0 and abs(emission_strength - 1.0) > 0.0001:
			light.light_energy *= emission_strength
		return

	if mode == "projector":
		if data.get("shadow_enabled", data.get("use_shadow", false)):
			light.shadow_enabled = true
		light.light_projector = texture
		if emission_strength > 0.0 and abs(emission_strength - 1.0) > 0.0001:
			light.light_energy *= emission_strength

func _is_area_light(light: Light3D) -> bool:
	return light != null and light.get_class() == AREA_LIGHT_CLASS
