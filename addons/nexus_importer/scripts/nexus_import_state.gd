class_name NexusImportState
extends RefCounted

## Persists last successful import metadata per glTF to avoid redundant catch-up scans.

const STATE_PATH := "user://nexus_import_state.json"

static var _entries: Dictionary = {}
static var _loaded := false
static var _dirty := false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_entries = {}
	if not FileAccess.file_exists(STATE_PATH):
		return
	var text := FileAccess.get_file_as_string(STATE_PATH)
	if text.is_empty():
		return
	var parsed = JSON.new()
	if parsed.parse(text) != OK:
		return
	var data = parsed.get_data()
	if data is Dictionary:
		_entries = data


static func _save_if_dirty() -> void:
	if not _dirty:
		return
	var file := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_entries, "\t"))
	file.close()
	_dirty = false


static func get_entry(gltf_path: String) -> Dictionary:
	_ensure_loaded()
	var canonical := _canonical_path(gltf_path)
	if canonical.is_empty():
		return {}
	var entry = _entries.get(canonical, {})
	return entry if entry is Dictionary else {}


static func has_entry(gltf_path: String) -> bool:
	return not get_entry(gltf_path).is_empty()


static func mark_imported(gltf_path: String, index_content_hash: String = "") -> void:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return
	_ensure_loaded()
	var canonical := _canonical_path(gltf_path)
	if canonical.is_empty():
		return
	_entries[canonical] = {
		"last_import_mtime": FileAccess.get_modified_time(gltf_path),
		"last_content_hash": str(index_content_hash).strip_edges(),
	}
	_clear_build_abort_fields(canonical)
	_dirty = true
	_save_if_dirty()


static func mark_build_aborted(gltf_path: String, reason: String = "") -> void:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return
	_ensure_loaded()
	var canonical := _canonical_path(gltf_path)
	if canonical.is_empty():
		return
	var entry: Dictionary = _entries.get(canonical, {})
	if not entry is Dictionary:
		entry = {}
	entry["last_import_mtime"] = entry.get("last_import_mtime", FileAccess.get_modified_time(gltf_path))
	entry["last_content_hash"] = str(entry.get("last_content_hash", ""))
	entry["build_aborted_mtime"] = FileAccess.get_modified_time(gltf_path)
	var trimmed := str(reason).strip_edges()
	if not trimmed.is_empty():
		entry["build_abort_reason"] = trimmed
	_entries[canonical] = entry
	_dirty = true
	_save_if_dirty()


static func is_build_aborted(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var entry := get_entry(gltf_path)
	if not entry.has("build_aborted_mtime"):
		return false
	var locked_mtime := int(entry.get("build_aborted_mtime", -1))
	if FileAccess.get_modified_time(gltf_path) != locked_mtime:
		clear_build_abort(gltf_path)
		return false
	return true


static func clear_build_abort(gltf_path: String) -> void:
	_ensure_loaded()
	var canonical := _canonical_path(gltf_path)
	if canonical.is_empty() or not _entries.has(canonical):
		return
	if not _clear_build_abort_fields(canonical):
		return
	_dirty = true
	_save_if_dirty()


static func _clear_build_abort_fields(canonical: String) -> bool:
	if not _entries.has(canonical):
		return false
	var entry = _entries[canonical]
	if not entry is Dictionary:
		return false
	if not entry.has("build_aborted_mtime") and not entry.has("build_abort_reason"):
		return false
	entry.erase("build_aborted_mtime")
	entry.erase("build_abort_reason")
	_entries[canonical] = entry
	return true


static func is_unchanged_since_import(gltf_path: String, index_content_hash: String = "") -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var entry := get_entry(gltf_path)
	if entry.is_empty():
		return false
	var current_mtime := FileAccess.get_modified_time(gltf_path)
	if int(entry.get("last_import_mtime", -1)) != int(current_mtime):
		return false
	var hash := str(index_content_hash).strip_edges()
	if hash.is_empty():
		return true
	return str(entry.get("last_content_hash", "")) == hash


static func _canonical_path(gltf_path: String) -> String:
	return NexusUtils.canonical_res_path(gltf_path)
