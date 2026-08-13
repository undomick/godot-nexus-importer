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
	var path := lock_file_path()
	if not FileAccess.file_exists(path):
		return false
	var data := _read_lock()
	if data.is_empty():
		# Blender refreshes via atomic replace; persistent unreadable files are crash artifacts.
		var modified := FileAccess.get_modified_time(path)
		if modified <= 0.0 or (Time.get_unix_time_from_system() - modified) > 2.0:
			_remove_lock_file()
			return false
		return true
	if _is_stale(data):
		_remove_lock_file()
		return false
	return true

static func defer_path(path: String) -> void:
	if path.is_empty():
		return
	path = NexusUtils.canonical_res_path(path)
	if path.is_empty():
		return
	var ext := path.get_extension().to_lower()
	if ext in ["png", "jpg", "jpeg", "webp"]:
		var key := NexusUtils.dict_bind_path(_deferred_texture_paths, path)
		_deferred_texture_paths[key] = true
	elif ext in ["gltf", "glb"]:
		var key := NexusUtils.dict_bind_path(_deferred_gltf_paths, path)
		_deferred_gltf_paths[key] = true


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
	var text := NexusUtils.read_utf8_text(path)
	if text.is_empty():
		return {}
	var parsed = JSON.new()
	if parsed.parse(text) != OK:
		return {}
	var data = parsed.get_data()
	return data if data is Dictionary else {}


static func _is_stale(data: Dictionary) -> bool:
	var pid := int(data.get("pid", 0))
	if pid > 0 and _pid_alive(pid):
		return false
	var worker_pid := int(data.get("worker_pid", 0))
	if worker_pid > 0 and _pid_alive(worker_pid):
		return false
	if pid > 0 or worker_pid > 0:
		return true
	var updated := float(data.get("updated_at_unix", 0.0))
	if updated <= 0.0:
		return true
	return (Time.get_unix_time_from_system() - updated) > STALE_SECONDS


static func _pid_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	match OS.get_name():
		"Windows":
			var output: Array = []
			var args: PackedStringArray = PackedStringArray([
				"/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV",
			])
			var exit_code := OS.execute("tasklist", args, output, true)
			if exit_code != 0:
				return false
			return output.size() > 0 and str(output[0]).find(str(pid)) >= 0
		_:
			return OS.execute("kill", ["-0", str(pid)]) == 0


static func _remove_lock_file() -> void:
	var path := lock_file_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
