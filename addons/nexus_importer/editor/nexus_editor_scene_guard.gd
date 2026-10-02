class_name NexusEditorSceneGuard
extends RefCounted

## Closes open glTF editor tabs before reimport.
## Inherited and wrapper tabs stay open across reimport and Blender re-export.
## Falls back to Godot's empty edited-root state when no keeper tab remains.
## Focus and close are split across calls so Godot 4.7+ edited_scene indices stay valid.

const SCENE_SWITCH_SETTLE_FRAMES := 2

const TAB_KIND_UNRELATED := &"unrelated"
const TAB_KIND_WRAPPER := &"wrapper"
const TAB_KIND_INHERITED := &"inherited"
const TAB_KIND_INSTANCED := &"instanced"
const TAB_KIND_AMBIGUOUS := &"ambiguous"

static var _busy: bool = false


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


static func is_inherited_or_wrapper_scene(scene_path: String) -> bool:
	var file_name := scene_path.get_file()
	return file_name.ends_with("_wrapper.tscn") or file_name.ends_with("_inherited.tscn")


## resources_reimporting must not close inherited or wrapper tabs.
## EditorNode has already stored the open instance Node* on that signal and
## still reads scene_file_path from it in reload_instances (resources_reimported).
static func manual_reimport_scene_plan(edited_path: String, gltf_path: String) -> Dictionary:
	var keep_open := false
	var edited := edited_path.replace("\\", "/").strip_edges()
	if is_inherited_or_wrapper_scene(edited):
		for related in related_paths_for_gltf(gltf_path):
			if related == edited:
				keep_open = true
				break
	return {
		"close_on_reimporting": false,
		"close_on_reimported": false,
		"reopen_path": "",
		"keep_open": keep_open,
	}


static func _tab_path_matches(path_a: String, path_b: String) -> bool:
	if path_a.is_empty() or path_b.is_empty():
		return false
	var a := path_a.replace("\\", "/").strip_edges()
	var b := path_b.replace("\\", "/").strip_edges()
	if a == b:
		return true
	return NexusUtils.path_identity_key(a) == NexusUtils.path_identity_key(b)


static func _is_imported_gltf_sidecar_tab(tab_path: String, gltf_path: String) -> bool:
	if tab_path.find(".godot/imported/") < 0:
		return false
	if tab_path.get_extension().to_lower() != "scn":
		return false
	var stem := gltf_path.get_file().get_basename()
	return not stem.is_empty() and tab_path.find(stem) >= 0


## Classify an open editor tab for a glTF being reimported.
## Wrapper and inherited Nexus scenes stay open; raw glTF / import-cache tabs close.
## Unrecognized related .tscn paths are ambiguous and must not be closed.
static func classify_open_scene_tab(open_tab_path: String, gltf_path: String) -> StringName:
	var tab := str(open_tab_path).replace("\\", "/").strip_edges()
	var gltf := NexusUtils.to_res_gltf_path(gltf_path)
	if gltf.is_empty():
		gltf = str(gltf_path).replace("\\", "/").strip_edges()
	if tab.is_empty() or gltf.is_empty():
		return TAB_KIND_UNRELATED

	var wrapper := NexusPaths.wrapper_path_for(gltf)
	var inherited := NexusPaths.inherited_path_for(gltf)
	if _tab_path_matches(tab, wrapper):
		return TAB_KIND_WRAPPER
	if _tab_path_matches(tab, inherited):
		return TAB_KIND_INHERITED

	if not _open_tab_related_to_gltf(tab, gltf):
		return TAB_KIND_UNRELATED

	var ext := tab.get_extension().to_lower()
	if ext == "gltf" or ext == "glb" or ext == "scn":
		return TAB_KIND_INSTANCED
	return TAB_KIND_AMBIGUOUS


static func _open_tab_related_to_gltf(tab: String, gltf: String) -> bool:
	if _tab_path_matches(tab, gltf):
		return true
	if NexusSceneUtils.gltf_identity_key(tab) == NexusSceneUtils.gltf_identity_key(gltf):
		return true
	var mapped := gltf_path_from_nexus_scene_path(tab)
	if not mapped.is_empty() and _tab_path_matches(mapped, gltf):
		return true
	return _is_imported_gltf_sidecar_tab(tab, gltf)


static func tabs_to_close_before_reimport(gltf_paths: Array, open_paths: Array) -> Dictionary:
	var closing: Array[String] = []
	var ambiguous: Array[String] = []
	var seen_close: Dictionary = {}
	var seen_ambiguous: Dictionary = {}

	for raw_gltf in gltf_paths:
		if not raw_gltf is String:
			continue
		var gltf_path: String = str(raw_gltf)
		if gltf_path.is_empty():
			continue
		for raw_open in open_paths:
			var tab_path := str(raw_open).replace("\\", "/").strip_edges()
			if tab_path.is_empty():
				continue
			match classify_open_scene_tab(tab_path, gltf_path):
				TAB_KIND_INSTANCED:
					if not seen_close.has(tab_path):
						seen_close[tab_path] = true
						closing.append(tab_path)
				TAB_KIND_AMBIGUOUS:
					if not seen_ambiguous.has(tab_path):
						seen_ambiguous[tab_path] = true
						ambiguous.append(tab_path)

	return {"closing": closing, "ambiguous": ambiguous}


static func paths_closed_on_gltf_refresh(open_paths: Array, gltf_path: String = "") -> Array[String]:
	if gltf_path.is_empty():
		var closing: Array[String] = []
		for raw in open_paths:
			var scene_path := str(raw).replace("\\", "/").strip_edges()
			if scene_path.is_empty():
				continue
			if is_inherited_or_wrapper_scene(scene_path):
				continue
			closing.append(scene_path)
		return closing
	return tabs_to_close_before_reimport([gltf_path], open_paths).get("closing", [])


static func should_close_tab_after_inherited_save(saved_path: String, was_open: bool) -> bool:
	if was_open and is_inherited_or_wrapper_scene(saved_path):
		return false
	return true


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
		var gltf := NexusUtils.to_res_gltf_path(str(raw_path))
		if gltf.is_empty():
			gltf = str(raw_path).replace("\\", "/").strip_edges()
		if not gltf.is_empty():
			blocking[gltf] = true
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


static func _open_scene_paths_for_close_plan(editor_interface: EditorInterface) -> Array:
	var open_paths: Array = []
	open_paths.append_array(editor_interface.get_open_scenes())
	var edited_root = editor_interface.get_edited_scene_root()
	if edited_root != null and not edited_root.scene_file_path.is_empty():
		var edited_path: String = edited_root.scene_file_path
		if edited_path not in open_paths:
			open_paths.append(edited_path)
	return open_paths


static func _collect_tabs_to_close(
	editor_interface: EditorInterface, gltf_paths: Array
) -> Array[String]:
	if editor_interface == null or gltf_paths.is_empty():
		return []
	var plan := tabs_to_close_before_reimport(gltf_paths, _open_scene_paths_for_close_plan(editor_interface))
	for raw_amb in plan.get("ambiguous", []):
		push_warning(
			"Nexus: Ambiguous open scene '%s' during glTF reimport; leaving tab open."
			% str(raw_amb)
		)
	return plan.get("closing", [])


static func _clear_edited_flag(editor_interface: EditorInterface) -> void:
	if editor_interface == null:
		return
	var root = editor_interface.get_edited_scene_root()
	if root != null and is_instance_valid(root):
		editor_interface.set_object_edited(root, false)


static func stabilize_editor_after_close(editor_interface: EditorInterface) -> void:
	if editor_interface == null:
		return
	if _busy:
		return

	_busy = true
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
	_busy = false


static func close_open_nexus_asset_tabs_if_any(editor_interface: EditorInterface) -> Dictionary:
	var gltf_paths := collect_gltf_paths_from_open_nexus_tabs(editor_interface)
	if gltf_paths.is_empty():
		return {"closed": PackedStringArray(), "remaining": 0}
	return close_open_scenes_for_reimport(editor_interface, gltf_paths)


## Close at most one blocking Nexus tab. Used for phased close from _process.
static func close_one_open_nexus_asset_tab_if_any(editor_interface: EditorInterface) -> Dictionary:
	var closed := PackedStringArray()
	var close_errors: Array = []
	if editor_interface == null:
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}
	if _busy:
		var busy_gltfs := collect_gltf_paths_from_open_nexus_tabs(editor_interface)
		var busy_remaining := _collect_tabs_to_close(editor_interface, busy_gltfs).size()
		return {"closed": closed, "close_errors": close_errors, "remaining": busy_remaining}

	var gltf_paths := collect_gltf_paths_from_open_nexus_tabs(editor_interface)
	if gltf_paths.is_empty():
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}

	var blocking := blocking_path_set_for_gltfs(gltf_paths)
	if blocking.is_empty():
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}

	var to_close := _collect_tabs_to_close(editor_interface, gltf_paths)
	if to_close.is_empty():
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}

	_busy = true
	NexusEditorViewportGuard.push_pause(editor_interface)
	var result := _close_one_blocking_tab(editor_interface, to_close)
	if result.get("closed_path", "") != "":
		closed.append(str(result["closed_path"]))
	if result.has("err"):
		close_errors.append({"path": result.get("closed_path", ""), "err": result["err"]})
	var remaining := _collect_tabs_to_close(editor_interface, gltf_paths).size()
	# Focus-only step still has tabs to close next frame - do not stabilize yet.
	if remaining == 0 and not result.has("focused_path"):
		_busy = false
		stabilize_editor_after_close(editor_interface)
		NexusEditorViewportGuard.pop_pause(editor_interface)
		return {"closed": closed, "close_errors": close_errors, "remaining": remaining}
	NexusEditorViewportGuard.pop_pause(editor_interface)
	_busy = false
	return {"closed": closed, "close_errors": close_errors, "remaining": remaining}


static func _scene_still_open(editor_interface: EditorInterface, scene_path: String) -> bool:
	if scene_path.is_empty():
		return false
	for open_path in editor_interface.get_open_scenes():
		if open_path == scene_path:
			return true
	var edited_root = editor_interface.get_edited_scene_root()
	if edited_root != null and is_instance_valid(edited_root) and edited_root.scene_file_path == scene_path:
		return true
	return false


## Close current blocking tab, or focus a blocking tab without closing (two-phase).
## Returns {"closed_path","err"}, {"focused_path"}, or {}.
static func _close_one_blocking_tab(
	editor_interface: EditorInterface, to_close: Array[String]
) -> Dictionary:
	var edited_root = editor_interface.get_edited_scene_root()
	var edited_path := ""
	if edited_root != null and is_instance_valid(edited_root) and not edited_root.scene_file_path.is_empty():
		edited_path = edited_root.scene_file_path

	# Prefer closing the currently edited blocking tab - avoids open_scene_from_path.
	var scene_path := ""
	if not edited_path.is_empty() and edited_path in to_close:
		scene_path = edited_path
	else:
		for candidate in to_close:
			if _scene_still_open(editor_interface, candidate):
				scene_path = candidate
				break

	if scene_path.is_empty():
		return {}

	if edited_path != scene_path:
		if not _scene_still_open(editor_interface, scene_path):
			return {}
		_clear_edited_flag(editor_interface)
		editor_interface.open_scene_from_path(scene_path, false)
		# Do not close in the same call - Godot 4.7+ stale edited_scene index crash.
		return {"focused_path": scene_path}

	if editor_interface.get_edited_scene_root() == null:
		return {}
	_clear_edited_flag(editor_interface)
	var close_err := editor_interface.close_scene()
	return {"closed_path": scene_path, "err": close_err}


static func close_open_scenes_for_reimport(
	editor_interface: EditorInterface, gltf_paths: Array
) -> Dictionary:
	var closed := PackedStringArray()
	var close_errors: Array = []

	if editor_interface == null or gltf_paths.is_empty():
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}
	if _busy:
		var busy_remaining := _collect_tabs_to_close(editor_interface, gltf_paths).size()
		return {"closed": closed, "close_errors": close_errors, "remaining": busy_remaining}

	var to_close := _collect_tabs_to_close(editor_interface, gltf_paths)
	if to_close.is_empty():
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}

	_busy = true
	NexusEditorViewportGuard.push_pause(editor_interface)

	# Re-collect after each step. Focus and close are never in the same iteration.
	var safety := 0
	while safety < 64:
		safety += 1
		to_close = _collect_tabs_to_close(editor_interface, gltf_paths)
		if to_close.is_empty():
			break
		var result := _close_one_blocking_tab(editor_interface, to_close)
		if result.is_empty():
			break
		if result.has("focused_path"):
			# Next iteration closes the newly focused tab without another open.
			continue
		var closed_path := str(result.get("closed_path", ""))
		if closed_path != "":
			closed.append(closed_path)
		if result.has("err"):
			close_errors.append({"path": closed_path, "err": result["err"]})
		var close_err: int = int(result.get("err", FAILED))
		if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
			break

	_busy = false
	stabilize_editor_after_close(editor_interface)
	NexusEditorViewportGuard.pop_pause(editor_interface)

	var remaining := _collect_tabs_to_close(editor_interface, gltf_paths).size()
	return {"closed": closed, "close_errors": close_errors, "remaining": remaining}


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
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}
	if _busy:
		var busy_remaining := _collect_tabs_to_close(editor_interface, gltf_paths).size()
		return {"closed": closed, "close_errors": close_errors, "remaining": busy_remaining}

	var to_close := _collect_tabs_to_close(editor_interface, gltf_paths)
	if to_close.is_empty():
		return {"closed": closed, "close_errors": close_errors, "remaining": 0}

	_busy = true
	NexusEditorViewportGuard.push_pause(editor_interface)

	var safety := 0
	while safety < 64:
		safety += 1
		to_close = _collect_tabs_to_close(editor_interface, gltf_paths)
		if to_close.is_empty():
			break
		var result := _close_one_blocking_tab(editor_interface, to_close)
		if result.is_empty():
			break
		if result.has("focused_path"):
			await _settle_scene_tree(scene_tree)
			continue
		var closed_path := str(result.get("closed_path", ""))
		if closed_path != "":
			closed.append(closed_path)
		if result.has("err"):
			close_errors.append({"path": closed_path, "err": result["err"]})
		await _settle_scene_tree(scene_tree)
		var close_err: int = int(result.get("err", FAILED))
		if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
			break

	_busy = false
	stabilize_editor_after_close(editor_interface)
	await _settle_scene_tree(scene_tree)
	NexusEditorViewportGuard.pop_pause(editor_interface)

	var remaining := _collect_tabs_to_close(editor_interface, gltf_paths).size()
	return {"closed": closed, "close_errors": close_errors, "remaining": remaining}
