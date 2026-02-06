@tool
extends Object

## Replaces placeholder nodes with instanced scenes from asset_index or nexus_placeholder_path.

func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var scene_path = ""

	if meta.has("nexus_placeholder_path"):
		scene_path = meta["nexus_placeholder_path"]
		
	elif meta.has("nexus_asset_id"):
		var asset_id = meta["nexus_asset_id"]
		var asset_index_path = ProjectSettings.get_setting("nexus/import/asset_index_path", "res://asset_index.json")
		var file = FileAccess.open(asset_index_path, FileAccess.READ)
		if file:
			var json = JSON.new()
			if json.parse(file.get_as_text()) == OK:
				var asset_index = json.get_data()
				if asset_index.has(asset_id):
					var rel = asset_index[asset_id]["relative_path"]
					
					var base_gltf_path = _ensure_res_path(rel)
					
					var editable_scene_path = base_gltf_path.get_basename() + "_editable.tscn"
					scene_path = editable_scene_path if ResourceLoader.exists(editable_scene_path) else base_gltf_path
				else:
					push_error("Nexus Instancer: Asset ID '%s' not found." % asset_id)
					return false
	
	if scene_path.is_empty(): return false

	if not ResourceLoader.exists(scene_path):
		push_error("Nexus Instancer: Target scene not found at '%s'" % scene_path)
		return false

	var packed_scene = load(scene_path)
	if not packed_scene is PackedScene:
		push_error("Nexus Instancer: Resource at '%s' is not a PackedScene." % scene_path)
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
	
	print("Nexus Instancer: Replaced '%s' with instance of '%s'." % [instance.name, scene_path.get_file()])
	return true

# Helper to avoid double res://
func _ensure_res_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	return "res://" + path
