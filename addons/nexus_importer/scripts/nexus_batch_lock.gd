class_name NexusBatchLock
extends RefCounted

## Defers Nexus import work while Blender batch export holds nexus_batch_export.lock.

const LOCK_FILENAME := "nexus_batch_export.lock"
const STALE_SECONDS := 300.0

static var _deferred_texture_paths: Dictionary = {}
static var _deferred_gltf_paths: Dictionary = {}


static func lock_file_path() -> String:
	return ProjectSettings.globalize_path("res://").path_join(LOCK_FILENAME)


static func is_active() -> bool:
	var data := _read_lock()
	if data.is_empty():
		return false
	if _is_stale(data):
		_remove_lock_file()
		return false
	return true


static func defer_path(path: String) -> void:
	if path.is_empty():
		return
	var ext := path.get_extension().to_lower()
	if ext in ["png", "jpg", "jpeg", "webp"]:
		_deferred_texture_paths[path] = true
	elif ext in ["gltf", "glb"]:
		_deferred_gltf_paths[path] = true


static func defer_paths(paths: Array) -> void:
	for entry in paths:
		if entry is String:
			defer_path(entry)


static func has_deferred_paths() -> bool:
	return not _deferred_texture_paths.is_empty() or not _deferred_gltf_paths.is_empty()


static func take_deferred_phased() -> Dictionary:
	var textures: Array[String] = []
	var gltfs: Array[String] = []
	for path in _deferred_texture_paths.keys():
		textures.append(path)
	for path in _deferred_gltf_paths.keys():
		gltfs.append(path)
	_deferred_texture_paths.clear()
	_deferred_gltf_paths.clear()
	return {"textures": textures, "gltfs": gltfs}


static func _read_lock() -> Dictionary:
	var path := lock_file_path()
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var parsed = JSON.new()
	if parsed.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	file.close()
	var data = parsed.get_data()
	return data if data is Dictionary else {}


static func _is_stale(data: Dictionary) -> bool:
	var updated := float(data.get("updated_at_unix", 0.0))
	if updated <= 0.0:
		return true
	return (Time.get_unix_time_from_system() - updated) > STALE_SECONDS


static func _remove_lock_file() -> void:
	var path := lock_file_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
