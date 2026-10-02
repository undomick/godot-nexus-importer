class_name NexusAssetIndexLookup
extends RefCounted

## Fallback asset_id -> glTF path resolution when asset_index.json is incomplete.
## Scans exported glTF manifests under res://props and res://assets (case-safe keys).

const _SCAN_ROOTS: Array[String] = ["res://props", "res://assets"]

static var _asset_id_to_gltf: Dictionary = {}
static var _index_mtime: int = -1


static func invalidate_cache() -> void:
	_asset_id_to_gltf.clear()
	_index_mtime = -1


static func _asset_index_mtime() -> int:
	var path := NexusPaths.asset_index_path()
	if not FileAccess.file_exists(path):
		return -1
	return FileAccess.get_modified_time(path)


static func _ensure_cache() -> void:
	var mtime := _asset_index_mtime()
	if mtime == _index_mtime and not _asset_id_to_gltf.is_empty():
		return
	_asset_id_to_gltf.clear()
	_index_mtime = mtime
	for root in _SCAN_ROOTS:
		if DirAccess.dir_exists_absolute(root):
			_scan_dir(root)
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path := str(entry.get("relative_path", "")).strip_edges()
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			continue
		_bind_asset_id(str(asset_id), gltf_path)


static func _scan_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			_scan_dir(full)
		else:
			var ext := name.get_extension().to_lower()
			if ext == "gltf" or ext == "glb":
				var meta := NexusUtils.get_nexus_metadata(full)
				var asset_id := str(meta.get("asset_id", "")).strip_edges()
				if not asset_id.is_empty():
					_bind_asset_id(asset_id, full)
		name = dir.get_next()
	dir.list_dir_end()


static func _bind_asset_id(asset_id: String, gltf_path: String) -> void:
	if asset_id.is_empty() or gltf_path.is_empty():
		return
	var canonical := NexusUtils.canonical_res_path(gltf_path)
	if canonical.is_empty():
		return
	_asset_id_to_gltf[asset_id] = canonical


static func gltf_path_for_asset_id(asset_id: String) -> String:
	var id := str(asset_id).strip_edges()
	if id.is_empty():
		return ""
	_ensure_cache()
	return str(_asset_id_to_gltf.get(id, ""))


static func index_entry_for_asset_id(asset_id: String) -> Dictionary:
	var gltf_path := gltf_path_for_asset_id(asset_id)
	if gltf_path.is_empty():
		return {}
	var rel := gltf_path.replace("res://", "")
	return {"relative_path": rel}
