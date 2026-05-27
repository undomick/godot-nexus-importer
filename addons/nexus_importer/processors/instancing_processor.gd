@tool
extends Object

## Replaces placeholder nodes with instanced scenes from asset_index or nexus_placeholder_path.

const PENDING_INSTANCES_META := "_nexus_pending_instances"

var _asset_index_cache: Dictionary = {}
var _asset_index_loaded: bool = false
var _warned_missing_paths: Dictionary = {}


func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var requested_path := ""
	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	var gltf_context: String = (" (in glTF: %s)" % gltf_path) if not gltf_path.is_empty() else ""

	if meta.has("nexus_placeholder_path"):
		requested_path = meta["nexus_placeholder_path"]
	elif meta.has("nexus_asset_id"):
		requested_path = _resolve_scene_path_from_asset_id(meta["nexus_asset_id"], root, gltf_context)
		if requested_path.is_empty():
			return false

	if requested_path.is_empty():
		return false

	var scene_path := NexusSceneUtils.resolve_packed_scene_path(requested_path)
	if scene_path.is_empty():
		_mark_pending_instance(root, node, requested_path, meta, gltf_context)
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


func _mark_pending_instance(
	root: Node,
	node: Node,
	requested_path: String,
	meta: Dictionary,
	gltf_context: String
) -> void:
	var pending = root.get_meta(PENDING_INSTANCES_META, [])
	if not pending is Array:
		pending = []
	pending.append({
		"requested_path": requested_path,
		"node_name": node.name,
		"asset_id": meta.get("nexus_asset_id", ""),
	})
	root.set_meta(PENDING_INSTANCES_META, pending)

	var asset_ref: String = (
		" Referenced by asset ID '%s'." % meta.get("nexus_asset_id", "")
		if meta.has("nexus_asset_id")
		else ""
	)
	if _warned_missing_paths.has(requested_path):
		return
	_warned_missing_paths[requested_path] = true
	push_warning(
		"Nexus Instancer: Target scene not found at '%s'.%s%s Placeholder kept; will retry on reimport."
		% [requested_path, asset_ref, gltf_context]
	)


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

	return base_gltf_path
