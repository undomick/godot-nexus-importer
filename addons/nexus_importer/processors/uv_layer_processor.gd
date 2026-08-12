@tool
extends Object

func process(node: Node, meta: Dictionary) -> void:
	if not node is MeshInstance3D:
		return
	if not meta.has("nexus_uv_layers"):
		return

	var layers: Array = meta["nexus_uv_layers"]
	if layers.is_empty():
		return

	for entry in layers:
		if not entry is Dictionary:
			continue
		var blender_name = entry.get("blender_name", "Unknown")
		var channel_index = entry.get("gltf_channel_index", -1)
		if channel_index < 0:
			continue
		var godot_channel = "UV" if channel_index == 0 else "UV2" if channel_index == 1 else "CUSTOM%d" % (channel_index - 2)
		print_verbose(
			" -> UV layer '%s' exported as TEXCOORD_%d (Godot %s)." % [blender_name, channel_index, godot_channel]
		)
