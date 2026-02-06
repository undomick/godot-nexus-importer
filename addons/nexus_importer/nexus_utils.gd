@tool
class_name NexusUtils
extends RefCounted

## Central utility functions for the Nexus Importer.
## Avoids duplicated metadata logic across plugin, import_post_processor and scene_post_processor.

const NEXUS_ASSET_META_KEY = "NEXUS_ASSET_METADATA"

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
		return {}
	var gltf_data = json.get_data()
	var meta = gltf_data.get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	if meta.is_empty():
		meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get(NEXUS_ASSET_META_KEY, {})
	return meta
