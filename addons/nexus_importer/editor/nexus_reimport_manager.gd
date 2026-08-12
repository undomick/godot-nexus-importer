class_name NexusReimportManager
extends RefCounted

## Phased reimport queues and signal-based flush logic.
## Inherited-scene queuing and import-config fixups live in dedicated helpers.

const NexusSceneCompleteness = preload(
	"res://addons/nexus_importer/scripts/nexus_scene_completeness.gd"
)

## Settle frames before reimport_files: 0 when FS idle, else 1.
const REIMPORT_DELAY_BUSY = 1
const FLUSH_FALLBACK_TIMEOUT = 2.5
## Post-batch idle cooldown: assets settle faster than composition/multimesh.
const SAFETY_FRAMES_ASSET = 3
const SAFETY_FRAMES_HEAVY = 6
const RECENTLY_REIMPORTED_GRACE_MS := 5000

const PHASE_IDLE = 0
const PHASE_TEXTURES = 1
const PHASE_GLTF = 2

var cooldown_remaining: int = 0

var _plugin: EditorPlugin
var _texture_paths: Array[String] = []
var _non_texture_paths: Array[String] = []
var _reimport_phase: int = PHASE_IDLE
var _reimport_pending: bool = false
var _pending_reimport_after_signal: Dictionary = {}
var _pending_flush_ready: bool = false
var _reimport_in_progress: bool = false
var _batch_reimport_active: bool = false
var _active_batch_paths: Dictionary = {}
var _config_deferred_queue: Array[String] = []
var _config_deferred_scheduled: bool = false
var _flush_pending_scheduled: bool = false
var _flush_pending_just_reimported: Array = []
var _flush_fallback_timer_active: bool = false
var _deferred_config_paths: Array[String] = []
var _deferred_wrapper_paths: Array[String] = []
var _deferred_composition_gltf_paths: Array[String] = []
var _deferred_multimesh_paths: Array[String] = []
var _composition_wave_active: bool = false
var _multimesh_wave_active: bool = false
var _composition_wave_wait_log_frames: int = 0
var _mass_import_wrapper_flushed: Dictionary = {}
var _config_stabilized_paths: Dictionary = {}
var _config_pending_reimport_paths: Dictionary = {}
var _recently_reimported_ms: Dictionary = {}

var _inherited_scenes: NexusInheritedSceneQueue
var _config_fixer: NexusImportConfigFixer

func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_inherited_scenes = NexusInheritedSceneQueue.new()
	_config_fixer = NexusImportConfigFixer.new()
	_config_fixer.set_reimport_queue_callback(
		func(paths) -> void: queue_catchup_reimport([], paths)
	)

func is_reimport_active() -> bool:
	return _reimport_pending or _reimport_in_progress or _batch_reimport_active

func was_recently_reimported(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not _recently_reimported_ms.has(gltf_path):
		return false
	return Time.get_ticks_msec() - int(_recently_reimported_ms[gltf_path]) < RECENTLY_REIMPORTED_GRACE_MS

func note_resources_reimported(
	resources: PackedStringArray, wrapper_builder: NexusWrapperBuilder = null
) -> void:
	var now := Time.get_ticks_msec()
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	var gltf_to_index_entry := NexusImportConfigFixer.index_entries_by_gltf_path(asset_index)
	for path in resources:
		if not path is String:
			continue
		var ext := path.get_extension().to_lower()
		if ext != "gltf" and ext != "glb":
			continue
		_recently_reimported_ms[path] = now
		if _config_pending_reimport_paths.erase(path):
			_config_stabilized_paths[path] = true
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		var index_entry: Dictionary = gltf_to_index_entry.get(canonical, {})
		var index_hash := str(index_entry.get("content_hash", "")).strip_edges()
		NexusImportState.mark_imported(canonical, index_hash)
		NexusSceneCompleteness.invalidate(canonical)
		if wrapper_builder != null:
			# Composition abort clear stays in plugin (skips forced resolution reimports).
			if NexusSceneUtils.is_composition_gltf(canonical):
				wrapper_builder.reset_build_retries(canonical)
				if canonical != path:
					wrapper_builder.reset_build_retries(path)
			else:
				wrapper_builder.clear_inherited_abort(canonical)
				if canonical != path:
					wrapper_builder.clear_inherited_abort(path)

func is_config_fix_needed(gltf_path: String) -> bool:
	return _should_defer_config_fix(gltf_path)

func _should_defer_config_fix(gltf_path: String) -> bool:
	if _config_stabilized_paths.has(gltf_path):
		if NexusSceneUtils.nexus_import_config_needs_fix(gltf_path):
			# Stabilized sidecar drifted back to defaults; invalidate and re-fix.
			_config_stabilized_paths.erase(gltf_path)
			return true
		return false
	return NexusSceneUtils.nexus_import_config_needs_fix(gltf_path)

func _mark_config_pending_reimport(gltf_path: String) -> void:
	_config_pending_reimport_paths[gltf_path] = true

func is_config_wave_pending() -> bool:
	return not _config_deferred_queue.is_empty() or not _pending_reimport_after_signal.is_empty()

func is_blocking_scene_creation() -> bool:
	if is_reimport_active() or is_config_wave_pending() or _batch_reimport_active:
		return true
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		return true
	return false

func prepare_editor_scenes_for_reimport(gltf_paths: Array) -> void:
	if gltf_paths.is_empty():
		return
	var ei = _plugin.get_editor_interface()
	if ei == null:
		return
	# Sync tab close during active reimport/inherited build crashes Godot (esp. Multimesh).
	if is_reimport_active():
		return
	if _plugin.has_method("is_wrapper_builder_busy") and _plugin.is_wrapper_builder_busy():
		return
	NexusEditorSceneGuard.close_open_scenes_for_reimport(ei, gltf_paths)

func has_pending_paths() -> bool:
	return not _texture_paths.is_empty() or not _non_texture_paths.is_empty()

func has_pending_reimport_work() -> bool:
	return has_pending_paths() or has_deferred_composition_paths() or has_deferred_multimesh_paths()

func has_deferred_composition_paths() -> bool:
	return not _deferred_composition_gltf_paths.is_empty()

func has_deferred_multimesh_paths() -> bool:
	return not _deferred_multimesh_paths.is_empty()

func is_composition_wave_active() -> bool:
	return _composition_wave_active

func is_multimesh_wave_active() -> bool:
	return _multimesh_wave_active

func try_queue_composition_wave() -> bool:
	if _deferred_composition_gltf_paths.is_empty():
		return false

	var hold_levels := not _deferred_multimesh_paths.is_empty()
	var ready_paths: Array[String] = []
	var non_level_waiting := false
	for path in _deferred_composition_gltf_paths:
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if hold_levels and NexusSceneUtils.is_level_gltf(canonical):
			continue
		non_level_waiting = true
		if NexusSceneUtils.composition_dependencies_ready(canonical):
			ready_paths.append(canonical)
	if ready_paths.is_empty():
		# Only LEVEL entries remain while MultiMesh is still deferred - let MM run.
		if hold_levels and not non_level_waiting:
			return false
		if _queue_blocking_composition_dependencies():
			return false
		_log_deferred_composition_wave_blocked()
		return false

	NexusImportContext.set_mass_import_active(false)
	_composition_wave_active = true
	for path in ready_paths:
		_erase_deferred_composition_path(path)
		if path not in _non_texture_paths:
			_non_texture_paths.append(path)

	_sort_gltf_queue()
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = PHASE_GLTF
	print_rich(
		"[color=cyan]Nexus:[/color] Queued %d composition glTF(s) for second import wave."
		% ready_paths.size()
	)
	return true

func try_queue_multimesh_wave() -> bool:
	if _deferred_multimesh_paths.is_empty():
		return false
	# Combined/Anim must finish before MultiMesh (LEVEL may still be held).
	for path in _deferred_composition_gltf_paths:
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if not NexusSceneUtils.is_level_gltf(canonical):
			return false

	var ready_paths: Array[String] = []
	for path in _deferred_multimesh_paths:
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		var sources_ready := NexusMultiMeshUtils.multimesh_sources_ready(canonical)
		if sources_ready.get("ok", false):
			ready_paths.append(canonical)
	if ready_paths.is_empty():
		_log_deferred_multimesh_wave_blocked()
		return false

	NexusImportContext.set_mass_import_active(false)
	NexusImportContext.set_multimesh_wave_active(true)
	_multimesh_wave_active = true
	for path in ready_paths:
		_erase_deferred_multimesh_path(path)
		if path not in _non_texture_paths:
			_non_texture_paths.append(path)

	_sort_gltf_queue()
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = PHASE_GLTF
	print_rich(
		"[color=cyan]Nexus:[/color] Queued %d MultiMesh manifest(s) for second import wave."
		% ready_paths.size()
	)
	return true

func _log_deferred_multimesh_wave_blocked() -> void:
	if _composition_wave_wait_log_frames > 0:
		_composition_wave_wait_log_frames -= 1
		return
	_composition_wave_wait_log_frames = 180
	var waiting: PackedStringArray = []
	for path in _deferred_multimesh_paths:
		var sources_ready := NexusMultiMeshUtils.multimesh_sources_ready(path)
		if sources_ready.get("ok", false):
			continue
		waiting.append(path.get_file())
	if waiting.is_empty():
		return
	print_rich(
		"[color=yellow]Nexus:[/color] MultiMesh wave 2 waiting on source assets for: %s"
		% ", ".join(waiting)
	)

func _erase_deferred_multimesh_path(canonical: String) -> void:
	for i in range(_deferred_multimesh_paths.size() - 1, -1, -1):
		var existing := NexusUtils.to_res_gltf_path(_deferred_multimesh_paths[i])
		if existing.is_empty():
			existing = _deferred_multimesh_paths[i]
		if existing == canonical:
			_deferred_multimesh_paths.remove_at(i)

func _is_deferred_composition_path(gltf_path: String) -> bool:
	var canonical := NexusUtils.to_res_gltf_path(gltf_path)
	if canonical.is_empty():
		canonical = gltf_path
	for path in _deferred_composition_gltf_paths:
		var existing := NexusUtils.to_res_gltf_path(path)
		if existing.is_empty():
			existing = path
		if existing == canonical:
			return true
	return false

func _collect_unready_composition_dependencies() -> Array[String]:
	var blocking: Array[String] = []
	var seen: Dictionary = {}
	for path in _deferred_composition_gltf_paths:
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if NexusSceneUtils.composition_dependencies_ready(canonical):
			continue
		var asset_ids := NexusSceneUtils.collect_composition_dependency_asset_ids(canonical)
		var dep_gltfs := NexusSceneUtils.resolve_dependency_gltf_paths(asset_ids)
		var own_key := NexusSceneUtils.gltf_identity_key(canonical)
		for dep_gltf in dep_gltfs:
			if not dep_gltf is String:
				continue
			var dep_canonical := NexusUtils.to_res_gltf_path(dep_gltf)
			if dep_canonical.is_empty():
				dep_canonical = dep_gltf
			if not own_key.is_empty() and NexusSceneUtils.gltf_identity_key(dep_canonical) == own_key:
				continue
			if _is_deferred_composition_path(dep_canonical):
				continue
			if NexusSceneUtils.dependency_scene_ready(dep_canonical):
				continue
			if seen.has(dep_canonical):
				continue
			seen[dep_canonical] = true
			blocking.append(dep_canonical)
	return NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(blocking)

func _queue_blocking_composition_dependencies() -> bool:
	var blocking := _collect_unready_composition_dependencies()
	if blocking.is_empty():
		return false

	var queued := false
	for dep_canonical in blocking:
		if dep_canonical in _non_texture_paths:
			continue
		_non_texture_paths.append(dep_canonical)
		queued = true
	if not queued:
		if blocking.is_empty():
			return false
		# Wave 2 still blocked; keep phased reimport running.
		if not has_pending_paths():
			return false
		if _reimport_phase == PHASE_IDLE:
			_reimport_phase = PHASE_GLTF
		_reimport_pending = true
		return true

	_sort_gltf_queue()
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = PHASE_GLTF
	_reimport_pending = true
	var names: PackedStringArray = []
	for dep_path in blocking:
		names.append(dep_path.get_file())
	print_rich(
		"[color=cyan]Nexus:[/color] Queued %d blocking dependency glTF(s) for composition wave 2: %s"
		% [blocking.size(), ", ".join(names)]
	)
	return true

func _log_deferred_composition_wave_blocked() -> void:
	if _composition_wave_wait_log_frames > 0:
		_composition_wave_wait_log_frames -= 1
		return
	_composition_wave_wait_log_frames = 180
	var waiting: PackedStringArray = []
	for path in _deferred_composition_gltf_paths:
		if NexusSceneUtils.composition_dependencies_ready(path):
			continue
		waiting.append(path.get_file())
	if waiting.is_empty():
		return
	var blocking := _collect_unready_composition_dependencies()
	var blocking_names: PackedStringArray = []
	for dep_path in blocking:
		blocking_names.append(dep_path.get_file())
	var extra := ""
	if not blocking_names.is_empty():
		extra = " (waiting on: %s)" % ", ".join(blocking_names)
	print_rich(
		"[color=yellow]Nexus:[/color] Composition wave 2 waiting on dependency scenes for: %s%s"
		% [", ".join(waiting), extra]
	)

func _erase_deferred_composition_path(canonical: String) -> void:
	for i in range(_deferred_composition_gltf_paths.size() - 1, -1, -1):
		var existing := NexusUtils.to_res_gltf_path(_deferred_composition_gltf_paths[i])
		if existing.is_empty():
			existing = _deferred_composition_gltf_paths[i]
		if existing == canonical:
			_deferred_composition_gltf_paths.remove_at(i)

func remove_gltf_from_queue(gltf_path: String) -> void:
	_non_texture_paths.erase(gltf_path)

func tick_phased_reimport() -> bool:
	if _batch_reimport_active:
		return false
	if is_config_wave_pending() and not NexusImportContext.is_instance_pass_active():
		return false
	if not _reimport_pending and _reimport_phase > PHASE_IDLE:
		_reimport_pending = true
		match _reimport_phase:
			PHASE_TEXTURES:
				if not _texture_paths.is_empty():
					_reimport_safe_async_batch(_texture_paths.duplicate())
					_texture_paths.clear()
				else:
					_advance_reimport_phase()
			PHASE_GLTF:
				if not _non_texture_paths.is_empty():
					_reimport_safe_async_batch(_non_texture_paths.duplicate())
					_non_texture_paths.clear()
				else:
					_reimport_phase = PHASE_IDLE
					_reimport_pending = false
					if not _deferred_composition_gltf_paths.is_empty():
						_request_composition_wave()
					if not _deferred_multimesh_paths.is_empty():
						_request_multimesh_wave()
					if (
						_deferred_composition_gltf_paths.is_empty()
						and _deferred_multimesh_paths.is_empty()
					):
						_request_composition_inherited_scene_queue()
		return true
	if has_pending_paths():
		if _reimport_phase == PHASE_IDLE:
			_reimport_phase = _initial_reimport_phase()
		return true
	return false

func on_resources_reimporting(_resources: PackedStringArray) -> void:
	_reimport_in_progress = true

func finish_reimport_signal() -> void:
	_batch_reimport_active = false
	_active_batch_paths.clear()
	_reimport_in_progress = false
	_reimport_pending = false

func has_deferred_mass_import_work() -> bool:
	return not _deferred_config_paths.is_empty() or not _deferred_wrapper_paths.is_empty()

func flush_mass_import_post_processing(wrapper_builder: NexusWrapperBuilder) -> void:
	if _deferred_config_paths.is_empty() and _deferred_wrapper_paths.is_empty():
		return

	var config_paths := _deferred_config_paths.duplicate()
	_deferred_config_paths.clear()
	for path in config_paths:
		if fix_import_config_if_needed(path, true):
			_mark_config_pending_reimport(path)
			_pending_reimport_after_signal[path] = true
			print_rich("[color=yellow]Nexus:[/color] Config updated for %s." % path.get_file())

	var wrapper_paths := NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(_deferred_wrapper_paths.duplicate())
	_deferred_wrapper_paths.clear()
	var queued_wrappers := 0
	for path in wrapper_paths:
		if NexusSceneUtils.is_composition_gltf(path):
			continue
		if _pending_reimport_after_signal.has(path):
			continue
		if NexusMultiMeshUtils.is_multimesh_manifest(path):
			var import_ready := NexusMultiMeshUtils.multimesh_import_ready(path)
			if not import_ready.get("ok", false):
				continue
		if NexusSceneUtils.should_create_packed_scene(path):
			wrapper_builder.queue_scene(path)
			_mass_import_wrapper_flushed[path] = true
			queued_wrappers += 1
	if queued_wrappers > 0:
		print_rich(
			"[color=cyan]Nexus:[/color] Queued %d wrapper/inherited scene(s) after mass import."
			% queued_wrappers
		)
	_request_composition_inherited_scene_queue()

	if not _pending_reimport_after_signal.is_empty():
		cooldown_remaining = SAFETY_FRAMES_HEAVY * 2
		_pending_flush_ready = false
		_arm_flush_fallback_timer()


func queue_wrapper_fixup_for_paths(
	paths: Array[String], wrapper_builder: NexusWrapperBuilder
) -> int:
	return _inherited_scenes.queue_wrapper_fixup_for_paths(paths, wrapper_builder)

func queue_composition_inherited_scenes_from_index(wrapper_builder: NexusWrapperBuilder) -> int:
	return _inherited_scenes.queue_composition_inherited_scenes_from_index(wrapper_builder)

func queue_multimesh_inherited_scenes_from_paths(
	wrapper_builder: NexusWrapperBuilder, gltf_paths: PackedStringArray
) -> int:
	return _inherited_scenes.queue_multimesh_inherited_scenes_from_paths(wrapper_builder, gltf_paths)

func queue_multimesh_inherited_scenes_from_index(wrapper_builder: NexusWrapperBuilder) -> int:
	return _inherited_scenes.queue_multimesh_inherited_scenes_from_index(wrapper_builder)

func has_pending_inherited_scene_work(wrapper_builder: NexusWrapperBuilder) -> bool:
	return _inherited_scenes.has_pending_inherited_scene_work(wrapper_builder)

func has_pending_composition_scene_work(wrapper_builder: NexusWrapperBuilder) -> bool:
	if has_deferred_composition_paths() or has_deferred_multimesh_paths():
		return true
	return has_pending_inherited_scene_work(wrapper_builder)

func fix_import_config_if_needed(gltf_path: String, do_write: bool = true) -> bool:
	return _config_fixer.fix_import_config_if_needed(gltf_path, do_write)

func prime_nexus_import_configs() -> int:
	return _config_fixer.prime_nexus_import_configs()

func on_resources_reimported(
	resources: PackedStringArray,
	wrapper_builder: NexusWrapperBuilder,
	on_scan_needed: Callable
) -> bool:
	note_resources_reimported(resources, wrapper_builder)

	if NexusBatchLock.is_active():
		for path in resources:
			NexusBatchLock.defer_path(path)
		_finish_batch_paths_from_signal(resources, wrapper_builder)
		return false

	if NexusImportContext.is_instance_pass_active() and NexusImportContext.is_mass_import_active():
		_finish_batch_paths_from_signal(resources, wrapper_builder)
		return false

	var activity_detected := false
	if NexusImportContext.is_mass_import_active():
		activity_detected = _handle_mass_import_reimported(resources, wrapper_builder, on_scan_needed)
		_finish_batch_paths_from_signal(resources, wrapper_builder)
		if activity_detected:
			cooldown_remaining = SAFETY_FRAMES_ASSET
		return activity_detected

	activity_detected = _handle_normal_reimported(resources, wrapper_builder, on_scan_needed)

	if not _pending_reimport_after_signal.is_empty():
		var resources_arr: Array[String] = []
		for i in range(resources.size()):
			resources_arr.append(resources[i])
		_schedule_flush_pending_reimport(resources_arr)

	_finish_batch_paths_from_signal(resources, wrapper_builder)
	if activity_detected:
		cooldown_remaining = SAFETY_FRAMES_ASSET
	return activity_detected


func _handle_mass_import_reimported(
	resources: PackedStringArray,
	wrapper_builder: NexusWrapperBuilder,
	on_scan_needed: Callable
) -> bool:
	var activity_detected := false
	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext in ["tres", "png", "jpg", "jpeg", "webp"]:
			activity_detected = true
			continue
		if ext != "gltf" and ext != "glb":
			continue

		if _should_defer_config_fix(path):
			if path not in _deferred_config_paths:
				_deferred_config_paths.append(path)
			activity_detected = true

		if _maybe_defer_mass_import_wrapper(path, wrapper_builder):
			activity_detected = true

		if NexusPaths.auto_import_enabled() and NexusMultiMeshUtils.is_multimesh_manifest(path):
			on_scan_needed.call(true)
			activity_detected = true
	return activity_detected


func _maybe_defer_mass_import_wrapper(path: String, wrapper_builder: NexusWrapperBuilder) -> bool:
	if not NexusPaths.auto_import_enabled():
		return false
	if not NexusSceneUtils.should_create_packed_scene(path):
		return false
	if not wrapper_builder.needs_scene_processing(path):
		return false
	# Compositions stay deferred until Wave 2; do not queue wrappers during mass import.
	if NexusSceneUtils.is_composition_gltf(path):
		return false

	if _mass_import_wrapper_flushed.has(path):
		if _should_skip_flushed_mass_import_wrapper(path):
			return false

	if path in _deferred_wrapper_paths:
		return false
	_deferred_wrapper_paths.append(path)
	return true


func _should_skip_flushed_mass_import_wrapper(path: String) -> bool:
	if NexusMultiMeshUtils.is_multimesh_manifest(path):
		var import_ready := NexusMultiMeshUtils.multimesh_import_ready(path)
		var tscn_path := NexusPaths.scene_path_for(
			path, NexusSceneUtils.preferred_scene_style_for_gltf(path)
		)
		return (
			import_ready.get("ok", false)
			and FileAccess.file_exists(tscn_path)
			and NexusSceneCompleteness.scene_is_complete(path, tscn_path)
		)

	if NexusSceneUtils.gltf_needs_reimport(path):
		return false
	# Missing or incomplete .tscn after FS delete / aborted build must recreate.
	var flushed_tscn := NexusPaths.scene_path_for(
		path, NexusSceneUtils.preferred_scene_style_for_gltf(path)
	)
	if not FileAccess.file_exists(flushed_tscn):
		return false
	return NexusSceneCompleteness.scene_is_complete(path, flushed_tscn)


func _handle_normal_reimported(
	resources: PackedStringArray,
	wrapper_builder: NexusWrapperBuilder,
	on_scan_needed: Callable
) -> bool:
	var activity_detected := false
	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext in ["tres", "png", "jpg", "jpeg", "webp"]:
			activity_detected = true
			continue
		if ext != "gltf" and ext != "glb":
			continue

		if _should_defer_config_fix(path):
			if path not in _config_deferred_queue:
				_config_deferred_queue.append(path)
			_schedule_deferred_config_writes()
			activity_detected = true
			continue

		if (
			NexusPaths.auto_import_enabled()
			and NexusSceneUtils.should_create_packed_scene(path)
			and wrapper_builder.needs_scene_processing(path)
		):
			wrapper_builder.queue_scene(path)
			activity_detected = true
			continue

		if not NexusPaths.auto_import_enabled() or not NexusMultiMeshUtils.is_multimesh_manifest(path):
			continue

		if NexusMultiMeshUtils.multimesh_manifest_import_complete(path):
			NexusImportContext.clear_multimesh_retry(path)
			if wrapper_builder.needs_scene_processing(path):
				wrapper_builder.queue_scene(path)
				activity_detected = true
			else:
				_request_multimesh_inherited_scene_queue()
		elif _plugin and _plugin.has_method("handle_multimesh_inherited_failure"):
			var stage: String = str(
				NexusMultiMeshUtils.multimesh_pipeline_stage(path).get("stage", "")
			)
			if stage == NexusMultiMeshUtils.MULTIMESH_STAGE_SOURCES:
				seed_deferred_multimesh_paths([path])
				_request_multimesh_wave()
			elif stage == NexusMultiMeshUtils.MULTIMESH_STAGE_MANIFEST:
				_plugin.handle_multimesh_inherited_failure(
					path, str(NexusMultiMeshUtils.multimesh_pipeline_stage(path).get("reason", ""))
				)
		on_scan_needed.call(true)
		activity_detected = true
	return activity_detected


func _finish_batch_paths_from_signal(
	resources: PackedStringArray, wrapper_builder: NexusWrapperBuilder = null
) -> void:
	if not _batch_reimport_active:
		_reimport_in_progress = false
		_reimport_pending = false
		return
	for path in resources:
		_active_batch_paths.erase(path)
	if _active_batch_paths.is_empty():
		_batch_reimport_active = false
		_reimport_in_progress = false
		_reimport_pending = false
		if (
			_composition_wave_active
			and _non_texture_paths.is_empty()
			and _deferred_composition_gltf_paths.is_empty()
			and _deferred_multimesh_paths.is_empty()
		):
			_composition_wave_active = false
			_request_composition_inherited_scene_queue()
		elif (
			_multimesh_wave_active
			and _non_texture_paths.is_empty()
			and _deferred_multimesh_paths.is_empty()
		):
			_multimesh_wave_active = false
			NexusImportContext.set_multimesh_wave_active(false)
			if _plugin and _plugin.has_method("on_multimesh_wave_batch_finished") and wrapper_builder != null:
				_plugin.on_multimesh_wave_batch_finished(resources, wrapper_builder)
			else:
				_request_multimesh_inherited_scene_queue()
			_request_composition_inherited_scene_queue()
		elif not _deferred_composition_gltf_paths.is_empty():
			_request_composition_wave()
		elif not _deferred_multimesh_paths.is_empty():
			_request_multimesh_wave()

func queue_multimesh_manifest_reimport(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	NexusImportContext.set_mass_import_active(false)
	NexusImportContext.set_multimesh_wave_active(true)
	_multimesh_wave_active = true
	var canonical := NexusUtils.to_res_gltf_path(gltf_path)
	if canonical.is_empty():
		canonical = gltf_path
	if canonical not in _non_texture_paths:
		_non_texture_paths.append(canonical)
	_sort_gltf_queue()
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = PHASE_GLTF
	_reimport_pending = true

func queue_paths(paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(paths)
		return
	for p in paths:
		if p is String:
			_route_path_to_queue(p)
	_sort_gltf_queue()
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = _initial_reimport_phase()

func queue_phased_paths(texture_paths: Array, gltf_paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(texture_paths)
		NexusBatchLock.defer_paths(gltf_paths)
		return
	for p in texture_paths:
		if p is String and p not in _texture_paths:
			_texture_paths.append(p)
	for p in gltf_paths:
		if not p is String:
			continue
		_route_gltf_path_to_queue(p)
	_sort_gltf_queue()
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = _initial_reimport_phase()

func seed_deferred_composition_paths(paths: Array) -> int:
	var sorted := NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(paths)
	var added := 0
	for path in sorted:
		if not path is String or path.is_empty():
			continue
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if NexusMultiMeshUtils.is_multimesh_manifest(canonical):
			continue
		if canonical not in _deferred_composition_gltf_paths:
			_deferred_composition_gltf_paths.append(canonical)
			added += 1
	return added

func seed_deferred_multimesh_paths(paths: Array) -> int:
	var sorted := NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(paths)
	var added := 0
	for path in sorted:
		if not path is String or path.is_empty():
			continue
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if not NexusMultiMeshUtils.is_multimesh_manifest(canonical):
			continue
		if canonical not in _deferred_multimesh_paths:
			_deferred_multimesh_paths.append(canonical)
			added += 1
	return added

func queue_phased_reimport_from_gltf_paths(texture_paths: Array, gltf_paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(texture_paths)
		NexusBatchLock.defer_paths(gltf_paths)
		return
	NexusImportContext.set_mass_import_active(true)
	_mass_import_wrapper_flushed.clear()
	var split := NexusSceneUtils.split_gltf_paths_for_phased_reimport(gltf_paths)
	queue_phased_paths(texture_paths, split.get("wave1", []))
	var composition_added := seed_deferred_composition_paths(split.get("deferred_composition", []))
	var multimesh_added := seed_deferred_multimesh_paths(split.get("deferred_multimesh", []))
	if composition_added > 0:
		print_rich(
			"[color=cyan]Nexus Reimport:[/color] Deferred %d composition/level glTF(s) for second import wave."
			% composition_added
		)
	if multimesh_added > 0:
		print_rich(
			"[color=cyan]Nexus Reimport:[/color] Deferred %d MultiMesh manifest(s) for second import wave."
			% multimesh_added
		)

func queue_catchup_reimport(texture_paths: Array, gltf_paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(texture_paths)
		NexusBatchLock.defer_paths(gltf_paths)
		return
	queue_phased_paths(texture_paths, gltf_paths)

func collect_stale_paths(candidates: Array[String], asset_index: Dictionary) -> Array[String]:
	var stale_paths: Array[String] = []
	var seen: Dictionary = {}
	for path in candidates:
		if not path is String or path.is_empty():
			continue
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if seen.has(canonical):
			continue
		if not FileAccess.file_exists(canonical):
			continue
		var index_entry: Dictionary = {}
		for asset_id in asset_index.keys():
			var entry = asset_index[asset_id]
			if not entry is Dictionary:
				continue
			var rel_path: String = entry.get("relative_path", "")
			if rel_path.is_empty():
				continue
			var indexed_path := NexusUtils.validate_index_path(rel_path)
			if indexed_path == canonical:
				index_entry = entry
				break
		if NexusSceneUtils.is_gltf_stale_for_catchup(canonical, index_entry):
			seen[canonical] = true
			stale_paths.append(canonical)
		# Missing packed scene must recreate even when the glTF itself is current.
		if NexusSceneUtils.should_create_packed_scene(canonical):
			var startup_tscn := NexusPaths.scene_path_for(
				canonical, NexusSceneUtils.preferred_scene_style_for_gltf(canonical)
			)
			if not FileAccess.file_exists(startup_tscn) and not seen.has(canonical):
				seen[canonical] = true
				stale_paths.append(canonical)
	return stale_paths

func collect_startup_stale_paths() -> Dictionary:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return {"gltf_paths": []}

	var candidates: Array[String] = []
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		candidates.append(gltf_path)

	return {"gltf_paths": collect_stale_paths(candidates, asset_index)}

func queue_indexed_dependents_for_changed(
	changed_gltf_paths: Array, wrapper_builder: NexusWrapperBuilder = null
) -> int:
	var dependents := NexusSceneUtils.find_indexed_dependents_for_changed_gltfs(changed_gltf_paths)
	if dependents.is_empty():
		return 0
	if wrapper_builder != null:
		var kept: Array[String] = []
		for path in dependents:
			if not path is String or path.is_empty():
				continue
			var canonical := NexusUtils.to_res_gltf_path(path)
			if canonical.is_empty():
				canonical = path
			if wrapper_builder.is_inherited_aborted(canonical):
				# Multimesh must rebuild when sources get Nexus materials; composition abort stays.
				if NexusMultiMeshUtils.is_multimesh_manifest(canonical):
					wrapper_builder.clear_inherited_abort(canonical)
					NexusMultiMeshUtils.invalidate_multimesh_pipeline_cache(canonical)
				else:
					continue
			elif NexusMultiMeshUtils.is_multimesh_manifest(canonical):
				NexusMultiMeshUtils.invalidate_multimesh_pipeline_cache(canonical)
			kept.append(canonical)
		dependents = kept
		if dependents.is_empty():
			return 0
	var split := NexusSceneUtils.split_gltf_paths_for_phased_reimport(dependents)
	var added := seed_deferred_composition_paths(split.get("deferred_composition", []))
	added += seed_deferred_multimesh_paths(split.get("deferred_multimesh", []))
	for path in split.get("wave1", []):
		if not path is String or path.is_empty():
			continue
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		if wrapper_builder != null and wrapper_builder.is_inherited_aborted(canonical):
			if NexusMultiMeshUtils.is_multimesh_manifest(canonical):
				wrapper_builder.clear_inherited_abort(canonical)
				NexusMultiMeshUtils.invalidate_multimesh_pipeline_cache(canonical)
			else:
				continue
		if canonical in _non_texture_paths:
			continue
		_non_texture_paths.append(canonical)
		added += 1
	if added > 0:
		_sort_gltf_queue()
		if _reimport_phase == PHASE_IDLE and not _non_texture_paths.is_empty():
			_reimport_phase = PHASE_GLTF
		print_rich(
			"[color=cyan]Nexus Reimport:[/color] Deferred %d indexed dependent glTF(s) for wave 2."
			% added
		)
	return added

func apply_stale_catchup(
	stale: Dictionary, _wrapper_builder: NexusWrapperBuilder, use_mass_import: bool = false
) -> bool:
	var gltf_paths: Array = stale.get("gltf_paths", [])
	if gltf_paths.is_empty():
		return false

	if use_mass_import:
		queue_phased_reimport_from_gltf_paths([], gltf_paths)
	else:
		queue_catchup_reimport([], gltf_paths)
	return true

func queue_dependent_gltfs_from_index() -> int:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return 0

	var pending_paths: Array[String] = []
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		var meta := NexusUtils.get_nexus_metadata(gltf_path)
		var export_type: String = meta.get("export_type", "")
		if not NexusExportOrder.is_dependent_export_type(export_type):
			continue
		if NexusImportContext.is_level_pending_instance_pass(gltf_path):
			continue
		pending_paths.append(gltf_path)

	pending_paths.sort_custom(func(a: String, b: String) -> bool:
		var meta_a := NexusUtils.get_nexus_metadata(a)
		var meta_b := NexusUtils.get_nexus_metadata(b)
		var pri_a := NexusExportOrder.export_type_priority(str(meta_a.get("export_type", "")))
		var pri_b := NexusExportOrder.export_type_priority(str(meta_b.get("export_type", "")))
		if pri_a != pri_b:
			return pri_a < pri_b
		return a < b
	)

	var queued := 0
	for gltf_path in pending_paths:
		if gltf_path in _non_texture_paths:
			continue
		_non_texture_paths.append(gltf_path)
		queued += 1

	if queued > 0:
		_sort_gltf_queue()
	if queued > 0 and _reimport_phase == PHASE_IDLE:
		_reimport_phase = PHASE_GLTF
	return queued

func _schedule_deferred_config_writes() -> void:
	if _config_deferred_scheduled:
		return
	if _plugin == null or not is_instance_valid(_plugin):
		return
	_config_deferred_scheduled = true
	_plugin.call_deferred("_nexus_apply_deferred_config_writes")


func _schedule_flush_pending_reimport(just_reimported: Array) -> void:
	for path in just_reimported:
		if path not in _flush_pending_just_reimported:
			_flush_pending_just_reimported.append(path)
	if _flush_pending_scheduled:
		return
	if _plugin == null or not is_instance_valid(_plugin):
		return
	_flush_pending_scheduled = true
	_plugin.call_deferred("_nexus_flush_pending_reimport_queue", [])


func _arm_flush_fallback_timer() -> void:
	if _flush_fallback_timer_active:
		return
	if _plugin == null or not is_instance_valid(_plugin):
		return
	var tree = _plugin.get_tree()
	if tree == null:
		return
	_flush_fallback_timer_active = true
	var timer = tree.create_timer(FLUSH_FALLBACK_TIMEOUT)
	timer.timeout.connect(_on_flush_fallback_timeout)


func apply_deferred_config_writes() -> void:
	_config_deferred_scheduled = false
	if NexusBatchLock.is_active():
		_schedule_deferred_config_writes()
		return
	if _config_deferred_queue.is_empty():
		return
	if _plugin == null or not is_instance_valid(_plugin):
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning() or _reimport_in_progress or _batch_reimport_active:
		_schedule_deferred_config_writes()
		return
	var paths = _config_deferred_queue.duplicate()
	_config_deferred_queue.clear()
	for path in paths:
		if fix_import_config_if_needed(path, true):
			_mark_config_pending_reimport(path)
			_pending_reimport_after_signal[path] = true
			print_rich("[color=yellow]Nexus:[/color] Config updated for %s." % path.get_file())
	if not paths.is_empty():
		cooldown_remaining = SAFETY_FRAMES_HEAVY * 2
		_pending_flush_ready = false
		_arm_flush_fallback_timer()

func flush_pending_reimport_queue(just_reimported: Array) -> void:
	_flush_pending_scheduled = false
	var merged: Array = just_reimported.duplicate()
	for path in _flush_pending_just_reimported:
		if path not in merged:
			merged.append(path)
	_flush_pending_just_reimported.clear()
	if _pending_reimport_after_signal.is_empty():
		return
	if _reimport_in_progress or _batch_reimport_active:
		_schedule_flush_pending_reimport(merged)
		return
	if _plugin == null or not is_instance_valid(_plugin):
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_schedule_flush_pending_reimport(merged)
		return
	var reimported_set: Dictionary = {}
	for path in merged:
		reimported_set[path] = true
	for path in reimported_set:
		_pending_reimport_after_signal.erase(path)
	if _pending_reimport_after_signal.is_empty():
		return
	if not _pending_flush_ready:
		_pending_flush_ready = true
		return
	for path in _pending_reimport_after_signal.keys():
		_route_path_to_queue(path)
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = _initial_reimport_phase()
	_pending_reimport_after_signal.clear()
	_pending_flush_ready = false

func _reimport_safe_async_batch(paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(paths)
		_reimport_pending = false
		return
	if _reimport_in_progress or _batch_reimport_active:
		queue_paths(paths)
		_reimport_pending = false
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	# Sole call site for EditorFileSystem.reimport_files - never nest from plugin.gd.
	var settle_frames := 0
	if fs != null and fs.is_scanning():
		settle_frames = REIMPORT_DELAY_BUSY
	for p in paths:
		_active_batch_paths[p] = true
	_batch_reimport_active = true
	_reimport_in_progress = true
	for i in settle_frames:
		await _plugin.get_tree().process_frame
	if fs.is_scanning():
		queue_paths(paths)
		_batch_reimport_active = false
		_reimport_in_progress = false
		_active_batch_paths.clear()
		_reimport_pending = false
		return
	if is_config_wave_pending() and not NexusImportContext.is_instance_pass_active():
		for p in paths:
			_route_path_to_queue(p)
		_batch_reimport_active = false
		_reimport_in_progress = false
		_active_batch_paths.clear()
		_reimport_pending = false
		return
	var path_set: Dictionary = {}
	for p in paths:
		path_set[p] = true
	var selection = _plugin.get_editor_interface().get_selection()
	var nodes_to_reselect = []
	for node in selection.get_selected_nodes():
		if node.scene_file_path in path_set:
			selection.remove_node(node)
			nodes_to_reselect.append(node)
	prepare_editor_scenes_for_reimport(paths)
	fs.reimport_files(PackedStringArray(paths))
	if not nodes_to_reselect.is_empty():
		_plugin.call_deferred("_nexus_restore_selection", nodes_to_reselect)
	cooldown_remaining = _safety_frames_for_paths(paths)
	_advance_reimport_phase()


func _safety_frames_for_paths(paths: Array) -> int:
	for p in paths:
		var path := str(p)
		if NexusSceneUtils.is_composition_gltf(path) or NexusMultiMeshUtils.is_multimesh_manifest(path):
			return SAFETY_FRAMES_HEAVY
	return SAFETY_FRAMES_ASSET


func _on_flush_fallback_timeout() -> void:
	_flush_fallback_timer_active = false
	if _plugin == null or not is_instance_valid(_plugin):
		return
	if _pending_reimport_after_signal.is_empty():
		return
	if _reimport_in_progress or _batch_reimport_active:
		_arm_flush_fallback_timer()
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_arm_flush_fallback_timer()
		return
	for path in _pending_reimport_after_signal.keys():
		_route_path_to_queue(path)
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = _initial_reimport_phase()
	_pending_reimport_after_signal.clear()
	_pending_flush_ready = false

func _route_path_to_queue(path: String) -> void:
	if _is_texture_path(path):
		if path not in _texture_paths:
			_texture_paths.append(path)
	else:
		_route_gltf_path_to_queue(path)

func _route_gltf_path_to_queue(path: String) -> void:
	if path.is_empty():
		return
	var canonical := NexusUtils.to_res_gltf_path(path)
	if canonical.is_empty():
		canonical = path
	if NexusImportContext.is_mass_import_active() and NexusSceneUtils.is_composition_gltf(canonical):
		if canonical not in _deferred_composition_gltf_paths:
			_deferred_composition_gltf_paths.append(canonical)
		return
	if NexusImportContext.is_mass_import_active() and NexusMultiMeshUtils.is_multimesh_manifest(canonical):
		if canonical not in _deferred_multimesh_paths:
			_deferred_multimesh_paths.append(canonical)
		return
	if canonical not in _non_texture_paths:
		_non_texture_paths.append(canonical)

func _sort_gltf_queue() -> void:
	_non_texture_paths = NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(_non_texture_paths)

func _initial_reimport_phase() -> int:
	if not _texture_paths.is_empty():
		return PHASE_TEXTURES
	if not _non_texture_paths.is_empty():
		return PHASE_GLTF
	return PHASE_IDLE

func _advance_reimport_phase() -> void:
	match _reimport_phase:
		PHASE_TEXTURES:
			if not _non_texture_paths.is_empty():
				_reimport_phase = PHASE_GLTF
			else:
				_reimport_phase = PHASE_IDLE
				_reimport_pending = false
				if not _deferred_composition_gltf_paths.is_empty():
					_request_composition_wave()
				if not _deferred_multimesh_paths.is_empty():
					_request_multimesh_wave()
				if (
					_deferred_composition_gltf_paths.is_empty()
					and _deferred_multimesh_paths.is_empty()
				):
					_request_composition_inherited_scene_queue()
		PHASE_GLTF:
			if _non_texture_paths.is_empty():
				_reimport_phase = PHASE_IDLE
				_reimport_pending = false
				if not _deferred_composition_gltf_paths.is_empty():
					_request_composition_wave()
				if not _deferred_multimesh_paths.is_empty():
					_request_multimesh_wave()
				if (
					_deferred_composition_gltf_paths.is_empty()
					and _deferred_multimesh_paths.is_empty()
				):
					_request_composition_inherited_scene_queue()

func _request_multimesh_wave() -> void:
	if _plugin and _plugin.has_method("request_multimesh_wave"):
		_plugin.request_multimesh_wave()

func _request_multimesh_inherited_scene_queue() -> void:
	if _plugin and _plugin.has_method("request_multimesh_inherited_scene_queue"):
		_plugin.request_multimesh_inherited_scene_queue()

func _request_composition_inherited_scene_queue() -> void:
	if _plugin and _plugin.has_method("request_composition_inherited_scene_queue"):
		_plugin.request_composition_inherited_scene_queue()

func _request_composition_wave() -> void:
	if _plugin and _plugin.has_method("request_composition_wave"):
		_plugin.request_composition_wave()

func _is_texture_path(path: String) -> bool:
	var ext = path.get_extension().to_lower()
	return ext in ["png", "jpg", "jpeg", "webp"]

func _is_gltf_path(path: String) -> bool:
	var ext = path.get_extension().to_lower()
	return ext == "gltf" or ext == "glb"
