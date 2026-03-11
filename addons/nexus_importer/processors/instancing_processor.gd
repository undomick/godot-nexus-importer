@tool
extends Object

## Replaces placeholder nodes with instanced scenes from asset_index or nexus_placeholder_path.

func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var scene_path = ""
	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	var gltf_context: String = (" (in glTF: %s)" % gltf_path) if not gltf_path.is_empty() else ""

	if meta.has("nexus_placeholder_path"):
		scene_path = meta["nexus_placeholder_path"]
		
	elif meta.has("nexus_asset_id"):
		var asset_id = meta["nexus_asset_id"]
		var asset_index_path = ProjectSettings.get_setting("nexus/import/asset_index_path", "res://asset_index.json")
		var file = FileAccess.open(asset_index_path, FileAccess.READ)
		if file:
			var json = JSON.new()
			var parse_ok = json.parse(file.get_as_text()) == OK
			if parse_ok:
				var asset_index = json.get_data()
				if asset_index.has(asset_id):
					var entry = asset_index[asset_id]
					if not entry is Dictionary:
						file.close()
						push_error("Nexus Instancer: Invalid index entry for Asset ID '%s'.%s" % [asset_id, gltf_context])
						return false
					var rel = entry.get("relative_path", "")
					var base_gltf_path = NexusUtils.validate_index_path(rel)
					if base_gltf_path.is_empty():
						file.close()
						push_error("Nexus Instancer: Invalid path in index for Asset ID '%s'.%s" % [asset_id, gltf_context])
						return false

					var parent_export_type = root.get_meta("_nexus_export_type", "")
					if parent_export_type == "LEVEL":
						var base = base_gltf_path.get_basename()
						var tscn_wrapper = base + "_wrapper.tscn"
						var tscn_inherited = base + "_inherited.tscn"
						if ResourceLoader.exists(tscn_wrapper):
							scene_path = tscn_wrapper
						elif ResourceLoader.exists(tscn_inherited):
							scene_path = tscn_inherited
						else:
							scene_path = base_gltf_path
					else:
						var base = base_gltf_path.get_basename()
						var editable_scene_path = base + "_editable.tscn"
						var tscn_wrapper = base + "_wrapper.tscn"
						var tscn_inherited = base + "_inherited.tscn"
						if ResourceLoader.exists(editable_scene_path):
							scene_path = editable_scene_path
						elif ResourceLoader.exists(tscn_wrapper):
							scene_path = tscn_wrapper
						elif ResourceLoader.exists(tscn_inherited):
							scene_path = tscn_inherited
						else:
							scene_path = base_gltf_path
				else:
					file.close()
					push_error("Nexus Instancer: Asset ID '%s' not found.%s" % [asset_id, gltf_context])
					return false
			else:
				push_error("Nexus Instancer: Failed to parse asset index at '%s'." % asset_index_path)
			file.close()

	if scene_path.is_empty(): return false

	if not ResourceLoader.exists(scene_path):
		var asset_ref: String = (" Referenced by asset ID '%s'." % meta.get("nexus_asset_id", "")) if meta.has("nexus_asset_id") else ""
		push_error("Nexus Instancer: Target scene not found at '%s'.%s%s" % [scene_path, asset_ref, gltf_context])
		return false

	var packed_scene = load(scene_path)
	if not packed_scene is PackedScene:
		push_error("Nexus Instancer: Resource at '%s' is not a PackedScene.%s" % [scene_path, gltf_context])
		return false
		
	var instance = packed_scene.instantiate()
	instance.name = node.name
	instance.transform = node.transform
	
	var parent = node.get_parent()
	if not parent: return false

	parent.remove_child(node)
	parent.add_child(instance)
	instance.owner = root
	
	node.free()

	print_verbose("Nexus Instancer: Replaced '%s' with instance of '%s'." % [instance.name, scene_path.get_file()])
	return true
