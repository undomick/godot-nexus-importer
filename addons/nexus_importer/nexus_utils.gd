@tool
class_name NexusUtils
extends RefCounted

## Central utility functions for the Nexus Importer.
## Avoids duplicated metadata logic across plugin, import_post_processor and scene_post_processor.

const NEXUS_ASSET_META_KEY = "NEXUS_ASSET_METADATA"

## Magic and chunk type for binary glTF (.glb), little-endian.
const _GLB_MAGIC = 0x46546C67
const _GLB_CHUNK_JSON = 0x4E4F534A

## True if the path uses a glTF 2.0 container supported by Nexus (.gltf or .glb).
static func is_gltf_container_path(path: String) -> bool:
	var e := path.get_extension().to_lower()
	return e == "gltf" or e == "glb"

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
	return data.get_string_from_utf8()

## Full glTF JSON as text: whole file for .gltf, JSON chunk for .glb.
static func get_gltf_json_text(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var ext := path.get_extension().to_lower()
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return ""
	var text: String
	if ext == "glb":
		text = extract_json_text_from_glb_file(file)
	else:
		text = file.get_as_text()
	file.close()
	return text

## Ensures path has res:// prefix for Godot resource loading.
static func ensure_res_path(path: String) -> String:
	if path.begins_with("res://"):
		return path
	return "res://" + path

## Sanitizes a node name for Godot (removes @ . : / " % and ensures it does not start with a digit).
static func sanitize_node_name(name: String) -> String:
	if name.is_empty():
		return "Resonance"
	var s = name.replace("@", "_").replace(".", "_").replace(":", "_").replace("/", "_").replace("\"", "_").replace("%", "_")
	if s.length() > 0 and s[0] >= "0" and s[0] <= "9":
		s = "n_" + s
	return s if not s.is_empty() else "Resonance"

## Validates a path from asset/material index to prevent path traversal.
## Returns the full res:// path if safe, empty string otherwise.
## Rejects: paths with "..", paths escaping project, absolute system paths.
static func validate_index_path(rel_path: String) -> String:
	if rel_path.is_empty():
		return ""
	var path = rel_path.strip_edges()
	if path.begins_with("res://"):
		path = path.substr(6)
	if path.contains("..") or path.begins_with("/") or path.contains("\\"):
		return ""
	if path.is_empty():
		return ""
	return "res://" + path

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
