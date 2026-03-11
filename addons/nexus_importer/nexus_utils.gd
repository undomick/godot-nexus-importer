@tool
class_name NexusUtils
extends RefCounted

## Central utility functions for the Nexus Importer.
## Avoids duplicated metadata logic across plugin, import_post_processor and scene_post_processor.

const NEXUS_ASSET_META_KEY = "NEXUS_ASSET_METADATA"

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

## Reads NEXUS_ASSET_METADATA from a glTF file.
## Checks extras, scenes[0].extras and asset.extras (in that order).
static func get_nexus_metadata(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path):
		return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file:
		return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return {}
	var gltf_data = json.get_data()
	file.close()

	var meta = gltf_data.get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	if meta.is_empty():
		meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	return meta
