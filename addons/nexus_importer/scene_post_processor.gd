@tool
extends EditorScenePostImportPlugin

func _get_import_options(path: String):
	add_import_option("internal_nexus_path", path)

func _get_option_visibility(path, for_animation, option):
	return option != "internal_nexus_path"

func _post_process(scene: Node) -> void:
	if NexusBatchLock.is_active():
		return

	var gltf_path = get_option_value("internal_nexus_path")
	var scene_meta = NexusUtils.get_nexus_metadata(gltf_path)
	if scene_meta.is_empty(): return

	if scene_meta.has("godot_groups"):
		var groups = scene_meta["godot_groups"]
		if groups is Array:
			for group in groups:
				scene.add_to_group(group, true) # true = persistent
