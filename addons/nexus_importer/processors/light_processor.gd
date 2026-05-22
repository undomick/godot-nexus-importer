@tool
extends Object

## Converts nexus_light metadata to OmniLight3D, SpotLight3D or DirectionalLight3D.

func process(node: Node, meta: Dictionary, root: Node) -> bool:
	if not meta.has("nexus_light"): 
		return false
	
	var light_data = meta["nexus_light"]
	var parent = node.get_parent()
	if not parent: return false
	
	var new_light: Light3D = null
	match light_data.get("type"):
		"point": new_light = OmniLight3D.new()
		"spot": new_light = SpotLight3D.new()
		"sun": new_light = DirectionalLight3D.new()
		_:
			push_warning("Nexus Importer: Unknown light type '%s'" % light_data.get("type"))
			return false
			
	new_light.name = node.name
	new_light.transform = node.transform

	var c_arr = light_data.get("color", [1.0, 1.0, 1.0])
	if c_arr is Array and c_arr.size() >= 3:
		new_light.light_color = Color(c_arr[0], c_arr[1], c_arr[2])
	else:
		new_light.light_color = Color.WHITE

	# Blender radiant flux (W) to Godot energy: ~100 W ~= 1.0 energy.
	const BLENDER_WATTS_TO_GODOT = 0.01
	var raw_energy = light_data.get("energy", 1000.0)
	new_light.light_energy = raw_energy * BLENDER_WATTS_TO_GODOT
	if new_light is DirectionalLight3D:
		new_light.light_energy = min(new_light.light_energy, 5.0)

	new_light.shadow_enabled = light_data.get("use_shadow", false)
	new_light.shadow_bias = light_data.get("shadow_bias", 0.05) # Adjusted default bias
	new_light.shadow_blur = light_data.get("shadow_blur", 1.0)
	
	if new_light is OmniLight3D:
		new_light.omni_range = light_data.get("range", 5.0)
		new_light.omni_shadow_mode = OmniLight3D.SHADOW_CUBE if light_data.get("omni_shadow_mode") == "CUBE" else OmniLight3D.SHADOW_DUAL_PARABOLOID
	elif new_light is SpotLight3D:
		new_light.spot_range = light_data.get("range", 5.0)
		new_light.spot_angle = light_data.get("spot_angle_deg", 45.0)
		new_light.spot_angle_attenuation = light_data.get("spot_softness", 0.5)
	
	parent.remove_child(node)
	parent.add_child(new_light)
	new_light.owner = root
	
	node.free()
	
	return true
