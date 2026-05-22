@tool
extends Object

## Replaces placeholder nodes with instanced scenes from asset_index or nexus_placeholder_path.

var _asset_index_cache: Dictionary = {}
var _asset_index_loaded: bool = false


func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var scene_path := ""
	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	var gltf_context: String = (" (in glTF: %s)" % gltf_path) if not gltf_path.is_empty() else ""

	if meta.has("nexus_placeholder_path"):
		scene_path = meta["nexus_placeholder_path"]
	elif meta.has("nexus_asset_id"):
		scene_path = _resolve_scene_path_from_asset_id(meta["nexus_asset_id"], root, gltf_context)
		if scene_path.is_empty():
			return false

	if scene_path.is_empty():
		return false

	if not ResourceLoader.exists(scene_path):
		var asset_ref: String = (
			" Referenced by asset ID '%s'." % meta.get("nexus_asset_id", "")
			if meta.has("nexus_asset_id")
			else ""
		)
		push_error(
			"Nexus Instancer: Target scene not found at '%s'.%s%s" % [scene_path, asset_ref, gltf_context]
		)
		return false

	var packed_scene = load(scene_path)
	if not packed_scene is PackedScene:
		push_error(
			"Nexus Instancer: Resource at '%s' is not a PackedScene.%s" % [scene_path, gltf_context]
		)
		return false

	var instance = packed_scene.instantiate()
	instance.name = node.name
	instance.transform = node.transform

	var parent = node.get_parent()
	if not parent:
		return false

	parent.remove_child(node)
	parent.add_child(instance)
	instance.owner = root
	node.free()

	print_verbose("Nexus Instancer: Replaced '%s' with instance of '%s'." % [instance.name, scene_path.get_file()])
	return true


func _load_asset_index() -> Dictionary:
	if _asset_index_loaded:
		return _asset_index_cache
	_asset_index_loaded = true
	var asset_index_path = NexusPaths.asset_index_path()
	if not FileAccess.file_exists(asset_index_path):
		return {}
	var file = FileAccess.open(asset_index_path, FileAccess.READ)
	if not file:
		return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	var data = json.get_data()
	file.close()
	if data is Dictionary:
		_asset_index_cache = data
	return _asset_index_cache


func _resolve_scene_path_from_asset_id(asset_id: String, root: Node, gltf_context: String) -> String:
	var asset_index = _load_asset_index()
	if not asset_index.has(asset_id):
		push_error("Nexus Instancer: Asset ID '%s' not found.%s" % [asset_id, gltf_context])
		return ""

	var entry = asset_index[asset_id]
	if not entry is Dictionary:
		push_error("Nexus Instancer: Invalid index entry for Asset ID '%s'.%s" % [asset_id, gltf_context])
		return ""

	var rel = entry.get("relative_path", "")
	var base_gltf_path = NexusUtils.validate_index_path(rel)
	if base_gltf_path.is_empty():
		push_error("Nexus Instancer: Invalid path in index for Asset ID '%s'.%s" % [asset_id, gltf_context])
		return ""

	var parent_export_type = root.get_meta("_nexus_export_type", "")
	if parent_export_type == "LEVEL":
		if ResourceLoader.exists(NexusPaths.wrapper_path_for(base_gltf_path)):
			return NexusPaths.wrapper_path_for(base_gltf_path)
		if ResourceLoader.exists(NexusPaths.inherited_path_for(base_gltf_path)):
			return NexusPaths.inherited_path_for(base_gltf_path)
		return base_gltf_path

	var base = base_gltf_path.get_basename()
	var editable_scene_path = base + "_editable.tscn"
	if ResourceLoader.exists(editable_scene_path):
		return editable_scene_path
	if ResourceLoader.exists(NexusPaths.wrapper_path_for(base_gltf_path)):
		return NexusPaths.wrapper_path_for(base_gltf_path)
	if ResourceLoader.exists(NexusPaths.inherited_path_for(base_gltf_path)):
		return NexusPaths.inherited_path_for(base_gltf_path)
	return base_gltf_path
