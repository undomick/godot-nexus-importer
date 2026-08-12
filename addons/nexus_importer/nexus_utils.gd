@tool
class_name NexusUtils
extends RefCounted

## Central utility functions for the Nexus Importer.
## Avoids duplicated metadata logic across plugin, import_post_processor and scene_post_processor.

const NEXUS_ASSET_META_KEY = "NEXUS_ASSET_METADATA"

static var _gltf_json_cache: Dictionary = {}
static var _warned_backslash_index_path: bool = false

## Magic and chunk type for binary glTF (.glb), little-endian.
const _GLB_MAGIC = 0x46546C67
const _GLB_CHUNK_JSON = 0x4E4F534A

## True if the path uses a glTF 2.0 container supported by Nexus (.gltf or .glb).
static func is_gltf_container_path(path: String) -> bool:
	var e := path.get_extension().to_lower()
	return e == "gltf" or e == "glb"

## Whether import should swap mesh materials to Nexus .tres via material_index.
## Typical shareable GLB sets material_pipeline=gltf and keeps embedded materials.
static func should_swap_nexus_materials(scene_meta: Dictionary) -> bool:
	return str(scene_meta.get("material_pipeline", "nexus")) != "gltf"

## Reads the UTF-8 JSON chunk from an open .glb file (must be at position 0). Returns "" on failure.
static func extract_json_text_from_glb_file(file: FileAccess) -> String:
	if file.get_length() < 20:
		return ""
	file.seek(0)
	if file.get_32() != _GLB_MAGIC:
		return ""
	var version := file.get_32()
	if version != 2:
		return ""
	file.get_32()
	var chunk_len := file.get_32()
	var chunk_type := file.get_32()
	if chunk_type != _GLB_CHUNK_JSON:
		return ""
	var data := file.get_buffer(chunk_len)
	if data.is_empty() or not _bytes_are_valid_utf8(data):
		return ""
	return data.get_string_from_utf8()

## Returns true when every byte sequence is valid UTF-8 (Godot 4.7 has no PackedByteArray.is_valid_utf8).
static func _bytes_are_valid_utf8(data: PackedByteArray) -> bool:
	var i := 0
	var size := data.size()
	while i < size:
		var b: int = data[i]
		if b < 0x80:
			i += 1
		elif (b & 0xE0) == 0xC0:
			if i + 1 >= size or (data[i + 1] & 0xC0) != 0x80:
				return false
			i += 2
		elif (b & 0xF0) == 0xE0:
			if i + 2 >= size:
				return false
			for j in range(1, 3):
				if (data[i + j] & 0xC0) != 0x80:
					return false
			i += 3
		elif (b & 0xF8) == 0xF0:
			if i + 3 >= size:
				return false
			for j in range(1, 4):
				if (data[i + j] & 0xC0) != 0x80:
					return false
			i += 4
		else:
			return false
	return true

static func file_has_binary_magic(data: PackedByteArray) -> bool:
	if data.size() < 2:
		return false
	# PNG
	if data.size() >= 4 and data[0] == 0x89 and data[1] == 0x50 and data[2] == 0x4E and data[3] == 0x47:
		return true
	# JPEG
	if data[0] == 0xFF and data[1] == 0xD8:
		return true
	# GIF
	if data.size() >= 3 and data[0] == 0x47 and data[1] == 0x49 and data[2] == 0x46:
		return true
	# RIFF (WebP, etc.)
	if data.size() >= 4 and data[0] == 0x52 and data[1] == 0x49 and data[2] == 0x46 and data[3] == 0x46:
		return true
	# GLB
	if data.size() >= 4 and data.decode_u32(0) == _GLB_MAGIC:
		return true
	return false

static func _read_file_bytes(path: String) -> PackedByteArray:
	if path.is_empty() or not FileAccess.file_exists(path):
		return PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var length := file.get_length()
	if length <= 0:
		file.close()
		return PackedByteArray()
	var data := file.get_buffer(length)
	file.close()
	return data

## Reads a text file as UTF-8. Returns "" if missing, unreadable, binary, or not valid UTF-8.
static func read_utf8_text(path: String) -> String:
	var data := _read_file_bytes(path)
	if data.is_empty():
		return ""
	if file_has_binary_magic(data):
		return ""
	if not _bytes_are_valid_utf8(data):
		return ""
	return data.get_string_from_utf8()

static func _file_byte_size(path: String) -> int:
	return _read_file_bytes(path).size()

## Loads a text config via parse(). Returns {"ok": bool, "corrupt": bool, "config": ConfigFile}.
static func load_text_config(path: String) -> Dictionary:
	var config := ConfigFile.new()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "corrupt": false, "config": config}

	var data := _read_file_bytes(path)
	if data.is_empty():
		return {"ok": false, "corrupt": false, "config": config}

	if file_has_binary_magic(data):
		return {"ok": false, "corrupt": true, "config": ConfigFile.new()}

	var text := ""
	if _bytes_are_valid_utf8(data):
		text = data.get_string_from_utf8()

	if text.is_empty():
		return {"ok": false, "corrupt": true, "config": ConfigFile.new()}

	if config.parse(text) != OK:
		return {"ok": false, "corrupt": true, "config": ConfigFile.new()}

	return {"ok": true, "corrupt": false, "config": config}

## Removes a .import sidecar that contains binary data instead of text. Returns true if deleted.
static func remove_corrupt_import_sidecar(path: String) -> bool:
	if not path.ends_with(".import") or not FileAccess.file_exists(path):
		return false
	var data := _read_file_bytes(path)
	if data.is_empty() or not file_has_binary_magic(data):
		return false
	var abs_path := ProjectSettings.globalize_path(path)
	return DirAccess.remove_absolute(abs_path) == OK

## Full glTF JSON as text: whole file for .gltf, JSON chunk for .glb.
static func get_gltf_json_text(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var mtime := FileAccess.get_modified_time(path)
	if _gltf_json_cache.has(path):
		var cached: Dictionary = _gltf_json_cache[path]
		if int(cached.get("mtime", -1)) == mtime:
			return str(cached.get("text", ""))
	var ext := path.get_extension().to_lower()
	if ext == "glb":
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			return ""
		var text := extract_json_text_from_glb_file(file)
		file.close()
		_gltf_json_cache[path] = {"mtime": mtime, "text": text}
		return text

	var text := read_utf8_text(path)
	_gltf_json_cache[path] = {"mtime": mtime, "text": text}
	return text


static func invalidate_gltf_json_cache(path: String = "") -> void:
	if path.is_empty():
		_gltf_json_cache.clear()
	else:
		_gltf_json_cache.erase(path)

## Ensures path has res:// prefix for Godot resource loading.
static func ensure_res_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	return "res://" + path

## Safe single path segment for export filenames (parity with Blender sanitize_path_segment).
## Preserves inner dots so Blender-unique names stay distinct on disk.
static func sanitize_path_segment(name: String) -> String:
	var cleaned := ""
	for ch in name:
		var code := ch.unicode_at(0)
		if ch == "/" or ch == "\\" or code < 32:
			cleaned += "_"
		else:
			cleaned += ch
	cleaned = cleaned.strip_edges()
	if cleaned.is_empty() or cleaned == "." or cleaned == "..":
		return "_"
	return cleaned


## Sanitizes a node name for Godot (removes @ . : / " % and ensures it does not start with a digit).
static func sanitize_node_name(name: String) -> String:
	if name.is_empty():
		return "Resonance"
	var s = name.replace("@", "_").replace(".", "_").replace(":", "_").replace("/", "_").replace("\"", "_").replace("%", "_")
	if s.length() > 0 and s[0] >= "0" and s[0] <= "9":
		s = "n_" + s
	return s if not s.is_empty() else "Resonance"

## Returns a name unique among direct children of parent (Godot-safe base).
## `exclude` (optional) is a child still present in parent that the caller is
## about to replace; it must not count as a name collision, otherwise the
## replacement would be suffixed _001 next to the still-present placeholder.
static func unique_sibling_name(parent: Node, base_name: String, exclude: Node = null) -> String:
	if parent == null:
		return sanitize_node_name(base_name)
	var safe := sanitize_node_name(base_name)
	if safe.is_empty():
		safe = "Node"
	if not _sibling_name_taken(parent, safe, exclude):
		return safe
	var suffix := 1
	while suffix < 10000:
		var candidate := "%s_%03d" % [safe, suffix]
		if not _sibling_name_taken(parent, candidate, exclude):
			return candidate
		suffix += 1
	return safe + "_dup"


static func _sibling_name_taken(parent: Node, child_name: String, exclude: Node = null) -> bool:
	for child in parent.get_children():
		if child == exclude:
			continue
		if child.name == child_name:
			return true
	return false

## Loads a JSON index file and filters non-object entries (parity with Blender _sanitize_index_entries).
## Returns {"ok": bool, "entries": Dictionary, "error": String}.
static func try_load_index_json(path: String, label: String = "index") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {
			"ok": false,
			"entries": {},
			"error": "%s not found at '%s'." % [label, path],
		}

	var text := read_utf8_text(path)
	if text.is_empty() and _file_byte_size(path) > 0:
		return {
			"ok": false,
			"entries": {},
			"error": "Could not read %s as UTF-8." % label,
		}

	var json := JSON.new()
	var parse_err := json.parse(text)
	if parse_err != OK:
		return {
			"ok": false,
			"entries": {},
			"error": "%s is not valid JSON." % label,
		}

	var data = json.get_data()
	if not data is Dictionary:
		return {
			"ok": false,
			"entries": {},
			"error": "%s root must be an object." % label,
		}

	return {
		"ok": true,
		"entries": _sanitize_index_entries(data, label),
		"error": "",
	}


## Convenience wrapper around try_load_index_json; logs errors when report_errors is true.
static func load_index_json(
	path: String,
	label: String = "index",
	report_errors: bool = true
) -> Dictionary:
	var result := try_load_index_json(path, label)
	if report_errors and not result.ok and not result.error.is_empty():
		push_error("Nexus: %s" % result.error)
	return result.entries


static func _sanitize_index_entries(data: Dictionary, label: String) -> Dictionary:
	var cleaned: Dictionary = {}
	for key in data.keys():
		var value = data[key]
		if value is Dictionary:
			cleaned[key] = value
		else:
			push_warning(
				"Nexus: %s entry '%s' has invalid type (expected object); skipping." % [label, key]
			)
	return cleaned


## Atomically writes a JSON index (temp file + replace). Returns false on failure.
static func atomic_write_index_json(path: String, data: Dictionary, label: String = "index") -> bool:
	var temp_path := path + ".tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		push_error("Nexus: Could not open temp file for %s write." % label)
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()

	var abs_path := ProjectSettings.globalize_path(path)
	var abs_temp := ProjectSettings.globalize_path(temp_path)

	# Prefer rename without deleting first (atomic on POSIX; keeps the old file if rename fails).
	var rename_err := DirAccess.rename_absolute(abs_temp, abs_path)
	if rename_err != OK and FileAccess.file_exists(path):
		var remove_err := DirAccess.remove_absolute(abs_path)
		if remove_err != OK:
			push_error("Nexus: Could not replace existing %s." % label)
			DirAccess.remove_absolute(abs_temp)
			return false
		rename_err = DirAccess.rename_absolute(abs_temp, abs_path)

	if rename_err != OK:
		push_error("Nexus: Could not finalize %s write." % label)
		if not FileAccess.file_exists(path) and FileAccess.file_exists(temp_path):
			var copy_err := DirAccess.copy_absolute(abs_temp, abs_path)
			if copy_err == OK:
				DirAccess.remove_absolute(abs_temp)
				return true
			push_error(
				"Nexus: %s replace failed after removing the existing file; "
				% label
				+ "new data kept at '%s' for manual recovery." % temp_path
			)
			return false
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(abs_temp)
		return false
	return true


## Validates a project-relative resource path (index entries or glTF metadata).
## Returns the full res:// path if safe, empty string otherwise.
## Rejects: paths with "..", absolute system paths. Backslashes are normalized.
static func validate_index_path(rel_path: String) -> String:
	if rel_path.is_empty():
		return ""
	var path = rel_path.strip_edges()
	if path.begins_with("res://"):
		path = path.substr(6)
	if path.contains("\\"):
		if not _warned_backslash_index_path:
			_warned_backslash_index_path = true
			push_warning(
				"Nexus: Index paths with backslashes are normalized to forward slashes."
			)
		path = path.replace("\\", "/")
	if path.contains("..") or path.begins_with("/"):
		return ""
	if path.is_empty():
		return ""
	return "res://" + path

## Canonical res:// glTF path for queue/dedup (accepts res:// or absolute under project root).
static func to_res_gltf_path(path: String) -> String:
	if path.is_empty():
		return ""
	var normalized := path.strip_edges().replace("\\", "/")
	if normalized.begins_with("res://"):
		return normalized
	var project_root := ProjectSettings.globalize_path("res://").replace("\\", "/")
	if project_root.is_empty():
		return ""
	if not project_root.ends_with("/"):
		project_root += "/"
	var absolute := normalized
	if not absolute.is_absolute_path():
		absolute = project_root.path_join(normalized)
	absolute = absolute.replace("\\", "/")
	if not absolute.begins_with(project_root):
		return ""
	return "res://" + absolute.substr(project_root.length())

## Reads NEXUS_ASSET_METADATA from a .gltf or .glb file.
## Checks extras, scenes[0].extras and asset.extras (in that order).
static func get_nexus_metadata(asset_path: String) -> Dictionary:
	var json_text := get_gltf_json_text(asset_path)
	if json_text.is_empty():
		return {}
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return {}
	var gltf_data = json.get_data()
	if not gltf_data is Dictionary:
		return {}

	var meta = gltf_data.get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	if meta.is_empty():
		meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	return meta
