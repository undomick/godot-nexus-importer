class_name NexusEditorSceneGuard
extends RefCounted

## Closes open glTF, wrapper, and inherited editor tabs before reimport.
## Falls back to Godot's empty edited-root state when no keeper tab remains.

const SCENE_SWITCH_SETTLE_FRAMES := 2


static func related_paths_for_gltf(gltf_path: String) -> PackedStringArray:
	var result := PackedStringArray()
	if gltf_path.is_empty():
		return result

	var canonical: String = gltf_path.replace("\\", "/").strip_edges()
	if canonical.is_empty():
		return result

	var res_path: String = NexusUtils.to_res_gltf_path(canonical)
	if res_path.is_empty():
		res_path = canonical

	result.append(res_path)
	result.append(NexusPaths.wrapper_path_for(res_path))
	result.append(NexusPaths.inherited_path_for(res_path))
	return result


static func gltf_path_from_nexus_scene_path(scene_path: String) -> String:
	if scene_path.is_empty():
		return ""
	var file_name: String = scene_path.get_file()
	var dir_path: String = scene_path.get_base_dir()
	var stem := ""
	if file_name.ends_with("_wrapper.tscn"):
		stem = file_name.trim_suffix("_wrapper.tscn")
	elif file_name.ends_with("_inherited.tscn"):
		stem = file_name.trim_suffix("_inherited.tscn")
	else:
		return ""
	if stem.is_empty():
		return ""
	for ext in ["gltf", "glb"]:
		var candidate := dir_path.path_join(stem + "." + ext)
		if ResourceLoader.exists(candidate) or FileAccess.file_exists(candidate):
			return candidate
	return ""


static func _register_open_gltf_path(gltf_paths: Dictionary, scene_path: String) -> void:
	if scene_path.is_empty():
		return
	var ext := scene_path.get_extension().to_lower()
	if ext == "gltf" or ext == "glb":
		gltf_paths[scene_path] = true
		return
	var base_gltf := gltf_path_from_nexus_scene_path(scene_path)
	if not base_gltf.is_empty():
		gltf_paths[base_gltf] = true


static func collect_gltf_paths_from_open_nexus_tabs(editor_interface: EditorInterface) -> Array:
	var gltf_paths: Dictionary = {}
	if editor_interface == null:
		return []

	for open_path in editor_interface.get_open_scenes():
		_register_open_gltf_path(gltf_paths, open_path)

	var edited_root = editor_interface.get_edited_scene_root()
	if edited_root != null and not edited_root.scene_file_path.is_empty():
		_register_open_gltf_path(gltf_paths, edited_root.scene_file_path)

	return gltf_paths.keys()


static func blocking_path_set_for_gltfs(gltf_paths: Array) -> Dictionary:
	var blocking: Dictionary = {}
	for raw_path in gltf_paths:
		if not raw_path is String:
			continue
		for related in related_paths_for_gltf(raw_path):
			blocking[related] = true
	return blocking


static func _find_keeper_scene_path(
	editor_interface: EditorInterface, to_close: Array[String]
) -> String:
	for open_path in editor_interface.get_open_scenes():
		if open_path.is_empty():
			continue
		if open_path in to_close:
			continue
		if ResourceLoader.exists(open_path) or FileAccess.file_exists(open_path):
			return open_path
	return ""


## True when the editor is in its neutral empty state (no real scene open).
## This is the fallback "keeper" now that no persistent guard scene exists.
static func is_neutral_editor_state(editor_interface: EditorInterface) -> bool:
	if editor_interface == null:
		return true
	var root = editor_interface.get_edited_scene_root()
	if root == null or not is_instance_valid(root):
		return true
	if root.scene_file_path.is_empty() and root.get_child_count() == 0:
		return true
	return false


static func _collect_tabs_to_close(
	editor_interface: EditorInterface, blocking: Dictionary
) -> Array[String]:
	var to_close: Array[String] = []
	for open_path in editor_interface.get_open_scenes():
		if blocking.has(open_path):
			to_close.append(open_path)

	var edited_root = editor_interface.get_edited_scene_root()
	if edited_root != null and not edited_root.scene_file_path.is_empty():
		var edited_path: String = edited_root.scene_file_path
		if blocking.has(edited_path) and edited_path not in to_close:
			to_close.append(edited_path)
	return to_close


static func _clear_edited_flag(editor_interface: EditorInterface) -> void:
	if editor_interface == null:
		return
	var root = editor_interface.get_edited_scene_root()
	if root != null and is_instance_valid(root):
		editor_interface.set_object_edited(root, false)


static func stabilize_editor_after_close(editor_interface: EditorInterface) -> void:
	if editor_interface == null:
		return

	NexusEditorViewportGuard.push_pause(editor_interface)
	var attempts := 0
	while attempts < 8:
		attempts += 1
		var open_scenes := editor_interface.get_open_scenes()
		var root = editor_interface.get_edited_scene_root()
		var root_valid := root != null and is_instance_valid(root)

		# Neutral empty state is a stable resting point - nothing to stabilize.
		if is_neutral_editor_state(editor_interface):
			break

		var only_phantom := not open_scenes.is_empty()
		for open_path in open_scenes:
			if not open_path.is_empty():
				only_phantom = false
				break

		if only_phantom and not root_valid:
			var close_err := editor_interface.close_scene()
			if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
				break
			continue

		if root_valid:
			break

		var keeper := _find_keeper_scene_path(editor_interface, [])
		if not keeper.is_empty():
			_clear_edited_flag(editor_interface)
			editor_interface.open_scene_from_path(keeper, false)
			break
		break
	NexusEditorViewportGuard.pop_pause(editor_interface)


static func close_open_nexus_asset_tabs_if_any(editor_interface: EditorInterface) -> Dictionary:
	var gltf_paths := collect_gltf_paths_from_open_nexus_tabs(editor_interface)
	if gltf_paths.is_empty():
		return {"closed": PackedStringArray()}
	return close_open_scenes_for_reimport(editor_interface, gltf_paths)


static func close_open_scenes_for_reimport(
	editor_interface: EditorInterface, gltf_paths: Array
) -> Dictionary:
	var closed := PackedStringArray()
	var close_errors: Array = []

	if editor_interface == null or gltf_paths.is_empty():
		return {"closed": closed, "close_errors": close_errors}

	var blocking := blocking_path_set_for_gltfs(gltf_paths)
	if blocking.is_empty():
		return {"closed": closed, "close_errors": close_errors}

	var to_close := _collect_tabs_to_close(editor_interface, blocking)

	if to_close.is_empty():
		return {"closed": closed, "close_errors": close_errors}

	NexusEditorViewportGuard.push_pause(editor_interface)

	var edited_root = editor_interface.get_edited_scene_root()
	var edited_path := ""
	if edited_root != null and not edited_root.scene_file_path.is_empty():
		edited_path = edited_root.scene_file_path

	if not edited_path.is_empty() and edited_path in to_close:
		var keeper_path: String = _find_keeper_scene_path(editor_interface, to_close)
		if not keeper_path.is_empty():
			_clear_edited_flag(editor_interface)
			editor_interface.open_scene_from_path(keeper_path, false)

	for scene_path in to_close:
		edited_root = editor_interface.get_edited_scene_root()
		edited_path = ""
		if edited_root and not edited_root.scene_file_path.is_empty():
			edited_path = edited_root.scene_file_path
		if edited_path != scene_path:
			_clear_edited_flag(editor_interface)
			editor_interface.open_scene_from_path(scene_path, false)
		if editor_interface.get_edited_scene_root() == null:
			continue
		_clear_edited_flag(editor_interface)
		var close_err := editor_interface.close_scene()
		close_errors.append({"path": scene_path, "err": close_err})
		if close_err == OK or close_err == ERR_DOES_NOT_EXIST:
			closed.append(scene_path)

	stabilize_editor_after_close(editor_interface)
	NexusEditorViewportGuard.pop_pause(editor_interface)

	return {"closed": closed, "close_errors": close_errors}


static func _settle_scene_tree(scene_tree: SceneTree, frame_count: int = SCENE_SWITCH_SETTLE_FRAMES) -> void:
	if scene_tree == null:
		return
	for _i in frame_count:
		await scene_tree.process_frame


static func close_open_scenes_for_reimport_async(
	editor_interface: EditorInterface,
	gltf_paths: Array,
	scene_tree: SceneTree,
) -> Dictionary:
	var closed := PackedStringArray()
	var close_errors: Array = []

	if editor_interface == null or gltf_paths.is_empty():
		return {"closed": closed, "close_errors": close_errors}

	var blocking := blocking_path_set_for_gltfs(gltf_paths)
	if blocking.is_empty():
		return {"closed": closed, "close_errors": close_errors}

	var to_close := _collect_tabs_to_close(editor_interface, blocking)

	if to_close.is_empty():
		return {"closed": closed, "close_errors": close_errors}

	NexusEditorViewportGuard.push_pause(editor_interface)

	var edited_root = editor_interface.get_edited_scene_root()
	var edited_path := ""
	if edited_root != null and not edited_root.scene_file_path.is_empty():
		edited_path = edited_root.scene_file_path

	if not edited_path.is_empty() and edited_path in to_close:
		var keeper_path: String = _find_keeper_scene_path(editor_interface, to_close)
		if not keeper_path.is_empty():
			_clear_edited_flag(editor_interface)
			editor_interface.open_scene_from_path(keeper_path, false)
			await _settle_scene_tree(scene_tree)

	for scene_path in to_close:
		edited_root = editor_interface.get_edited_scene_root()
		edited_path = ""
		if edited_root and not edited_root.scene_file_path.is_empty():
			edited_path = edited_root.scene_file_path
		if edited_path != scene_path:
			_clear_edited_flag(editor_interface)
			editor_interface.open_scene_from_path(scene_path, false)
			await _settle_scene_tree(scene_tree)
		if editor_interface.get_edited_scene_root() == null:
			continue
		_clear_edited_flag(editor_interface)
		var close_err := editor_interface.close_scene()
		close_errors.append({"path": scene_path, "err": close_err})
		if close_err == OK or close_err == ERR_DOES_NOT_EXIST:
			closed.append(scene_path)
		await _settle_scene_tree(scene_tree)

	stabilize_editor_after_close(editor_interface)
	await _settle_scene_tree(scene_tree)
	NexusEditorViewportGuard.pop_pause(editor_interface)

	return {"closed": closed, "close_errors": close_errors}
