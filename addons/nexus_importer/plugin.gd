@tool
extends EditorPlugin

## Nexus Importer: Custom glTF importer for the Nexus Blender Export Pipeline.

const NexusReimportManagerScript = preload("res://addons/nexus_importer/editor/nexus_reimport_manager.gd")
const NexusWrapperBuilderScript = preload("res://addons/nexus_importer/editor/nexus_wrapper_builder.gd")
const NexusAssetToolsScript = preload("res://addons/nexus_importer/editor/nexus_asset_tools.gd")
const NexusInstanceFixupScript = preload("res://addons/nexus_importer/editor/nexus_instance_fixup.gd")
const NexusBatchLockScript = preload("res://addons/nexus_importer/scripts/nexus_batch_lock.gd")
const NexusEditorSceneGuard = preload(
	"res://addons/nexus_importer/editor/nexus_editor_scene_guard.gd"
)
const NexusImportContextScript = preload("res://addons/nexus_importer/scripts/nexus_import_context.gd")
const MultiMeshImportOrchestratorScript = preload(
	"res://addons/nexus_importer/editor/multimesh_import_orchestrator.gd"
)

const MENU_ID_IMPORT_MODE = 0
const MENU_ID_REIMPORT_ASSETS = 1
const MENU_ID_ASSET_SANITIZATION = 2
const MENU_ID_MATERIAL_SANITIZATION = 3
const INSTANCE_PASS_COOLDOWN_FRAMES := 2

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()
var _tool_submenu: PopupMenu
var _fs_context_plugin: RefCounted
var _reimport_manager: NexusReimportManager
var _wrapper_builder: NexusWrapperBuilder
var _asset_tools: NexusAssetTools
var _instance_fixup: NexusInstanceFixup
var _multimesh_orchestrator: MultiMeshImportOrchestrator
var _scan_needed: bool = false
var _batch_lock_was_active: bool = false
var _instance_pass_running: bool = false
var _editor_bootstrap_done: bool = false
var _saw_fs_scanning: bool = false
var _dependency_gate_queued: Dictionary = {}
var _composition_scene_queue_pending: bool = false
var _multimesh_scene_queue_pending: bool = false
var _startup_catchup_done: bool = false
var _multimesh_scan_cooldown_frames: int = 0

var _batch_lock_scene_guard_applied: bool = false

# FS-Reimport (Rechtsklick->Reimport / reimport_files) of a composition whose
# instance dependencies are NOT in the same reimport batch must resolve non-deferred,
# otherwise _post_import leaves placeholders in the .import (Bild 2) and the deferred
# instance pass is starved. Tracks the flag lifecycle for this signal-driven path.
var _fs_comp_resolution_reimport_active: bool = false


func _enter_tree():
	add_scene_post_import_plugin(scene_post_processor)
	var fs = get_editor_interface().get_resource_filesystem()
	if not fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.connect(_on_resources_reimported)
	if not fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.connect(_on_resources_reimporting)

	_reimport_manager = NexusReimportManagerScript.new(self)
	_wrapper_builder = NexusWrapperBuilderScript.new(self)
	_multimesh_orchestrator = MultiMeshImportOrchestratorScript.new(self)
	_asset_tools = NexusAssetToolsScript.new(_reimport_manager)
	_instance_fixup = NexusInstanceFixupScript.new()
	set_process(true)

	_register_project_settings()

	_tool_submenu = PopupMenu.new()
	_tool_submenu.id_pressed.connect(_on_tool_submenu_id_pressed)
	add_tool_submenu_item("Nexus Importer", _tool_submenu)
	_update_tool_menu_items()
	_fs_context_plugin = preload("res://addons/nexus_importer/fs_context_menu.gd").new()
	if _fs_context_plugin.has_method("set_nexus_plugin"):
		_fs_context_plugin.set_nexus_plugin(self)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_context_plugin)
	print_rich("[color=green]Nexus Importer: Ready.[/color]")


func _exit_tree():
	set_process(false)
	if _fs_context_plugin:
		remove_context_menu_plugin(_fs_context_plugin)
		_fs_context_plugin = null
	remove_scene_post_import_plugin(scene_post_processor)
	remove_tool_menu_item("Nexus Importer")
	_tool_submenu = null

	var fs = get_editor_interface().get_resource_filesystem()
	if fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.disconnect(_on_resources_reimported)
	if fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.disconnect(_on_resources_reimporting)

	_reimport_manager = null
	_wrapper_builder = null
	_asset_tools = null
	_instance_fixup = null


func _process(_delta):
	if _reimport_manager == null or _wrapper_builder == null:
		return

	var fs = get_editor_interface().get_resource_filesystem()
	if not _editor_bootstrap_done:
		if fs.is_scanning():
			_saw_fs_scanning = true
		elif _saw_fs_scanning:
			_editor_bootstrap_done = true
			if _reimport_manager != null:
				var primed := _reimport_manager.prime_nexus_import_configs()
				if primed > 0:
					print_rich(
						"[color=yellow]Nexus:[/color] Primed import config for %d glTF asset(s)."
						% primed
					)
			_try_startup_import_catchup()
		else:
			return

	var batch_locked := NexusBatchLockScript.is_active()
	if batch_locked:
		if not _batch_lock_scene_guard_applied:
			_batch_lock_scene_guard_applied = true
			NexusEditorSceneGuard.close_open_nexus_asset_tabs_if_any(get_editor_interface())
		_batch_lock_was_active = true
		return
	_batch_lock_scene_guard_applied = false

	if _batch_lock_was_active:
		_batch_lock_was_active = false
		_flush_batch_deferred_imports()
	elif NexusBatchLockScript.has_deferred_paths():
		_flush_batch_deferred_imports()

	if _reimport_manager.cooldown_remaining > 0:
		_reimport_manager.cooldown_remaining -= 1
		return

	if _multimesh_scan_cooldown_frames > 0:
		_multimesh_scan_cooldown_frames -= 1

	if fs.is_scanning():
		_reimport_manager.cooldown_remaining = 10
		return

	if _wrapper_builder.has_pending() or _wrapper_builder.is_busy():
		if _wrapper_builder.tick_scene_creation(_reimport_manager):
			return

	if _reimport_manager.tick_phased_reimport():
		return

	var ticked: bool = _wrapper_builder.tick_scene_creation(_reimport_manager)

	if (
		_wrapper_builder.scan_when_idle
		and not _wrapper_builder.is_busy()
		and not _wrapper_builder.has_pending()
	):
		_wrapper_builder.scan_when_idle = false
		request_composition_inherited_scene_queue()

	if ticked:
		return

	if _scan_needed:
		_scan_needed = false
		fs.scan()
		return

	if _instance_pass_running:
		_schedule_next_instance_pass_fixup()
		return

	_try_queue_composition_wave()
	_try_finalize_mass_import_when_idle()
	_try_start_deferred_instance_pass()
	_try_queue_pending_multimesh_inherited_scenes()
	_try_queue_pending_composition_inherited_scenes()


func _import_system_fully_idle() -> bool:
	if _reimport_manager.is_reimport_active() or _wrapper_builder.is_busy():
		return false
	if _reimport_manager.is_config_wave_pending():
		return false
	if _reimport_manager.has_pending_paths():
		return false
	if _wrapper_builder.has_pending():
		return false
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		return false
	if _reimport_manager.cooldown_remaining > 0:
		return false
	return true


func _ensure_composition_dependencies_ready(level_paths: Array[String]) -> bool:
	var queued_any := false
	for level_path in level_paths:
		if level_path is String and level_path.is_empty():
			continue
		var asset_ids := NexusSceneUtils.collect_asset_ids_from_gltf(level_path)
		var dep_gltfs := NexusSceneUtils.resolve_dependency_gltf_paths(asset_ids)
		for dep_gltf in dep_gltfs:
			if NexusSceneUtils.dependency_scene_ready(dep_gltf):
				continue
			if _dependency_gate_queued.has(dep_gltf):
				queued_any = true
				continue
			if _wrapper_builder.is_scene_queued(dep_gltf):
				queued_any = true
				continue
			if NexusPaths.auto_import_enabled() and NexusSceneUtils.should_create_packed_scene(dep_gltf):
				if _wrapper_builder.needs_scene_processing(dep_gltf):
					_dependency_gate_queued[dep_gltf] = true
					_wrapper_builder.queue_scene(dep_gltf)
					queued_any = true
			elif FileAccess.file_exists(dep_gltf):
				if (
					NexusPaths.auto_import_enabled()
					and not _wrapper_builder.needs_scene_processing(dep_gltf)
				):
					var scene_path := NexusSceneUtils.resolve_packed_scene_path(dep_gltf)
					if not scene_path.is_empty() and FileAccess.file_exists(scene_path):
						continue
				_dependency_gate_queued[dep_gltf] = true
				_reimport_manager.queue_paths([dep_gltf])
				queued_any = true
	if queued_any:
		return false
	for level_path in level_paths:
		if level_path is String and not level_path.is_empty():
			if not NexusSceneUtils.composition_dependencies_ready(level_path):
				return false
	return true


func _try_start_deferred_instance_pass() -> void:
	if not NexusImportContextScript.is_mass_import_active():
		return
	if _reimport_manager.has_deferred_mass_import_work():
		return
	if not _import_system_fully_idle():
		return
	if not NexusImportContextScript.has_levels_needing_instance_pass():
		return

	var levels := NexusImportContextScript.take_levels_needing_instance_pass()
	if not _ensure_composition_dependencies_ready(levels):
		for level_path in levels:
			if level_path is String and not level_path.is_empty():
				NexusImportContextScript.mark_level_needs_instance_pass(level_path)
		return

	_dependency_gate_queued.clear()
	_instance_pass_running = true
	NexusImportContextScript.start_instance_pass(levels)
	print_rich(
		"[color=cyan]Nexus:[/color] Starting deferred instancing pass for %d composition glTF(s)."
		% levels.size()
	)
	_schedule_next_instance_pass_fixup()


func _try_queue_composition_wave() -> void:
	if _reimport_manager == null:
		return
	if not _reimport_manager.has_deferred_composition_paths():
		return
	if not _import_system_fully_idle():
		return
	if _reimport_manager.has_deferred_mass_import_work():
		return
	_reimport_manager.try_queue_composition_wave()


func _try_queue_multimesh_wave() -> void:
	if _reimport_manager == null:
		return
	if not _reimport_manager.has_deferred_multimesh_paths():
		return
	if not _import_system_fully_idle():
		return
	if _reimport_manager.has_deferred_mass_import_work():
		return
	_reimport_manager.try_queue_multimesh_wave()


func request_multimesh_wave() -> void:
	call_deferred("_try_queue_multimesh_wave")


func defer_multimesh_manifest_reimport(gltf_path: String) -> void:
	if _reimport_manager == null or gltf_path.is_empty():
		return
	_reimport_manager.seed_deferred_multimesh_paths([gltf_path])
	request_multimesh_wave()


func reimport_multimesh_manifest(gltf_path: String) -> void:
	if _reimport_manager == null or gltf_path.is_empty():
		return
	_reimport_manager.queue_multimesh_manifest_reimport(gltf_path)


func _schedule_next_instance_pass_fixup() -> void:
	if not _instance_pass_running:
		return
	if not _import_system_fully_idle():
		return

	var next := NexusImportContextScript.next_instance_pass_target()
	if next.is_empty():
		_finish_instance_pass()
		return

	var preflight := NexusSceneUtils.can_run_instance_pass_for_level(next)
	if not preflight.get("ok", false):
		push_warning(
			"Nexus: Skipping instance pass for %s (%s)."
			% [next.get_file(), str(preflight.get("reason", "preflight failed"))]
		)
		NexusImportContextScript.skip_instance_pass_level(next, str(preflight.get("reason", "")))
		NexusImportContextScript.complete_current_instance_pass()
		call_deferred("_schedule_next_instance_pass_fixup")
		return

	if not NexusSceneUtils.composition_dependencies_ready(next):
		_ensure_composition_dependencies_ready([next])
		return

	print_rich(
		"[color=cyan]Nexus:[/color] Instance pass reimport: %s (%d remaining)"
		% [next.get_file(), NexusImportContextScript.instance_pass_remaining()]
	)
	_run_instance_pass_fixup(next)


func _run_instance_pass_fixup(gltf_path: String) -> void:
	if _reimport_manager == null:
		return
	NexusImportContextScript.set_mass_import_active(false)
	_reimport_manager.queue_paths([gltf_path])


func _finish_instance_pass() -> void:
	if not _instance_pass_running:
		return
	_instance_pass_running = false
	NexusImportContextScript.cancel_instance_pass()
	NexusImportContextScript.set_mass_import_active(false)
	print_rich("[color=cyan]Nexus:[/color] Deferred instancing pass finished.")
	_queue_post_instance_pass_fixup()


func _try_finalize_mass_import_when_idle() -> void:
	if not NexusImportContextScript.is_mass_import_active():
		return
	if not _import_system_fully_idle():
		return
	if _reimport_manager.has_pending_paths():
		return
	if _reimport_manager.has_deferred_mass_import_work():
		_reimport_manager.flush_mass_import_post_processing(_wrapper_builder)
		return
	if _reimport_manager.has_deferred_composition_paths():
		_try_queue_composition_wave()
		return
	if _reimport_manager.has_deferred_multimesh_paths():
		_try_queue_multimesh_wave()
		return
	if NexusImportContextScript.has_levels_needing_instance_pass():
		return
	NexusImportContextScript.set_mass_import_active(false)


func _on_resources_reimporting(_resources: PackedStringArray):
	if _reimport_manager == null:
		return
	var gltf_paths := _collect_gltf_paths_from_resources(_resources)
	if not gltf_paths.is_empty():
		_reimport_manager.prepare_editor_scenes_for_reimport(gltf_paths)
	if NexusImportContextScript.is_instance_pass_active():
		return
	if NexusImportContextScript.is_composition_resolution_reimport():
		# Forced non-deferred composition reimport (instance resolution before
		# inherited build): keep mass-import off so _post_import resolves
		# placeholders in the .import instead of deferring them.
		NexusImportContextScript.set_mass_import_active(false)
		_reimport_manager.on_resources_reimporting(_resources)
		return
	if _reimport_manager.is_composition_wave_active():
		return
	if _reimport_manager.is_multimesh_wave_active():
		return
	if NexusImportContextScript.is_multimesh_wave_active():
		return
	if _resources_include_multimesh_manifest(_resources):
		NexusImportContextScript.set_mass_import_active(false)
		_reimport_manager.on_resources_reimporting(_resources)
		return
	if _batch_is_composition_fs_reimport(gltf_paths):
		# Single/batch FS-Reimport of composition(s) whose instance dependencies are
		# not in this batch: resolve non-deferred so _post_import bakes resolved
		# instances into the .import (Bild 1). Deferring here leaves placeholders
		# (Bild 2) and the dependents-only wave never reimports the composition
		# itself, so the deferred instance pass is starved.
		_fs_comp_resolution_reimport_active = true
		NexusImportContextScript.set_composition_resolution_reimport(true)
		NexusImportContextScript.set_mass_import_active(false)
		_reimport_manager.on_resources_reimporting(_resources)
		return
	NexusImportContextScript.set_mass_import_active(true)
	_reimport_manager.on_resources_reimporting(_resources)


# FS-Reimport of a composition resolves non-deferred when none of the batch's
# compositions have an instance dependency also present in the batch. If a dep is
# in the batch, keep the deferred mass-import path (avoids load-during-reimport
# deadlocks for the dependency).
func _batch_is_composition_fs_reimport(gltf_paths: Array) -> bool:
	var batch_set: Dictionary = {}
	var has_composition := false
	for path in gltf_paths:
		if not path is String:
			continue
		var p := str(path)
		if p.is_empty():
			continue
		batch_set[p] = true
		if NexusSceneUtils.is_composition_gltf(p):
			has_composition = true
	if not has_composition:
		return false
	for path in batch_set.keys():
		if not NexusSceneUtils.is_composition_gltf(path):
			continue
		var asset_ids := NexusSceneUtils.collect_composition_dependency_asset_ids(path)
		var dep_paths := NexusSceneUtils.resolve_dependency_gltf_paths(asset_ids)
		for dep in dep_paths:
			if batch_set.has(dep):
				return false
	return true


func _resources_include_multimesh_manifest(resources: PackedStringArray) -> bool:
	for resource in resources:
		if resource.is_empty():
			continue
		var ext := resource.get_extension().to_lower()
		if ext != "gltf" and ext != "glb":
			continue
		if NexusSceneUtils.is_multimesh_manifest(resource):
			return true
	return false


func _collect_gltf_paths_from_resources(resources: PackedStringArray) -> Array:
	var gltf_paths: Array = []
	for resource in resources:
		if resource is String and not resource.is_empty():
			var ext := resource.get_extension().to_lower()
			if ext == "gltf" or ext == "glb":
				gltf_paths.append(resource)
	return gltf_paths


func _on_resources_reimported(resources: PackedStringArray):
	if _reimport_manager == null or _wrapper_builder == null:
		return
	if _fs_comp_resolution_reimport_active:
		_fs_comp_resolution_reimport_active = false
		NexusImportContextScript.set_composition_resolution_reimport(false)
	for resource in resources:
		if NexusSceneUtils.is_multimesh_manifest(resource):
			NexusSceneUtils.invalidate_multimesh_pipeline_cache(resource)
	if not _editor_bootstrap_done:
		_reimport_manager.finish_reimport_signal()
		return
	if _reimport_manager.on_resources_reimported(
		resources,
		_wrapper_builder,
		func(wants_scan: bool): _scan_needed = wants_scan
	):
		_show_nexus_notification("Nexus: Import complete", EditorToaster.SEVERITY_INFO)

	_queue_indexed_dependents_for_reimported(resources)

	if _instance_pass_running and NexusImportContextScript.resources_include_current_instance_pass_target(
		resources
	):
		NexusImportContextScript.complete_current_instance_pass()
		_reimport_manager.cooldown_remaining = INSTANCE_PASS_COOLDOWN_FRAMES
		call_deferred("_schedule_next_instance_pass_fixup")


func _nexus_apply_deferred_config_writes():
	if _reimport_manager == null:
		return
	_reimport_manager.apply_deferred_config_writes()


func _nexus_flush_pending_reimport_queue(just_reimported: Array):
	if _reimport_manager == null:
		return
	_reimport_manager.flush_pending_reimport_queue(just_reimported)


func _nexus_restore_selection(nodes: Array[Node]):
	var selection = get_editor_interface().get_selection()
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			selection.add_node(node)


func _flush_batch_deferred_imports() -> void:
	if _reimport_manager == null:
		return
	if not _editor_bootstrap_done:
		return
	if not NexusBatchLockScript.has_deferred_paths():
		return
	var phased: Dictionary = NexusBatchLockScript.take_deferred_phased()
	var textures: Array = phased.get("textures", [])
	var gltfs: Array = phased.get("gltfs", [])
	if textures.is_empty() and gltfs.is_empty():
		return
	print_rich(
		"[color=cyan]Nexus:[/color] Batch export finished; reimporting %d deferred resource(s)."
		% (textures.size() + gltfs.size())
	)
	NexusImportContextScript.set_mass_import_active(true)
	_reimport_manager.queue_phased_reimport_from_gltf_paths(textures, gltfs)
	request_composition_inherited_scene_queue()


func _queue_post_instance_pass_fixup() -> void:
	if _reimport_manager == null or _wrapper_builder == null:
		return
	var paths := NexusImportContextScript.take_instance_pass_completed_paths()
	var queued := _reimport_manager.queue_wrapper_fixup_for_paths(paths, _wrapper_builder)
	var composition_queued := _reimport_manager.queue_composition_inherited_scenes_from_index(
		_wrapper_builder
	)
	if queued > 0:
		print_rich(
			"[color=cyan]Nexus:[/color] Queued %d wrapper/inherited scene(s) after instance pass."
			% queued
		)
	if composition_queued > 0:
		print_rich(
			"[color=cyan]Nexus:[/color] Queued %d composition inherited scene(s) after instance pass."
			% composition_queued
		)


func request_composition_inherited_scene_queue() -> void:
	_composition_scene_queue_pending = true


func request_multimesh_inherited_scene_queue() -> void:
	_multimesh_scene_queue_pending = true


func ensure_multimesh_gltf_cache_ready_async(gltf_path: String) -> bool:
	if _reimport_manager == null or gltf_path.is_empty():
		return false
	if not NexusSceneUtils.is_multimesh_manifest(gltf_path):
		return false

	const MAX_ATTEMPTS := NexusImportContextScript.MAX_MULTIMESH_REIMPORT_RETRIES
	for attempt in range(MAX_ATTEMPTS):
		if NexusSceneUtils.multimesh_manifest_import_complete(gltf_path):
			return true

		var sources_ready := NexusSceneUtils.multimesh_sources_ready(gltf_path)
		if not sources_ready.get("ok", false):
			await _reimport_multimesh_source_dependencies(gltf_path)

		if (
			not _reimport_manager.was_recently_reimported(gltf_path)
			and NexusSceneUtils.nexus_import_config_needs_fix(gltf_path)
		):
			_reimport_manager.fix_import_config_if_needed(gltf_path, true)
		await _reimport_gltf_and_wait(gltf_path)
		await _wait_for_import_idle()
		NexusSceneUtils.invalidate_multimesh_pipeline_cache(gltf_path)
		ResourceLoader.load(gltf_path, "", ResourceLoader.CACHE_MODE_REPLACE)

	if NexusSceneUtils.multimesh_manifest_import_complete(gltf_path):
		return true

	var stage_info := NexusSceneUtils.multimesh_pipeline_stage(gltf_path)
	push_error(
		"Nexus MultiMesh: Import cache not ready for '%s' after %d attempts (stage=%s: %s)."
		% [
			gltf_path.get_file(),
			MAX_ATTEMPTS,
			str(stage_info.get("stage", "?")),
			str(stage_info.get("reason", "")),
		]
	)
	return false


func handle_multimesh_inherited_failure(gltf_path: String, reason: String) -> void:
	if _multimesh_orchestrator == null or _reimport_manager == null:
		return
	_multimesh_orchestrator.handle_inherited_failure(gltf_path, _reimport_manager, reason)


func on_multimesh_wave_batch_finished(
	resources: PackedStringArray, wrapper_builder: NexusWrapperBuilder
) -> void:
	if _multimesh_orchestrator == null or _reimport_manager == null:
		return
	var queued := _multimesh_orchestrator.on_manifest_reimport_done(
		resources, _reimport_manager, wrapper_builder
	)
	if queued > 0:
		print_rich(
			"[color=cyan]Nexus:[/color] Queued %d MultiMesh inherited scene(s) after manifest wave."
			% queued
		)


func _wait_for_import_idle() -> void:
	const MAX_WAIT_FRAMES := 1800
	var wait := 0
	var fs = get_editor_interface().get_resource_filesystem()
	while wait < MAX_WAIT_FRAMES:
		await get_tree().process_frame
		if (
			not _reimport_manager.is_reimport_active()
			and not fs.is_scanning()
			and _reimport_manager.cooldown_remaining <= 0
			and not _wrapper_builder.is_busy()
		):
			break
		wait += 1


func ensure_nexus_gltf_imported_async(gltf_path: String) -> bool:
	if _reimport_manager == null or gltf_path.is_empty():
		return false

	if not NexusSceneUtils.is_multimesh_manifest(gltf_path):
		if _reimport_manager.was_recently_reimported(gltf_path):
			return ResourceLoader.exists(gltf_path)
		var needs_reimport := NexusSceneUtils.gltf_needs_reimport(gltf_path)
		if NexusSceneUtils.nexus_import_config_needs_fix(gltf_path):
			if _reimport_manager.fix_import_config_if_needed(gltf_path, true):
				needs_reimport = true
		if not needs_reimport:
			return true
		var composition_resolution := NexusSceneUtils.is_composition_gltf(gltf_path)
		if composition_resolution:
			# Reimport the composition non-deferred so _post_import resolves
			# instance placeholders into the .import; otherwise the inherited
			# build would open a placeholder glTF and save a broken
			# instance=ExtResource(gltf) + local _001 override structure.
			NexusImportContextScript.set_composition_resolution_reimport(true)
			NexusImportContextScript.set_mass_import_active(false)
		await _reimport_gltf_and_wait(gltf_path)
		if composition_resolution:
			NexusImportContextScript.set_composition_resolution_reimport(false)
		return ResourceLoader.exists(gltf_path)

	return await ensure_multimesh_gltf_cache_ready_async(gltf_path)


func request_composition_instance_resolution_reimport(gltf_path: String) -> void:
	# Safety net for build_inherited_scene_async: force a non-deferred reimport of
	# a composition whose .import still holds unresolved instance placeholders, so
	# _post_import resolves them in the .import. The inherited build re-triggers
	# with a resolved glTF and saves a bare clean instance=ExtResource(gltf).
	if _reimport_manager == null or gltf_path.is_empty():
		return
	if not NexusSceneUtils.is_composition_gltf(gltf_path):
		return
	NexusImportContextScript.set_composition_resolution_reimport(true)
	NexusImportContextScript.set_mass_import_active(false)
	_reimport_manager.prepare_editor_scenes_for_reimport([gltf_path])
	var fs = get_editor_interface().get_resource_filesystem()
	fs.reimport_files(PackedStringArray([gltf_path]))
	await _wait_for_import_idle()
	NexusImportContextScript.set_composition_resolution_reimport(false)


func _reimport_gltf_and_wait(gltf_path: String) -> void:
	if _reimport_manager != null:
		_reimport_manager.prepare_editor_scenes_for_reimport([gltf_path])
	if NexusSceneUtils.is_multimesh_manifest(gltf_path) and _reimport_manager != null:
		_reimport_manager.queue_multimesh_manifest_reimport(gltf_path)
	else:
		var fs = get_editor_interface().get_resource_filesystem()
		fs.reimport_files(PackedStringArray([gltf_path]))
	var fs = get_editor_interface().get_resource_filesystem()
	await _wait_for_import_idle()


func _reimport_multimesh_source_dependencies(manifest_gltf_path: String) -> void:
	var asset_ids := NexusSceneUtils.collect_multimesh_manifest_source_asset_ids(manifest_gltf_path)
	var dep_gltfs := NexusSceneUtils.resolve_dependency_gltf_paths(asset_ids)
	if dep_gltfs.is_empty():
		return
	if _reimport_manager != null:
		_reimport_manager.prepare_editor_scenes_for_reimport(dep_gltfs)
	var fs = get_editor_interface().get_resource_filesystem()
	fs.reimport_files(PackedStringArray(dep_gltfs))
	await _wait_for_import_idle()


func _queue_indexed_dependents_for_reimported(resources: PackedStringArray) -> void:
	if _reimport_manager == null:
		return
	if NexusBatchLockScript.is_active():
		return
	var gltf_paths := _collect_gltf_paths_from_resources(resources)
	if gltf_paths.is_empty():
		return
	var added := _reimport_manager.queue_indexed_dependents_for_changed(gltf_paths)
	if added > 0:
		request_composition_wave()


func request_composition_wave() -> void:
	call_deferred("_try_queue_composition_wave")


func notify_scene_file_written() -> void:
	pass


func _try_queue_pending_multimesh_inherited_scenes() -> void:
	if not _multimesh_scene_queue_pending:
		return
	if NexusImportContextScript.is_multimesh_post_import_active():
		return
	if _multimesh_scan_cooldown_frames > 0:
		return
	if _reimport_manager == null or _wrapper_builder == null:
		return
	if _reimport_manager.has_deferred_multimesh_paths():
		return
	if not _import_system_fully_idle():
		return
	var queued := 0
	if _multimesh_orchestrator != null:
		queued = _multimesh_orchestrator.advance_pending_from_index(
			_wrapper_builder, _reimport_manager
		)
	_multimesh_scan_cooldown_frames = 60
	if _wrapper_builder.has_pending() or _wrapper_builder.is_busy():
		return
	if _reimport_manager.has_pending_inherited_scene_work(_wrapper_builder):
		return
	_multimesh_scene_queue_pending = false
	if queued > 0:
		print_rich(
			"[color=cyan]Nexus:[/color] Queued %d MultiMesh inherited scene(s) after reimport."
			% queued
		)


func _try_queue_pending_composition_inherited_scenes() -> void:
	if not _composition_scene_queue_pending:
		return
	if _reimport_manager == null or _wrapper_builder == null:
		return
	if _reimport_manager.has_deferred_composition_paths():
		return
	if _reimport_manager.has_deferred_multimesh_paths():
		return
	if not _import_system_fully_idle():
		return
	var queued := _reimport_manager.queue_composition_inherited_scenes_from_index(_wrapper_builder)
	if _reimport_manager.has_pending_inherited_scene_work(_wrapper_builder):
		return
	_composition_scene_queue_pending = false
	if queued > 0:
		print_rich(
			"[color=cyan]Nexus:[/color] Queued %d composition inherited scene(s) after reimport."
			% queued
		)


func _apply_stale_catchup(reason: String) -> void:
	var stale := _reimport_manager.collect_startup_stale_paths()
	var gltf_paths: Array = stale.get("gltf_paths", [])
	if gltf_paths.is_empty():
		return
	print_rich(
		"[color=cyan]Nexus:[/color] %s catch-up: reimporting %d stale indexed glTF(s)."
		% [reason, gltf_paths.size()]
	)
	_reimport_manager.apply_stale_catchup(stale, _wrapper_builder, reason == "Startup")
	request_multimesh_inherited_scene_queue()
	request_composition_inherited_scene_queue()


func _try_startup_import_catchup() -> void:
	if _startup_catchup_done:
		return
	_startup_catchup_done = true
	if not NexusPaths.auto_import_enabled():
		return
	if _reimport_manager == null or _wrapper_builder == null:
		return
	if NexusBatchLockScript.is_active():
		return
	var stale := _reimport_manager.collect_startup_stale_paths()
	var gltf_paths: Array = stale.get("gltf_paths", [])
	if gltf_paths.is_empty():
		return
	_apply_stale_catchup("Startup")


func _show_nexus_notification(message: String, severity: int = 0) -> void:
	if not get_editor_interface().has_method("get_editor_toaster"):
		return
	var toaster = get_editor_interface().get_editor_toaster()
	if toaster and toaster.has_method("push_toast"):
		toaster.push_toast(message, severity)


func queue_scene_creation(gltf_path: String, scene_type: String) -> void:
	if gltf_path.is_empty() or scene_type.is_empty():
		return
	if scene_type != NexusPaths.SCENE_STYLE_WRAPPER and scene_type != NexusPaths.SCENE_STYLE_INHERITED:
		return
	if not FileAccess.file_exists(gltf_path):
		push_warning("Nexus: glTF/GLB not found: %s" % gltf_path)
		return
	_wrapper_builder.queue_scene(gltf_path, scene_type)


func queue_scene_creation_for_folder(folder_path: String, scene_type: String) -> int:
	return _wrapper_builder.queue_scenes_in_folder(folder_path, scene_type)


func _register_project_settings() -> void:
	var needs_save := false
	if not ProjectSettings.has_setting(NexusPaths.SETTING_AUTO_IMPORT):
		ProjectSettings.set_setting(NexusPaths.SETTING_AUTO_IMPORT, true)
		ProjectSettings.set_initial_value(NexusPaths.SETTING_AUTO_IMPORT, true)
		needs_save = true
	if not ProjectSettings.has_setting(NexusPaths.SETTING_ASSET_INDEX):
		ProjectSettings.set_setting(NexusPaths.SETTING_ASSET_INDEX, "res://asset_index.json")
		ProjectSettings.set_initial_value(NexusPaths.SETTING_ASSET_INDEX, "res://asset_index.json")
		needs_save = true
	if not ProjectSettings.has_setting(NexusPaths.SETTING_MATERIAL_INDEX):
		ProjectSettings.set_setting(NexusPaths.SETTING_MATERIAL_INDEX, "res://material_index.json")
		ProjectSettings.set_initial_value(NexusPaths.SETTING_MATERIAL_INDEX, "res://material_index.json")
		needs_save = true
	if needs_save:
		ProjectSettings.save()


func _on_tool_submenu_id_pressed(id: int) -> void:
	match id:
		MENU_ID_IMPORT_MODE:
			_toggle_import_mode()
		MENU_ID_REIMPORT_ASSETS:
			_asset_tools.reimport_from_index()
			request_composition_inherited_scene_queue()
		MENU_ID_ASSET_SANITIZATION:
			_asset_tools.sanitize_orphaned_assets()
		MENU_ID_MATERIAL_SANITIZATION:
			_asset_tools.sanitize_orphaned_materials()


func _toggle_import_mode():
	var current = NexusPaths.auto_import_enabled()
	ProjectSettings.set_setting(NexusPaths.SETTING_AUTO_IMPORT, not current)
	ProjectSettings.save()
	_update_tool_menu_items()


func _update_tool_menu_items() -> void:
	if not _tool_submenu:
		return
	_tool_submenu.clear()
	var is_auto = NexusPaths.auto_import_enabled()
	_tool_submenu.add_item("Import Mode (Auto)" if is_auto else "Import Mode (Manual)", MENU_ID_IMPORT_MODE)
	_tool_submenu.set_item_tooltip(
		-1,
		"Toggle automatic post-processing. When Auto: config updates and scene creation run on import. When Manual: run tools explicitly."
	)
	_tool_submenu.add_separator()
	_tool_submenu.add_item("Reimport Assets", MENU_ID_REIMPORT_ASSETS)
	_tool_submenu.set_item_tooltip(
		-1,
		"Read asset_index.json and reimport all glTF/GLB files that exist at their expected paths. Skips missing assets with a warning."
	)
	_tool_submenu.add_item("Asset Sanitization", MENU_ID_ASSET_SANITIZATION)
	_tool_submenu.set_item_tooltip(
		-1,
		"Remove asset_index.json entries whose glTF/GLB files no longer exist. Cleans orphaned index entries."
	)
	_tool_submenu.add_item("Material Sanitization", MENU_ID_MATERIAL_SANITIZATION)
	_tool_submenu.set_item_tooltip(
		-1,
		"Remove material_index.json entries whose .tres files no longer exist. Cleans orphaned index entries."
	)
