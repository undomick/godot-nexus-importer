class_name NexusWrapperBuilder
extends RefCounted

## Wrapper and inherited scene creation from imported glTF assets.

const NexusBatchLock = preload("res://addons/nexus_importer/scripts/nexus_batch_lock.gd")
const NexusEditorSceneGuard = preload(
	"res://addons/nexus_importer/editor/nexus_editor_scene_guard.gd"
)
const NexusExportOrder = preload("res://addons/nexus_importer/scripts/nexus_export_order.gd")
const NexusImportContext = preload("res://addons/nexus_importer/scripts/nexus_import_context.gd")
const InstancingProcessor = preload("res://addons/nexus_importer/processors/instancing_processor.gd")
const MultiMeshProcessor = preload("res://addons/nexus_importer/processors/multimesh_processor.gd")

const NEXUS_NODE_META := "NEXUS_NODE_METADATA"

const SCENE_LOAD_WAIT_FRAMES = 3
const INHERITED_OPEN_ATTEMPTS = 5
const INHERITED_OPEN_WAIT_FRAMES_PER_ATTEMPT = 60
# Max forced non-deferred reimports when an inherited build opens a composition
# glTF whose .import still holds unresolved instance placeholders.
const MAX_PLACEHOLDER_REIMPORT_RETRIES = 2
# Max consecutive inherited-open timeouts before a glTF is marked aborted so the
# re-queue loop stops instead of spinning forever (e.g. multimesh composite that
# cannot be recognized as the expected edit root).
const MAX_INHERITED_OPEN_TIMEOUTS = 2

var _plugin: EditorPlugin
var _queue: Dictionary = {}
var _inherited_creation_in_progress: bool = false
var _wrapper_creation_in_progress: bool = false
var _placeholder_retry_counts: Dictionary = {}
var _inherited_open_timeout_counts: Dictionary = {}
var _inherited_aborted: Dictionary = {}

var scan_when_idle: bool = false


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func is_busy() -> bool:
	return _inherited_creation_in_progress or _wrapper_creation_in_progress


func has_pending() -> bool:
	return not _queue.is_empty()


func is_scene_queued(gltf_path: String) -> bool:
	return _queue.has(gltf_path)


func _signal_wrapper_queue_idle() -> void:
	scan_when_idle = true


func queue_scene(gltf_path: String, scene_type: String = "") -> bool:
	if gltf_path.is_empty():
		return false
	if _inherited_aborted.has(gltf_path):
		return false
	if not NexusSceneUtils.should_create_packed_scene(gltf_path):
		return false
	if NexusSceneUtils.is_composition_gltf(gltf_path):
		if not NexusSceneUtils.is_thin_composition_gltf(gltf_path):
			push_warning(
				"Nexus: Skipping inherited scene for bloated composition '%s'. Re-export from Blender."
				% gltf_path.get_file()
			)
			return false
		if not NexusSceneUtils.composition_dependencies_ready(gltf_path):
			return false
	if NexusSceneUtils.is_multimesh_manifest(gltf_path):
		if not _multimesh_scene_queue_allowed(gltf_path):
			return false
	var explicit_style := not scene_type.is_empty()
	if scene_type.is_empty():
		scene_type = NexusSceneUtils.preferred_scene_style_for_gltf(gltf_path)
	if scene_type != NexusPaths.SCENE_STYLE_WRAPPER and scene_type != NexusPaths.SCENE_STYLE_INHERITED:
		return false
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_path(gltf_path)
		return true
	if _queue.has(gltf_path):
		if explicit_style:
			_queue[gltf_path] = scene_type
		return true
	_queue[gltf_path] = scene_type
	return true


func _multimesh_scene_queue_allowed(gltf_path: String) -> bool:
	return NexusSceneUtils.multimesh_can_queue_inherited_scene(gltf_path)


func queue_scenes_in_folder(folder_path: String, scene_type: String) -> int:
	if folder_path.is_empty() or scene_type.is_empty():
		return 0
	if scene_type != NexusPaths.SCENE_STYLE_WRAPPER and scene_type != NexusPaths.SCENE_STYLE_INHERITED:
		return 0
	if not DirAccess.dir_exists_absolute(folder_path):
		push_warning("Nexus: Folder not found: %s" % folder_path)
		return 0
	var gltf_paths = NexusSceneUtils.collect_gltfs_recursive(folder_path)
	var queued := 0
	for gltf_path in gltf_paths:
		if not NexusSceneUtils.should_create_packed_scene(gltf_path):
			continue
		queue_scene(gltf_path, scene_type)
		queued += 1
	if queued > 0:
		print_rich(
			"[color=cyan]Nexus Folder:[/color] Queued %d glTF(s) for %s scene creation."
			% [queued, scene_type]
		)
	return queued


func tick_scene_creation(reimport_manager: NexusReimportManager) -> bool:
	if _queue.is_empty():
		return false
	if reimport_manager.is_blocking_scene_creation() or _inherited_creation_in_progress or _wrapper_creation_in_progress:
		return false

	var file_to_process := _highest_priority_queued_path()
	if file_to_process.is_empty():
		return false
	var scene_type: String = _queue[file_to_process]
	_queue.erase(file_to_process)
	if scene_type == NexusPaths.SCENE_STYLE_INHERITED:
		_inherited_creation_in_progress = true
		build_inherited_scene_async(file_to_process)
	else:
		_wrapper_creation_in_progress = true
		build_wrapper_scene_async(file_to_process)
	return true


func _highest_priority_queued_path() -> String:
	if _queue.is_empty():
		return ""
	var best_path := ""
	var best_priority := NexusExportOrder.PRIORITY_OTHER + 1
	for path in _queue.keys():
		var priority := NexusExportOrder.export_type_priority_for_gltf(path)
		if priority < best_priority or (priority == best_priority and (best_path.is_empty() or path < best_path)):
			best_priority = priority
			best_path = path
	return best_path


func needs_scene_processing(gltf_path: String) -> bool:
	if _inherited_aborted.has(gltf_path):
		return false
	if not NexusSceneUtils.should_create_packed_scene(gltf_path):
		return false

	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false

	var scene_style = NexusSceneUtils.preferred_scene_style_for_gltf(gltf_path)
	if scene_style == NexusPaths.SCENE_STYLE_DISABLED:
		return false
	var tscn_path = NexusPaths.scene_path_for(gltf_path, scene_style)
	var export_type: String = str(meta.get("export_type", ""))

	if NexusSceneUtils.is_composition_gltf(gltf_path):
		if not NexusSceneUtils.is_thin_composition_gltf(gltf_path):
			return false
		if not NexusSceneUtils.composition_dependencies_ready(gltf_path):
			return true

	if NexusImportContext.is_mass_import_active() and NexusSceneUtils.is_composition_gltf(gltf_path):
		return false

	if NexusImportContext.is_mass_import_active():
		if export_type == "MULTIMESH_MANIFEST":
			var import_ready := NexusSceneUtils.multimesh_import_ready(gltf_path)
			return not import_ready.get("ok", false) or not FileAccess.file_exists(tscn_path)
		# Re-exports (e.g. gltfpack Clean, which runs while the batch lock is held
		# and therefore reimports via the deferred mass-import flush) must recreate
		# the wrapper when the glTF is newer than the saved scene, not only when the
		# scene file is missing.
		if not FileAccess.file_exists(tscn_path):
			return true
		var gltf_mtime := FileAccess.get_modified_time(gltf_path)
		var tscn_mtime := FileAccess.get_modified_time(tscn_path)
		return gltf_mtime > tscn_mtime

	if NexusSceneUtils.is_composition_gltf(gltf_path) and FileAccess.file_exists(tscn_path):
		var gltf_mtime := FileAccess.get_modified_time(gltf_path)
		var tscn_mtime := FileAccess.get_modified_time(tscn_path)
		if gltf_mtime > tscn_mtime:
			return true

	if not FileAccess.file_exists(tscn_path):
		return true

	if str(meta.get("export_type", "")) == "MULTIMESH_MANIFEST":
		var import_ready := NexusSceneUtils.multimesh_import_ready(gltf_path)
		if not import_ready.get("ok", false):
			return true
		if not FileAccess.file_exists(tscn_path):
			return true

	# A re-export rewrote the glTF on disk; recreate the wrapper when it is newer
	# than the saved scene, even if the saved scene is structurally intact. The
	# mass-import and composition branches already do this; regular assets on the
	# normal (FS-triggered) reimport path need it too, otherwise re-exports only
	# update the scene on a manual reimport.
	var reg_gltf_mtime := FileAccess.get_modified_time(gltf_path)
	var reg_tscn_mtime := FileAccess.get_modified_time(tscn_path)
	if reg_gltf_mtime > reg_tscn_mtime:
		return true

	return _saved_scene_needs_update(gltf_path, meta, tscn_path, scene_style)


func _saved_scene_needs_update(
	gltf_path: String, meta: Dictionary, tscn_path: String, scene_style: String
) -> bool:
	if not ResourceLoader.exists(tscn_path):
		return true
	var packed = ResourceLoader.load(tscn_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return true
	var inst = packed.instantiate()
	if inst == null:
		return true

	var asset_name = gltf_path.get_file().get_basename()
	var script_root: Node = inst
	var resonance_root: Node = inst
	if scene_style == NexusPaths.SCENE_STYLE_WRAPPER:
		var gltf_child = inst.get_node_or_null(NodePath(asset_name))
		if gltf_child == null:
			inst.free()
			return true
		resonance_root = gltf_child

	var target_script_path = NexusUtils.validate_index_path(str(meta.get("script_path", "")))
	if not target_script_path.is_empty() and ResourceLoader.exists(target_script_path):
		var current_script: Script = script_root.get_script()
		var current_path := current_script.resource_path if current_script else ""
		if current_path != target_script_path:
			inst.free()
			return true

	if _has_resonance_nodes(gltf_path) and scene_style != NexusPaths.SCENE_STYLE_WRAPPER:
		var expected_count := _expected_resonance_count(gltf_path)
		var actual_count := _count_resonance_geometry_children(resonance_root)
		if expected_count > 0 and actual_count < expected_count:
			inst.free()
			return true

	inst.free()
	return false


func _expected_resonance_count(gltf_path: String) -> int:
	if gltf_path.is_empty():
		return 0
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return 0
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return 0
	var gltf = json.get_data()
	if gltf == null:
		return 0
	var count := 0
	var nodes = gltf.get("nodes", [])
	for n in nodes:
		var extras = n.get("extras", {})
		var node_meta = extras.get("NEXUS_NODE_METADATA")
		if node_meta is Dictionary:
			var shape = node_meta.get("nexus_mesh_collision_shape", "")
			if shape in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
				count += 1
	return count


func _count_resonance_geometry_children(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		var cls = child.get_class()
		if cls == "ResonanceStaticGeometry" or cls == "ResonanceDynamicGeometry":
			count += 1
	return count


func _notify_scene_file_written() -> void:
	if _plugin and _plugin.has_method("notify_scene_file_written"):
		_plugin.notify_scene_file_written()


func build_wrapper_scene_async(gltf_path: String) -> void:
	# Make sure the glTF has completed Nexus post-import (animation library saved,
	# native AnimationPlayer removed for wrapper style) before we instance it;
	# otherwise the wrapper would build against a half-processed subscene and miss
	# nexus_anim_lib_path meta / .res, causing timing-dependent player duplication.
	if _plugin and _plugin.has_method("ensure_nexus_gltf_imported_async"):
		await _plugin.ensure_nexus_gltf_imported_async(gltf_path)
	var fs_pre = _plugin.get_editor_interface().get_resource_filesystem()
	while fs_pre and fs_pre.is_scanning():
		await _plugin.get_tree().process_frame

	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var tscn_path = NexusPaths.wrapper_path_for(gltf_path)
	var target_script_path = meta.get("script_path", "")

	var gltf_resource = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		push_error("Nexus Wrapper: Could not load GLTF: %s" % gltf_path)
		_finish_wrapper_creation()
		return

	var gltf_instance = NexusSceneUtils.instantiate_scene_reference(gltf_path)
	if gltf_instance == null:
		gltf_instance = gltf_resource.instantiate()
	if not gltf_instance:
		push_error("Nexus Wrapper: Could not instantiate GLTF: %s" % gltf_path)
		_finish_wrapper_creation()
		return
	if gltf_instance.scene_file_path.is_empty():
		gltf_instance.scene_file_path = gltf_path
	var anim_lib_path = gltf_instance.get_meta("nexus_anim_lib_path", "")
	var resonance_nodes: Array = gltf_instance.get_meta("nexus_resonance_nodes", [])

	var packed_scene = PackedScene.new()
	var root_node = Node3D.new()
	root_node.name = gltf_path.get_file().get_basename()

	var asset_name = gltf_path.get_file().get_basename()
	gltf_instance.name = asset_name

	root_node.add_child(gltf_instance)
	gltf_instance.owner = root_node

	attach_resonance_nodes(gltf_instance, resonance_nodes)

	var export_type = meta.get("export_type", "")
	setup_animation_player(root_node, gltf_instance, anim_lib_path, export_type)
	assign_wrapper_script(root_node, target_script_path)

	if packed_scene.pack(root_node) == OK:
		var err = ResourceSaver.save(packed_scene, tscn_path)
		if err == OK:
			print_rich(
				"[color=cyan]Nexus Wrapper:[/color] Updated '%s' (Container Mode)."
				% tscn_path.get_file()
			)
			var fs = _plugin.get_editor_interface().get_resource_filesystem()
			if fs:
				fs.update_file(tscn_path)
			_notify_scene_file_written()
		else:
			push_error(
				"Nexus Wrapper: Failed to save %s: %s" % [tscn_path.get_file(), error_string(err)]
			)

	root_node.free()
	_finish_wrapper_creation()


func _finish_wrapper_creation() -> void:
	_wrapper_creation_in_progress = false
	if _queue.is_empty():
		_signal_wrapper_queue_idle()


func build_inherited_scene_async(gltf_path: String) -> void:
	if NexusSceneUtils.is_composition_gltf(gltf_path):
		if not NexusSceneUtils.is_thin_composition_gltf(gltf_path):
			push_warning(
				"Nexus Inherited: Refusing bloated composition '%s'. Re-export from Blender."
				% gltf_path.get_file()
			)
			_finish_inherited_creation()
			return
		if not NexusSceneUtils.composition_dependencies_ready(gltf_path):
			push_warning(
				"Nexus Inherited: Dependency scenes missing for '%s'."
				% gltf_path.get_file()
			)
			_finish_inherited_creation()
			return

	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var export_type = meta.get("export_type", "")

	if export_type == "MULTIMESH_MANIFEST":
		var stage_info := NexusSceneUtils.multimesh_pipeline_stage(gltf_path)
		var stage: String = str(stage_info.get("stage", ""))
		if stage == NexusSceneUtils.MULTIMESH_STAGE_SOURCES:
			_handle_multimesh_inherited_failure(
				gltf_path, str(stage_info.get("reason", "Source assets not ready"))
			)
			return

		var imported_ok := true
		if _plugin and _plugin.has_method("ensure_multimesh_gltf_cache_ready_async"):
			imported_ok = await _plugin.ensure_multimesh_gltf_cache_ready_async(gltf_path)
		if not imported_ok or not NexusSceneUtils.multimesh_manifest_import_complete(gltf_path):
			_handle_multimesh_inherited_failure(
				gltf_path,
				"Manifest import incomplete: %s"
				% str(NexusSceneUtils.multimesh_pipeline_stage(gltf_path).get("reason", ""))
			)
			return

	var tscn_path = NexusPaths.inherited_path_for(gltf_path)
	var target_script_path = meta.get("script_path", "")

	var ei = _plugin.get_editor_interface()
	var previous_scene_path := ""
	var current_root = ei.get_edited_scene_root()
	if current_root and not current_root.scene_file_path.is_empty():
		previous_scene_path = current_root.scene_file_path
		if not FileAccess.file_exists(previous_scene_path):
			var close_err = ei.close_scene()
			if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
				push_warning(
					"Nexus Inherited: Could not close missing scene '%s': %s"
					% [previous_scene_path.get_file(), error_string(close_err)]
				)
			previous_scene_path = ""

	if not ResourceLoader.exists(gltf_path):
		push_error("Nexus Inherited: glTF not found: %s" % gltf_path)
		_finish_inherited_creation()
		return

	if export_type != "MULTIMESH_MANIFEST":
		if _plugin and _plugin.has_method("ensure_nexus_gltf_imported_async"):
			await _plugin.ensure_nexus_gltf_imported_async(gltf_path)

	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	while fs.is_scanning():
		await _plugin.get_tree().process_frame

	await NexusEditorSceneGuard.close_open_scenes_for_reimport_async(
		ei, [gltf_path], _plugin.get_tree()
	)
	for _post_guard in SCENE_LOAD_WAIT_FRAMES:
		await _plugin.get_tree().process_frame

	var root: Node = null
	for _attempt in INHERITED_OPEN_ATTEMPTS:
		ei.open_scene_from_path(gltf_path, true)
		root = await _wait_for_inherited_edit_root(
			ei, gltf_path, INHERITED_OPEN_WAIT_FRAMES_PER_ATTEMPT
		)
		if root != null:
			break
		await _plugin.get_tree().process_frame

	if root == null:
		var timeouts: int = int(_inherited_open_timeout_counts.get(gltf_path, 0)) + 1
		_log_inherited_open_timeout(ei, gltf_path, timeouts, MAX_INHERITED_OPEN_TIMEOUTS)
		await _close_tab_by_path(ei, gltf_path)
		NexusEditorSceneGuard.stabilize_editor_after_close(ei)
		if timeouts > MAX_INHERITED_OPEN_TIMEOUTS:
			_inherited_open_timeout_counts.erase(gltf_path)
			_inherited_aborted[gltf_path] = true
			if export_type == "MULTIMESH_MANIFEST":
				# Routes through handle_multimesh_inherited_failure which logs and
				# calls _finish_inherited_creation; do not double-finish.
				_handle_multimesh_inherited_failure(
					gltf_path, "timed out opening glTF after %d attempt(s)" % timeouts
				)
				return
			push_error(
				"Nexus Inherited: Aborting '%s' after %d open timeout(s); re-export or reimport to retry."
				% [gltf_path.get_file(), timeouts]
			)
			_finish_inherited_creation()
			return
		_inherited_open_timeout_counts[gltf_path] = timeouts
		_finish_inherited_creation()
		return

	_inherited_open_timeout_counts.erase(gltf_path)

	root = await _ensure_composition_instances_resolved(ei, root, gltf_path)
	if root == null:
		_finish_inherited_creation()
		return

	if (
		export_type == "MULTIMESH_MANIFEST"
		and _find_multimesh_instance_recursive(root) == null
	):
		if not _inject_multimesh_tree_into_open_scene(root, gltf_path, meta):
			_handle_multimesh_inherited_failure(
				gltf_path,
				"Opened glTF still has no MultiMeshInstance3D nodes after injection fallback"
			)
			var close_err_missing := ei.close_scene()
			if close_err_missing != OK and close_err_missing != ERR_DOES_NOT_EXIST:
				push_warning(
					"Nexus Inherited: close_scene returned %s" % error_string(close_err_missing)
				)
			return

	_make_inherited_collision_shapes_editable(root)
	_resolve_instances_before_inherited_save(root, gltf_path)

	var anim_lib_path: String = root.get_meta("nexus_anim_lib_path", "")
	var resonance_nodes: Array = root.get_meta("nexus_resonance_nodes", [])
	attach_resonance_nodes(root, resonance_nodes)
	if export_type != "COMBINED_ASSET" and export_type != "LEVEL":
		setup_animation_player(root, root, anim_lib_path, export_type)
	if not target_script_path.is_empty():
		assign_wrapper_script(root, target_script_path)

	ei.save_scene_as(tscn_path)
	if not FileAccess.file_exists(tscn_path):
		push_error("Nexus Inherited: save_scene_as produced no file: %s" % tscn_path)
		_finish_inherited_creation()
		return
	print_rich("[color=cyan]Nexus Inherited:[/color] Created '%s'." % tscn_path.get_file())

	await _release_inherited_edit_tab(ei, root, tscn_path, previous_scene_path)

	NexusEditorSceneGuard.stabilize_editor_after_close(ei)

	if fs:
		fs.update_file(tscn_path)
	_notify_scene_file_written()

	_finish_inherited_creation()


func _handle_multimesh_inherited_failure(gltf_path: String, reason: String) -> void:
	print_rich(
		"[color=yellow]Nexus Inherited:[/color] MultiMesh '%s' deferred (%s)."
		% [gltf_path.get_file(), reason]
	)
	if _plugin and _plugin.has_method("handle_multimesh_inherited_failure"):
		_plugin.handle_multimesh_inherited_failure(gltf_path, reason)
	_finish_inherited_creation()


func _finish_inherited_creation() -> void:
	_inherited_creation_in_progress = false
	_request_multimesh_inherited_scene_queue()
	_request_composition_inherited_scene_queue()
	if _queue.is_empty():
		_signal_wrapper_queue_idle()


# Clear the aborted/timeout state for a glTF so a fresh reimport/re-export can
# retry the inherited build. Called by the reimport manager when a path is
# reimported (manifest wave / composition reimport).
func clear_inherited_abort(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	_inherited_aborted.erase(gltf_path)
	_inherited_open_timeout_counts.erase(gltf_path)


# Force-mark a glTF's inherited build as aborted (e.g. a stuck build detected by
# the plugin, or test injection). Symmetric to clear_inherited_abort.
func mark_inherited_aborted(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	_inherited_aborted[gltf_path] = true


func _request_multimesh_inherited_scene_queue() -> void:
	if _plugin and _plugin.has_method("request_multimesh_inherited_scene_queue"):
		_plugin.request_multimesh_inherited_scene_queue()


func _inject_multimesh_tree_into_open_scene(
	root: Node, gltf_path: String, scene_meta: Dictionary
) -> bool:
	if root == null or gltf_path.is_empty() or scene_meta.is_empty():
		return false
	if not NexusSceneUtils.multimesh_sidecar_resources_ready(gltf_path):
		return false

	var processor := MultiMeshProcessor.new()
	var composite: Node = processor.process(gltf_path, scene_meta)
	processor.free()
	if composite == null or composite.name == "MULTIMESH_ERROR":
		if composite:
			composite.free()
		return false
	if _find_multimesh_instance_recursive(composite) == null:
		composite.free()
		return false

	for child in root.get_children():
		root.remove_child(child)
		child.free()

	while composite.get_child_count() > 0:
		var mm_child: Node = composite.get_child(0)
		composite.remove_child(mm_child)
		root.add_child(mm_child)
		mm_child.owner = root
	composite.free()
	return _find_multimesh_instance_recursive(root) != null


func _request_composition_inherited_scene_queue() -> void:
	if _plugin and _plugin.has_method("request_composition_inherited_scene_queue"):
		_plugin.request_composition_inherited_scene_queue()


func _find_multimesh_instance_recursive(node: Node) -> MultiMeshInstance3D:
	if node is MultiMeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_multimesh_instance_recursive(child)
		if found:
			return found
	return null


func setup_animation_player(
	root_node: Node,
	gltf_instance: Node,
	anim_lib_path: String,
	export_type: String
) -> void:
	var is_skeletal = export_type == "SKELETAL_ASSET"
	var needs_anim_player = is_skeletal or (
		not anim_lib_path.is_empty() and ResourceLoader.exists(anim_lib_path)
	)
	if not needs_anim_player:
		return
	var anim_player: AnimationPlayer = _reuse_or_create_animation_player(root_node, gltf_instance)
	# Track paths are authored relative to the glTF root. Resolving against the
	# glTF instance (not the wrapper root) makes child-node tracks like "Cube"
	# resolve in wrapper style; for inherited style gltf_instance == root_node,
	# so this matches the existing parent-relative behavior.
	anim_player.root_node = anim_player.get_path_to(gltf_instance)
	var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
	if nexus_script:
		anim_player.set_script(nexus_script)
	if anim_player.get_parent() == root_node:
		anim_player.owner = root_node

	if anim_lib_path.is_empty() or not ResourceLoader.exists(anim_lib_path):
		return
	var library = ResourceLoader.load(anim_lib_path)
	if not library:
		push_error("Nexus Wrapper: Could not load animation library: %s" % anim_lib_path)
		return
	if not anim_player.has_animation_library(""):
		anim_player.add_animation_library("", library)

	if _has_physics_body_recursive(gltf_instance):
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

	var anim_list = library.get_animation_list()
	if anim_list.size() > 0:
		anim_player.set_meta("nexus_autoplay", anim_list[0])


func _reuse_or_create_animation_player(root_node: Node, gltf_instance: Node) -> AnimationPlayer:
	# Inherited style: root_node == gltf_instance, and the glTF retains an empty
	# placeholder AnimationPlayer as a direct child. Reuse it so we don't add a
	# second player that collides into @AnimationPlayer@<id>.
	if root_node == gltf_instance:
		var existing := _find_empty_animation_player_child(root_node)
		if existing:
			return existing
	# Wrapper style (or inherited without a placeholder): strip stray empty
	# players nested in the subscene (wrapper built from an inherited-style
	# glTF) and create a fresh player owned by the scene root.
	_strip_internal_animation_players(gltf_instance)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root_node.add_child(player)
	return player


func _find_empty_animation_player_child(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer and not child.has_animation_library(""):
			return child
	return null


func _strip_internal_animation_players(subscene: Node) -> void:
	# Remove empty placeholder AnimationPlayer nodes that non-wrapper scene
	# styles retain inside the imported subscene, so the builder-owned player
	# is the only one. Only direct empty players are stripped; nested players
	# that carry their own library are left intact. For wrapper-style imports
	# there is no placeholder, so this is a no-op.
	for i in range(subscene.get_child_count() - 1, -1, -1):
		var child = subscene.get_child(i)
		if child is AnimationPlayer and not child.has_animation_library(""):
			subscene.remove_child(child)
			child.queue_free()


func assign_wrapper_script(root_node: Node, target_script_path: String) -> void:
	var safe_path := NexusUtils.validate_index_path(target_script_path)
	if safe_path.is_empty():
		if not target_script_path.is_empty():
			push_warning("Nexus Wrapper: Rejected unsafe script_path '%s'." % target_script_path)
		return
	if not ResourceLoader.exists(safe_path):
		return
	var script = ResourceLoader.load(safe_path)
	if script is Script:
		root_node.set_script(script)


func _make_inherited_collision_shapes_editable(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node != root and not node.scene_file_path.is_empty():
			continue
		if node is CollisionShape3D:
			var col_shape := node as CollisionShape3D
			if col_shape.shape:
				col_shape.shape = col_shape.shape.duplicate(true)
		for child in node.get_children():
			stack.append(child)


func attach_resonance_nodes(gltf_instance: Node, resonance_nodes: Array) -> void:
	if resonance_nodes.is_empty():
		return
	if not ClassDB.class_exists("ResonanceStaticGeometry"):
		push_warning(
			"Nexus Wrapper: Nexus Resonance addon not active. ResonanceGeometry nodes were skipped."
		)
		return
	for entry in resonance_nodes:
		if not entry is Dictionary:
			continue
		var resonance_node = _instantiate_resonance_node(entry, gltf_instance)
		if resonance_node:
			gltf_instance.add_child(resonance_node)
			resonance_node.owner = gltf_instance.owner if gltf_instance.owner else gltf_instance


func _instantiate_resonance_node(entry: Dictionary, gltf_instance: Node) -> Node3D:
	var raw_material_path: String = entry.get("material_path", "")
	var material_path := NexusUtils.validate_index_path(raw_material_path)
	if not raw_material_path.is_empty() and material_path.is_empty():
		push_warning(
			"Nexus Wrapper: Rejected unsafe resonance material_path '%s' - skipped."
			% raw_material_path
		)
		return null
	var shape_type: String = entry.get("type", "RESONANCE_STATIC")
	var discard_mesh = entry.get("discard_mesh", false)
	var base_name = NexusUtils.sanitize_node_name(entry.get("node_name", "Resonance"))
	if base_name.is_empty():
		base_name = "Resonance"

	var mesh_path: String = entry.get("mesh_path", "")
	if not mesh_path.is_empty():
		var safe_mesh := NexusUtils.validate_index_path(mesh_path)
		if safe_mesh.is_empty():
			push_warning(
				"Nexus Wrapper: Rejected unsafe resonance mesh_path '%s' - skipped." % mesh_path
			)
			return null
		return _instantiate_resonance_from_sidecar(
			entry, safe_mesh, shape_type, discard_mesh, base_name, material_path
		)

	var path_from_root: String = entry.get("path_from_root", "")
	if path_from_root.is_empty():
		return null
	return _instantiate_resonance_from_mesh_instance(
		gltf_instance, path_from_root, shape_type, discard_mesh, base_name, material_path
	)


func _instantiate_resonance_from_sidecar(
	entry: Dictionary,
	mesh_path: String,
	shape_type: String,
	discard_mesh: bool,
	base_name: String,
	material_path: String
) -> Node3D:
	var mesh_ref = ResourceLoader.load(mesh_path)
	if not mesh_ref or not mesh_ref is Mesh:
		push_warning("Nexus Wrapper: Could not load resonance mesh from '%s' - skipped." % mesh_path)
		return null
	var name_from_res = mesh_path.get_file().get_basename()
	base_name = NexusUtils.sanitize_node_name(name_from_res)
	if base_name.is_empty():
		base_name = "Resonance"
	var transform_str: String = entry.get("transform_str", "")
	var resonance_node := _create_resonance_geometry_node(shape_type)
	if not transform_str.is_empty():
		var t = str_to_var(transform_str)
		if t is Transform3D:
			resonance_node.transform = t
	_apply_resonance_material_and_mesh(resonance_node, material_path, mesh_ref)
	resonance_node.name = base_name if discard_mesh else (base_name + "_Resonance")
	return resonance_node


func _instantiate_resonance_from_mesh_instance(
	gltf_instance: Node,
	path_from_root: String,
	shape_type: String,
	discard_mesh: bool,
	base_name: String,
	material_path: String
) -> Node3D:
	var mesh_instance = gltf_instance.get_node_or_null(NodePath(path_from_root))
	if not mesh_instance or not mesh_instance is MeshInstance3D or not mesh_instance.mesh:
		push_warning(
			"Nexus Wrapper: Resonance node path '%s' not found or invalid - skipped." % path_from_root
		)
		return null
	var mesh_ref = mesh_instance.mesh
	var resonance_node := _create_resonance_geometry_node(shape_type)
	resonance_node.transform = mesh_instance.transform
	_apply_resonance_material_and_mesh(resonance_node, material_path, mesh_ref)
	resonance_node.name = base_name if discard_mesh else (base_name + "_Resonance")
	return resonance_node


func _create_resonance_geometry_node(shape_type: String) -> Node3D:
	if shape_type == "RESONANCE_STATIC":
		return ClassDB.instantiate("ResonanceStaticGeometry")
	return ClassDB.instantiate("ResonanceDynamicGeometry")


func _apply_resonance_material_and_mesh(
	resonance_node: Node3D,
	material_path: String,
	mesh_ref: Mesh
) -> void:
	var material = _load_resonance_material(material_path)
	if material:
		if resonance_node.has_method("set_material"):
			resonance_node.set_material(material)
		else:
			resonance_node.set("material", material)
	if resonance_node.has_method("set_geometry_override"):
		resonance_node.set_geometry_override(mesh_ref)
	else:
		resonance_node.set("geometry_override", mesh_ref)


func _load_resonance_material(path: String) -> Resource:
	if path.is_empty():
		return _create_default_resonance_material()
	var safe_path := NexusUtils.validate_index_path(path)
	if safe_path.is_empty():
		push_warning("Nexus Wrapper: Rejected unsafe resonance material path '%s'." % path)
		return _create_default_resonance_material()
	if ResourceLoader.exists(safe_path):
		var res = load(safe_path)
		if res and res.get_class() == "ResonanceMaterial":
			return res
	return _create_default_resonance_material()


func _create_default_resonance_material() -> Resource:
	if not ClassDB.class_exists("ResonanceMaterial"):
		return null
	return ClassDB.instantiate("ResonanceMaterial")


func _has_physics_body_recursive(node: Node) -> bool:
	if node is PhysicsBody3D:
		return true
	for child in node.get_children():
		if _has_physics_body_recursive(child):
			return true
	return false


func _has_resonance_nodes(gltf_path: String) -> bool:
	if gltf_path.is_empty():
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return false
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return false
	var gltf = json.get_data()
	if gltf == null:
		return false
	var nodes = gltf.get("nodes", [])
	for n in nodes:
		var extras = n.get("extras", {})
		var node_meta = extras.get("NEXUS_NODE_METADATA")
		if node_meta is Dictionary:
			var shape = node_meta.get("nexus_mesh_collision_shape", "")
			if shape in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
				return true
	return false


func _ensure_composition_instances_resolved(
	ei: EditorInterface, root: Node, gltf_path: String
) -> Node:
	# Compositions must save as a bare instance=ExtResource(gltf) that inherits
	# the resolved instances baked into the glTF .import by _post_import. If the
	# opened glTF still holds unresolved instance placeholders (deferred state
	# leaked into the build), resolving them locally would persist a broken
	# structure: the inherited placeholders reappear (yellow) alongside local
	# _001-named instance overrides. Force a non-deferred reimport so _post_import
	# resolves in the .import, then reopen.
	if not NexusSceneUtils.is_composition_gltf(gltf_path):
		return root
	if not InstancingProcessor.has_unresolved_placeholders(root):
		_placeholder_retry_counts.erase(gltf_path)
		return root

	var retries: int = int(_placeholder_retry_counts.get(gltf_path, 0))
	if retries >= MAX_PLACEHOLDER_REIMPORT_RETRIES:
		push_warning(
			"Nexus Inherited: '%s' still has unresolved instance placeholders after %d retries; aborting inherited build."
			% [gltf_path.get_file(), retries]
		)
		_placeholder_retry_counts.erase(gltf_path)
		await _close_tab_by_path(ei, gltf_path)
		NexusEditorSceneGuard.stabilize_editor_after_close(ei)
		return null

	_placeholder_retry_counts[gltf_path] = retries + 1
	push_warning(
		"Nexus Inherited: '%s' opened with unresolved instance placeholders; reimporting non-deferred and reopening (retry %d)."
		% [gltf_path.get_file(), retries + 1]
	)
	await _close_tab_by_path(ei, gltf_path)
	NexusEditorSceneGuard.stabilize_editor_after_close(ei)

	if _plugin and _plugin.has_method("request_composition_instance_resolution_reimport"):
		await _plugin.request_composition_instance_resolution_reimport(gltf_path)

	var reopened: Node = null
	for _attempt in INHERITED_OPEN_ATTEMPTS:
		ei.open_scene_from_path(gltf_path, true)
		reopened = await _wait_for_inherited_edit_root(
			ei, gltf_path, INHERITED_OPEN_WAIT_FRAMES_PER_ATTEMPT
		)
		if reopened != null:
			break
		await _plugin.get_tree().process_frame

	if reopened == null:
		_log_inherited_open_timeout(ei, gltf_path)
		await _close_tab_by_path(ei, gltf_path)
		NexusEditorSceneGuard.stabilize_editor_after_close(ei)
		return null
	if InstancingProcessor.has_unresolved_placeholders(reopened):
		push_warning(
			"Nexus Inherited: '%s' still unresolved after non-deferred reimport; aborting build."
			% gltf_path.get_file()
		)
		await _close_tab_by_path(ei, gltf_path)
		NexusEditorSceneGuard.stabilize_editor_after_close(ei)
		return null
	_placeholder_retry_counts.erase(gltf_path)
	return reopened


func _resolve_instances_before_inherited_save(root: Node, gltf_path: String) -> void:
	if NexusImportContext.should_defer_external_scene_loads():
		return
	if gltf_path.is_empty():
		return
	var composition_rebuild := NexusSceneUtils.is_composition_gltf(gltf_path)
	if not composition_rebuild and root.get_meta(InstancingProcessor.INSTANCES_RESOLVED_META, false):
		return
	if not composition_rebuild and not InstancingProcessor.has_unresolved_placeholders(root):
		return
	if not root.get_meta("_nexus_gltf_path", ""):
		root.set_meta("_nexus_gltf_path", gltf_path)

	NexusSceneUtils.reroll_duplicate_uuid_markers(root)

	var processor := InstancingProcessor.new()
	processor.reset_import_budget()
	processor.retry_pending_instances(root)
	_resolve_asset_id_nodes_recursively(root, root, processor)
	if composition_rebuild:
		root.set_meta(InstancingProcessor.INSTANCES_RESOLVED_META, true)


func _release_inherited_edit_tab(
	editor_interface: EditorInterface,
	saved_root: Node,
	saved_tscn_path: String,
	previous_scene_path: String,
) -> void:
	if editor_interface == null:
		return
	if saved_root != null and is_instance_valid(saved_root):
		editor_interface.set_object_edited(saved_root, false)

	# The saved inherited scene is the active tab after save_scene_as. Close it
	# explicitly so it does not linger as a background tab, then restore the
	# scene the user had open before the build (if it survived the pre-close).
	await _close_tab_by_path(editor_interface, saved_tscn_path)

	if not previous_scene_path.is_empty() and previous_scene_path != saved_tscn_path:
		if FileAccess.file_exists(previous_scene_path) and _is_scene_open(editor_interface, previous_scene_path):
			var current_root := editor_interface.get_edited_scene_root()
			var current_path := ""
			if current_root != null:
				current_path = current_root.scene_file_path.replace("\\", "/")
			if current_path != previous_scene_path:
				editor_interface.open_scene_from_path(previous_scene_path, false)
				for _i in SCENE_LOAD_WAIT_FRAMES:
					await _plugin.get_tree().process_frame


func _is_scene_open(editor_interface: EditorInterface, scene_path: String) -> bool:
	if editor_interface == null or scene_path.is_empty():
		return false
	var canonical := scene_path.replace("\\", "/")
	for open_path in editor_interface.get_open_scenes():
		if open_path.replace("\\", "/") == canonical:
			return true
	return false


func _close_tab_by_path(editor_interface: EditorInterface, scene_path: String) -> void:
	if editor_interface == null or scene_path.is_empty():
		return
	var canonical := scene_path.replace("\\", "/")

	# Activate the target tab if it is not already active, so close_scene hits it.
	var edited_root := editor_interface.get_edited_scene_root()
	var edited_path := ""
	if edited_root != null and not edited_root.scene_file_path.is_empty():
		edited_path = edited_root.scene_file_path.replace("\\", "/")
	if edited_path != canonical and _is_scene_open(editor_interface, canonical):
		editor_interface.open_scene_from_path(scene_path, false)
		for _i in SCENE_LOAD_WAIT_FRAMES:
			await _plugin.get_tree().process_frame

	# Clear edited flag and close the active tab. If the target was already
	# gone (e.g. closed by a prior step), close_scene returns ERR_DOES_NOT_EXIST.
	edited_root = editor_interface.get_edited_scene_root()
	if edited_root != null and is_instance_valid(edited_root):
		editor_interface.set_object_edited(edited_root, false)
	if editor_interface.get_edited_scene_root() == null:
		return
	var close_err := editor_interface.close_scene()
	if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
		push_warning("Nexus Inherited: close_scene returned %s" % error_string(close_err))
	for _i in SCENE_LOAD_WAIT_FRAMES:
		await _plugin.get_tree().process_frame


func _canonical_gltf_path(gltf_path: String) -> String:
	var expected := NexusUtils.to_res_gltf_path(gltf_path)
	if expected.is_empty():
		expected = gltf_path.replace("\\", "/").strip_edges()
	return expected


func _is_neutral_keeper_root(root: Node) -> bool:
	# Neutral empty state after closing the last tab: no valid edited root. This
	# matches Godot 4.7's behavior where close_scene() on the final tab leaves
	# get_edited_scene_root() == null (validated via headless editor spike). A
	# freshly opened glTF root stays a valid node and is not mistaken for neutral.
	if root == null or not is_instance_valid(root):
		return true
	return false


func _scene_paths_match_gltf(scene_path: String, expected_gltf: String) -> bool:
	var edited_path := scene_path.replace("\\", "/")
	if edited_path.is_empty():
		return false
	if edited_path == expected_gltf:
		return true
	return (
		edited_path.get_base_dir() == expected_gltf.get_base_dir()
		and edited_path.get_basename() == expected_gltf.get_basename()
	)


func _is_expected_inherited_edit_root(root: Node, gltf_path: String) -> bool:
	if root == null or not is_instance_valid(root):
		return false
	if _is_neutral_keeper_root(root):
		return false

	var expected := _canonical_gltf_path(gltf_path)
	var edited_path := root.scene_file_path.replace("\\", "/")
	if _scene_paths_match_gltf(edited_path, expected):
		return true

	# glTF editor tabs often leave scene_file_path empty on the root.
	var meta_path := str(root.get_meta("_nexus_gltf_path", "")).replace("\\", "/")
	if _scene_paths_match_gltf(meta_path, expected):
		return true

	var gltf_stem := expected.get_file().get_basename()
	if root.name == gltf_stem and root.has_meta("_nexus_export_type"):
		return true

	return false


func _wait_for_inherited_edit_root(
	editor_interface: EditorInterface,
	gltf_path: String,
	max_frames: int = 600,
) -> Node:
	var open_wait := 0
	while open_wait < max_frames:
		var root_candidate := editor_interface.get_edited_scene_root()
		if _is_expected_inherited_edit_root(root_candidate, gltf_path):
			for _settle in SCENE_LOAD_WAIT_FRAMES:
				await _plugin.get_tree().process_frame
			return root_candidate
		await _plugin.get_tree().process_frame
		open_wait += 1
	return null


func _log_inherited_open_timeout(
	editor_interface: EditorInterface, gltf_path: String, attempt: int = 0, max_attempts: int = 0
) -> void:
	var root := editor_interface.get_edited_scene_root()
	var root_name := "<null>"
	var scene_path := ""
	var meta_path := ""
	if root != null and is_instance_valid(root):
		root_name = root.name
		scene_path = root.scene_file_path
		meta_path = str(root.get_meta("_nexus_gltf_path", ""))
	var open_tabs := editor_interface.get_open_scenes()
	var retry_tag := " (timeout %d/%d)" % [attempt, max_attempts] if attempt > 0 else ""
	push_error(
		(
			"Nexus Inherited: Timed out opening %s%s - edited root never matched glTF path "
			+ "(root=%s scene_file_path='%s' _nexus_gltf_path='%s' open_tabs=%s expected=%s)."
		)
		% [
			gltf_path.get_file(),
			retry_tag,
			root_name,
			scene_path,
			meta_path,
			str(open_tabs),
			_canonical_gltf_path(gltf_path),
		]
	)


func _resolve_asset_id_nodes_recursively(
	node: Node, root: Node, processor: InstancingProcessor
) -> void:
	for i in range(node.get_child_count() - 1, -1, -1):
		_resolve_asset_id_nodes_recursively(node.get_child(i), root, processor)

	if not node.has_meta("extras"):
		return
	if not node.scene_file_path.is_empty():
		return
	var extras = node.get_meta("extras")
	if not extras is Dictionary or not NEXUS_NODE_META in extras:
		return
	var node_meta = extras[NEXUS_NODE_META]
	if not node_meta is Dictionary:
		return
	if node_meta.has("nexus_asset_id") or node_meta.has("nexus_placeholder_path"):
		processor.process(node, node_meta, root)
