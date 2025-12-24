@tool
extends EditorScenePostImportPlugin

# This processor only adds internal data (groups) that should be stored directly in the .scn / .glb.
# It does NOT touch .tscn wrappers anymore.

func _get_import_options(path: String):
	add_import_option("internal_nexus_path", path)

func _get_option_visibility(path, for_animation, option):
	return option != "internal_nexus_path"

func _post_process(scene: Node) -> void:
	var gltf_path = get_option_value("internal_nexus_path")
	var scene_meta = _get_nexus_metadata(gltf_path)
	if scene_meta.is_empty(): return

	# Set groups directly in the internal node.
	if scene_meta.has("godot_groups"):
		var groups = scene_meta["godot_groups"]
		if groups is Array:
			for group in groups:
				scene.add_to_group(group, true) # true = persistent

func _get_nexus_metadata(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path): return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return {}
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return {}
	var gltf_data = json.get_data()
	
	var meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	return meta
