@tool
extends Object

## Applies vertex color attributes (e.g. Albedo Tint) from nexus_color_attributes.

func process(node: Node, meta: Dictionary) -> void:
	if not node is MeshInstance3D or not is_instance_valid(node.mesh):
		return
		
	if not meta.has("nexus_color_attributes"):
		return
	
	var attribute_settings: Array = meta["nexus_color_attributes"]
	var mesh_was_duplicated = false

	for settings in attribute_settings:
		var mapping = settings.get("mapping")
		var blender_name = settings.get("blender_name", "Unknown")
		var channel_index = settings.get("gltf_channel_index", -1) # 0 = COLOR_0
		
		if channel_index == -1: continue

		# Shader attribute name for info output
		var shader_attribute = "COLOR" if channel_index == 0 else "COLOR" + str(channel_index + 1)

		match mapping:
			"ALBEDO_TINT":
				if channel_index == 0:
					print_verbose(" -> Applying 'Albedo Tint' for layer '%s'." % blender_name)
					if not mesh_was_duplicated:
						node.mesh = node.mesh.duplicate()
						mesh_was_duplicated = true
					_apply_albedo_tint(node)
				else:
					push_warning("Nexus: Layer '%s' is on %s. Albedo Tint only works on COLOR. Use custom shader." % [blender_name, shader_attribute])

			_:
				print_verbose(" -> Layer '%s' mapped to %s for purpose '%s'." % [blender_name, shader_attribute, mapping])

func _apply_albedo_tint(node: MeshInstance3D) -> void:
	for surface_idx in range(node.mesh.get_surface_count()):
		var mat: Material = node.mesh.surface_get_material(surface_idx)
		if mat is StandardMaterial3D:
			var new_mat: StandardMaterial3D = mat.duplicate()
			new_mat.vertex_color_use_as_albedo = true
			node.mesh.surface_set_material(surface_idx, new_mat)
