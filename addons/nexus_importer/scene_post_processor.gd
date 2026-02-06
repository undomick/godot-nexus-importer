@tool
extends EditorScenePostImportPlugin

## Adds godot_groups to the scene root during import (stored in .scn/.glb).

func _get_import_options(path: String):
	add_import_option("internal_nexus_path", path)

func _get_option_visibility(path, for_animation, option):
	return option != "internal_nexus_path"

func _post_process(scene: Node) -> void:
	var gltf_path = get_option_value("internal_nexus_path")
	var scene_meta = NexusUtils.get_nexus_metadata(gltf_path)
	if scene_meta.is_empty(): return

	# Set groups directly in the internal node.
	if scene_meta.has("godot_groups"):
		var groups = scene_meta["godot_groups"]
		if groups is Array:
			for group in groups:
				scene.add_to_group(group, true) # true = persistent
