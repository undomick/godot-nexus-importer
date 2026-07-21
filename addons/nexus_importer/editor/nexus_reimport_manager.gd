class_name NexusReimportManager
extends RefCounted

## Phased reimport queues, import-config fixups, and signal-based flush logic.

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
var _deferred_config_paths: Array[String] = []
var _deferred_wrapper_paths: Array[String] = []
var _deferred_composition_gltf_paths: Array[String] = []
var _deferred_multimesh_paths: Array[String] = []
var _purged_binary_import_warned: Dictionary = {}
var _composition_wave_active: bool = false
var _multimesh_wave_active: bool = false
var _composition_wave_wait_log_frames: int = 0
var _composition_scene_log_fingerprint: String = ""
var _mass_import_wrapper_flushed: Dictionary = {}
var _config_stabilized_paths: Dictionary = {}
var _config_pending_reimport_paths: Dictionary = {}
var _recently_reimported_ms: Dictionary = {}

func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin

func is_reimport_active() -> bool:
	return _reimport_pending or _reimport_in_progress or _batch_reimport_active

func was_recently_reimported(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not _recently_reimported_ms.has(gltf_path):
		return false
	return Time.get_ticks_msec() - int(_recently_reimported_ms[gltf_path]) < RECENTLY_REIMPORTED_GRACE_MS

func note_resources_reimported(resources: PackedStringArray) -> void:
	var now := Time.get_ticks_msec()
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	var gltf_to_index_entry := _index_entries_by_gltf_path(asset_index)
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
		var sources_ready := NexusSceneUtils.multimesh_sources_ready(canonical)
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
		var sources_ready := NexusSceneUtils.multimesh_sources_ready(path)
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
		if NexusSceneUtils.is_multimesh_manifest(path):
			var import_ready := NexusSceneUtils.multimesh_import_ready(path)
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
		var timer = _plugin.get_tree().create_timer(FLUSH_FALLBACK_TIMEOUT)
		timer.timeout.connect(_on_flush_fallback_timeout)

func queue_wrapper_fixup_for_paths(
	paths: Array[String], wrapper_builder: NexusWrapperBuilder
) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0
	var queued := 0
	for path in paths:
		if path is String and NexusSceneUtils.should_create_packed_scene(path):
			if wrapper_builder.needs_scene_processing(path):
				wrapper_builder.queue_scene(path)
				queued += 1
	return queued

func queue_composition_inherited_scenes_from_index(wrapper_builder: NexusWrapperBuilder) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0

	var evaluation := _evaluate_composition_inherited_scene_candidates(wrapper_builder, true)
	_log_composition_scene_queue_summary(evaluation)
	return evaluation.ready_to_queue.size()

func queue_multimesh_inherited_scenes_from_paths(
	wrapper_builder: NexusWrapperBuilder, gltf_paths: PackedStringArray
) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0

	var evaluation := _evaluate_multimesh_inherited_scene_candidates(
		wrapper_builder, gltf_paths, true
	)
	_log_multimesh_scene_queue_summary(evaluation)
	return evaluation.ready_to_queue.size()

func queue_multimesh_inherited_scenes_from_index(wrapper_builder: NexusWrapperBuilder) -> int:
	var paths: PackedStringArray = []
	for gltf_path in _multimesh_paths_from_index():
		paths.append(gltf_path)
	return queue_multimesh_inherited_scenes_from_paths(wrapper_builder, paths)

func has_pending_inherited_scene_work(wrapper_builder: NexusWrapperBuilder) -> bool:
	if not NexusPaths.auto_import_enabled():
		return false
	var composition_eval := _evaluate_composition_inherited_scene_candidates(wrapper_builder, false)
	if (
		not composition_eval.ready_to_queue.is_empty()
		or not composition_eval.waiting_on_deps.is_empty()
	):
		return true
	var multimesh_eval := _evaluate_multimesh_inherited_scene_candidates(
		wrapper_builder, PackedStringArray(), false
	)
	return (
		not multimesh_eval.ready_to_queue.is_empty()
		or not multimesh_eval.waiting_on_import.is_empty()
	)

func has_pending_composition_scene_work(wrapper_builder: NexusWrapperBuilder) -> bool:
	if has_deferred_composition_paths() or has_deferred_multimesh_paths():
		return true
	return has_pending_inherited_scene_work(wrapper_builder)

func _composition_paths_from_index() -> Array[String]:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return []

	var by_canonical: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		var meta := NexusUtils.get_nexus_metadata(gltf_path)
		var export_type: String = str(meta.get("export_type", ""))
		if export_type != "COMBINED_ASSET" and export_type != "LEVEL":
			continue
		by_canonical[gltf_path] = true

	for path in NexusSceneUtils.discover_unindexed_composition_gltfs(asset_index):
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			continue
		by_canonical[canonical] = true

	var composition_paths: Array[String] = []
	for key in by_canonical.keys():
		composition_paths.append(key)

	composition_paths.sort_custom(func(a: String, b: String) -> bool:
		var meta_a := NexusUtils.get_nexus_metadata(a)
		var meta_b := NexusUtils.get_nexus_metadata(b)
		var pri_a := _dependent_export_type_priority(str(meta_a.get("export_type", "")))
		var pri_b := _dependent_export_type_priority(str(meta_b.get("export_type", "")))
		if pri_a != pri_b:
			return pri_a < pri_b
		return a < b
	)
	return composition_paths

func _evaluate_composition_inherited_scene_candidates(
	wrapper_builder: NexusWrapperBuilder,
	do_queue: bool
) -> Dictionary:
	var ready_to_queue: Array[String] = []
	var waiting_on_deps: Array[String] = []
	var skipped_bloated: Array[String] = []
	var skipped_up_to_date: Array[String] = []

	for gltf_path in _composition_paths_from_index():
		if not NexusSceneUtils.should_create_packed_scene(gltf_path):
			continue
		if not NexusSceneUtils.is_thin_composition_gltf(gltf_path):
			skipped_bloated.append(gltf_path.get_file())
			continue
		if not wrapper_builder.needs_scene_processing(gltf_path):
			skipped_up_to_date.append(gltf_path.get_file())
			continue
		if not NexusSceneUtils.composition_dependencies_ready(gltf_path):
			waiting_on_deps.append(gltf_path.get_file())
			continue
		if wrapper_builder.is_scene_queued(gltf_path):
			continue
		ready_to_queue.append(gltf_path)
		if do_queue:
			wrapper_builder.queue_scene(gltf_path)

	return {
		"ready_to_queue": ready_to_queue,
		"waiting_on_deps": waiting_on_deps,
		"skipped_bloated": skipped_bloated,
		"skipped_up_to_date": skipped_up_to_date,
	}

func _log_composition_scene_queue_summary(evaluation: Dictionary) -> void:
	var queued_count: int = evaluation.get("ready_to_queue", []).size()
	var bloated: Array = evaluation.get("skipped_bloated", [])
	var waiting_deps: Array = evaluation.get("waiting_on_deps", [])
	var up_to_date: Array = evaluation.get("skipped_up_to_date", [])

	if (
		queued_count == 0
		and bloated.is_empty()
		and waiting_deps.is_empty()
		and up_to_date.is_empty()
	):
		return

	var has_actionable := queued_count > 0 or not bloated.is_empty() or not waiting_deps.is_empty()
	if not has_actionable and not up_to_date.is_empty():
		var fingerprint := ", ".join(up_to_date)
		if fingerprint == _composition_scene_log_fingerprint:
			return
		_composition_scene_log_fingerprint = fingerprint
	elif has_actionable:
		_composition_scene_log_fingerprint = ""

	var parts: PackedStringArray = []
	if queued_count > 0:
		parts.append("queued %d" % queued_count)
	if not bloated.is_empty():
		parts.append("skipped_bloated: [%s]" % ", ".join(bloated))
	if not waiting_deps.is_empty():
		parts.append("skipped_deps: [%s]" % ", ".join(waiting_deps))
	if not up_to_date.is_empty():
		parts.append("skipped_up_to_date: [%s]" % ", ".join(up_to_date))
	print_rich("[color=cyan]Nexus Reimport:[/color] Composition inherited scenes: %s." % ", ".join(parts))

func _multimesh_paths_from_index() -> Array[String]:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return []

	var by_canonical: Dictionary = {}
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
		if not NexusSceneUtils.is_multimesh_manifest(gltf_path):
			continue
		by_canonical[gltf_path] = true

	var paths: Array[String] = []
	for key in by_canonical.keys():
		paths.append(key)
	return NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(paths)

func _evaluate_multimesh_inherited_scene_candidates(
	wrapper_builder: NexusWrapperBuilder,
	gltf_paths: PackedStringArray,
	do_queue: bool
) -> Dictionary:
	var ready_to_queue: Array[String] = []
	var waiting_on_sources: Array[String] = []
	var waiting_on_import: Array[String] = []
	var skipped_up_to_date: Array[String] = []

	var paths_to_scan: Array[String] = []
	if gltf_paths.is_empty():
		paths_to_scan = _multimesh_paths_from_index()
	else:
		for path in gltf_paths:
			if path is String and not path.is_empty():
				paths_to_scan.append(path)

	for gltf_path in paths_to_scan:
		if not NexusSceneUtils.should_create_packed_scene(gltf_path):
			continue
		if not NexusSceneUtils.is_multimesh_manifest(gltf_path):
			continue
		if not wrapper_builder.needs_scene_processing(gltf_path):
			skipped_up_to_date.append(gltf_path.get_file())
			continue
		var stage_info := NexusSceneUtils.multimesh_pipeline_stage(gltf_path)
		var stage: String = str(stage_info.get("stage", ""))
		match stage:
			NexusSceneUtils.MULTIMESH_STAGE_SOURCES:
				waiting_on_sources.append(gltf_path.get_file())
			NexusSceneUtils.MULTIMESH_STAGE_MANIFEST:
				waiting_on_import.append(gltf_path.get_file())
			NexusSceneUtils.MULTIMESH_STAGE_INHERITED:
				if wrapper_builder.is_scene_queued(gltf_path):
					continue
				ready_to_queue.append(gltf_path)
				if do_queue:
					wrapper_builder.queue_scene(gltf_path)
			NexusSceneUtils.MULTIMESH_STAGE_DONE:
				skipped_up_to_date.append(gltf_path.get_file())

	return {
		"ready_to_queue": ready_to_queue,
		"waiting_on_sources": waiting_on_sources,
		"waiting_on_import": waiting_on_import,
		"skipped_up_to_date": skipped_up_to_date,
	}

func _log_multimesh_scene_queue_summary(evaluation: Dictionary) -> void:
	var queued_count: int = evaluation.get("ready_to_queue", []).size()
	var waiting_sources: Array = evaluation.get("waiting_on_sources", [])
	var waiting_import: Array = evaluation.get("waiting_on_import", [])
	var up_to_date: Array = evaluation.get("skipped_up_to_date", [])

	if (
		queued_count == 0
		and waiting_sources.is_empty()
		and waiting_import.is_empty()
		and up_to_date.is_empty()
	):
		return

	var parts: PackedStringArray = []
	if queued_count > 0:
		parts.append("queued %d" % queued_count)
	if not waiting_sources.is_empty():
		parts.append("skipped_sources: [%s]" % ", ".join(waiting_sources))
	if not waiting_import.is_empty():
		parts.append("skipped_import: [%s]" % ", ".join(waiting_import))
	if not up_to_date.is_empty():
		parts.append("skipped_up_to_date: [%s]" % ", ".join(up_to_date))
	print_rich("[color=cyan]Nexus Reimport:[/color] MultiMesh inherited scenes: %s." % ", ".join(parts))

func on_resources_reimported(
	resources: PackedStringArray,
	wrapper_builder: NexusWrapperBuilder,
	on_scan_needed: Callable
) -> bool:
	note_resources_reimported(resources)

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
		for path in resources:
			var ext = path.get_extension().to_lower()
			if ext == "gltf" or ext == "glb":
				if _should_defer_config_fix(path):
					if path not in _deferred_config_paths:
						_deferred_config_paths.append(path)
					activity_detected = true
				if (
					NexusPaths.auto_import_enabled()
					and NexusSceneUtils.should_create_packed_scene(path)
					and wrapper_builder.needs_scene_processing(path)
				):
					if NexusSceneUtils.is_composition_gltf(path):
						pass
					elif _mass_import_wrapper_flushed.has(path):
						var skip_flushed := false
						if NexusSceneUtils.is_multimesh_manifest(path):
							var import_ready := NexusSceneUtils.multimesh_import_ready(path)
							var tscn_path := NexusPaths.scene_path_for(
								path, NexusSceneUtils.preferred_scene_style_for_gltf(path)
							)
							skip_flushed = (
								import_ready.get("ok", false) and FileAccess.file_exists(tscn_path)
							)
						else:
							skip_flushed = not NexusSceneUtils.gltf_needs_reimport(path)
							# Missing .tscn after FS delete must recreate even if mass-import flushed.
							var flushed_tscn := NexusPaths.scene_path_for(
								path, NexusSceneUtils.preferred_scene_style_for_gltf(path)
							)
							if not FileAccess.file_exists(flushed_tscn):
								skip_flushed = false
						if not skip_flushed and path not in _deferred_wrapper_paths:
							_deferred_wrapper_paths.append(path)
							activity_detected = true
					elif path not in _deferred_wrapper_paths:
						_deferred_wrapper_paths.append(path)
						activity_detected = true
				if NexusPaths.auto_import_enabled() and _is_multimesh_manifest(path):
					on_scan_needed.call(true)
					activity_detected = true
			elif ext in ["tres", "png", "jpg", "jpeg", "webp"]:
				activity_detected = true
		_finish_batch_paths_from_signal(resources, wrapper_builder)
		if activity_detected:
			cooldown_remaining = SAFETY_FRAMES_ASSET
		return activity_detected

	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext == "gltf" or ext == "glb":
			if _should_defer_config_fix(path):
				if path not in _config_deferred_queue:
					_config_deferred_queue.append(path)
				_plugin.call_deferred("_nexus_apply_deferred_config_writes")
				activity_detected = true
			elif (
				NexusPaths.auto_import_enabled()
				and NexusSceneUtils.should_create_packed_scene(path)
				and wrapper_builder.needs_scene_processing(path)
			):
				wrapper_builder.queue_scene(path)
				activity_detected = true
			elif NexusPaths.auto_import_enabled() and _is_multimesh_manifest(path):
				if NexusSceneUtils.multimesh_manifest_import_complete(path):
					NexusImportContext.clear_multimesh_retry(path)
					if wrapper_builder.needs_scene_processing(path):
						wrapper_builder.queue_scene(path)
						activity_detected = true
					else:
						_request_multimesh_inherited_scene_queue()
				elif _plugin and _plugin.has_method("handle_multimesh_inherited_failure"):
					var stage: String = str(
						NexusSceneUtils.multimesh_pipeline_stage(path).get("stage", "")
					)
					if stage == NexusSceneUtils.MULTIMESH_STAGE_SOURCES:
						seed_deferred_multimesh_paths([path])
						_request_multimesh_wave()
					elif stage == NexusSceneUtils.MULTIMESH_STAGE_MANIFEST:
						_plugin.handle_multimesh_inherited_failure(
							path, str(NexusSceneUtils.multimesh_pipeline_stage(path).get("reason", ""))
						)
				on_scan_needed.call(true)
				activity_detected = true
		elif ext in ["tres", "png", "jpg", "jpeg", "webp"]:
			activity_detected = true

	if not _pending_reimport_after_signal.is_empty():
		var resources_arr: Array[String] = []
		for i in range(resources.size()):
			resources_arr.append(resources[i])
		_plugin.call_deferred("_nexus_flush_pending_reimport_queue", resources_arr)

	_finish_batch_paths_from_signal(resources, wrapper_builder)
	if activity_detected:
		cooldown_remaining = SAFETY_FRAMES_ASSET
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
		if NexusSceneUtils.is_multimesh_manifest(canonical):
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
		if not NexusSceneUtils.is_multimesh_manifest(canonical):
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
			if not FileAccess.file_exists(startup_tscn):
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

func collect_stale_index_reimport_paths(_wrapper_builder: NexusWrapperBuilder) -> Dictionary:
	var startup := collect_startup_stale_paths()
	var gltf_paths: Array = startup.get("gltf_paths", [])
	var dirs_to_scan: Dictionary = {}
	for path in gltf_paths:
		dirs_to_scan[path.get_base_dir()] = true
	var texture_paths: Array[String] = []
	for dir_path in dirs_to_scan.keys():
		texture_paths.append_array(
			NexusSceneUtils.collect_files_with_extensions(dir_path, ["png", "jpg", "jpeg", "webp"])
		)
	return {
		"gltf_paths": gltf_paths,
		"wrapper_only_paths": [],
		"texture_paths": texture_paths,
	}

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
				if NexusSceneUtils.is_multimesh_manifest(canonical):
					wrapper_builder.clear_inherited_abort(canonical)
					NexusSceneUtils.invalidate_multimesh_pipeline_cache(canonical)
				else:
					continue
			elif NexusSceneUtils.is_multimesh_manifest(canonical):
				NexusSceneUtils.invalidate_multimesh_pipeline_cache(canonical)
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
			if NexusSceneUtils.is_multimesh_manifest(canonical):
				wrapper_builder.clear_inherited_abort(canonical)
				NexusSceneUtils.invalidate_multimesh_pipeline_cache(canonical)
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

const _DEPENDENT_EXPORT_TYPES: Array[String] = ["COMBINED_ASSET", "ANIMATION_LIB", "MULTIMESH_MANIFEST", "LEVEL"]

const _DEPENDENT_EXPORT_TYPE_ORDER: Dictionary = {
	"COMBINED_ASSET": 0,
	"ANIMATION_LIB": 1,
	"MULTIMESH_MANIFEST": 2,
	"LEVEL": 3,
}

func _dependent_export_type_priority(export_type: String) -> int:
	return int(_DEPENDENT_EXPORT_TYPE_ORDER.get(export_type, 99))

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
		if export_type not in _DEPENDENT_EXPORT_TYPES:
			continue
		if NexusImportContext.is_level_pending_instance_pass(gltf_path):
			continue
		pending_paths.append(gltf_path)

	pending_paths.sort_custom(func(a: String, b: String) -> bool:
		var meta_a := NexusUtils.get_nexus_metadata(a)
		var meta_b := NexusUtils.get_nexus_metadata(b)
		var pri_a := _dependent_export_type_priority(str(meta_a.get("export_type", "")))
		var pri_b := _dependent_export_type_priority(str(meta_b.get("export_type", "")))
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

func apply_deferred_config_writes() -> void:
	if NexusBatchLock.is_active():
		_plugin.call_deferred("_nexus_apply_deferred_config_writes")
		return
	if _config_deferred_queue.is_empty():
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning() or _reimport_in_progress or _batch_reimport_active:
		_plugin.call_deferred("_nexus_apply_deferred_config_writes")
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
		var timer = _plugin.get_tree().create_timer(FLUSH_FALLBACK_TIMEOUT)
		timer.timeout.connect(_on_flush_fallback_timeout)

func flush_pending_reimport_queue(just_reimported: Array) -> void:
	if _pending_reimport_after_signal.is_empty():
		return
	if _reimport_in_progress or _batch_reimport_active:
		_plugin.call_deferred("_nexus_flush_pending_reimport_queue", just_reimported)
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_plugin.call_deferred("_nexus_flush_pending_reimport_queue", just_reimported)
		return
	var reimported_set: Dictionary = {}
	for path in just_reimported:
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

func fix_import_config_if_needed(gltf_path: String, do_write: bool = true) -> bool:
	if not FileAccess.file_exists(gltf_path):
		return false

	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false

	var import_config_path = gltf_path + ".import"
	var import_config = ConfigFile.new()
	var config_corrupt := false
	if FileAccess.file_exists(import_config_path):
		var loaded := NexusUtils.load_text_config(import_config_path)
		import_config = loaded.config
		if not loaded.ok:
			config_corrupt = true
			if loaded.corrupt:
				NexusUtils.remove_corrupt_import_sidecar(import_config_path)
			push_warning(
				"Nexus: Could not load import config for %s."
				% gltf_path.get_file()
			)
			import_config = ConfigFile.new()
			_salvage_sidecar_fields(import_config, import_config_path)

	if not config_corrupt and not NexusSceneUtils.import_config_has_drift(gltf_path, import_config, meta):
		return false

	if import_config.get_value("params", "import_script/path", "") != NexusPaths.IMPORT_POST_PROCESSOR:
		import_config.set_value("params", "import_script/path", NexusPaths.IMPORT_POST_PROCESSOR)

	if "root_type" in meta:
		var desired = _root_type_string(meta["root_type"])
		if import_config.get_value("params", "nodes/root_type", "") != desired:
			import_config.set_value("params", "nodes/root_type", desired)

	if _has_custom_lods(gltf_path):
		if import_config.get_value("params", "meshes/generate_lods", true):
			import_config.set_value("params", "meshes/generate_lods", false)

	var light_mode = meta.get("nexus_light_bake_mode", -1)
	if light_mode != -1:
		var desired = 2 if light_mode == 1 else 0
		if import_config.get_value("params", "meshes/light_baking", 0) != desired:
			import_config.set_value("params", "meshes/light_baking", desired)

	if _gltf_has_tangent_attributes(gltf_path):
		if import_config.get_value("params", "meshes/ensure_tangents", true):
			import_config.set_value("params", "meshes/ensure_tangents", false)

	if config_corrupt:
		import_config.set_value("remap", "importer", "scene")
		import_config.set_value("remap", "importer_version", 1)
		import_config.set_value("remap", "type", "PackedScene")

	if do_write:
		var err = import_config.save(import_config_path)
		if err != OK:
			push_error(
				"Nexus: Failed to save import config for %s: %s"
				% [gltf_path.get_file(), error_string(err)]
			)
			return false
	return true

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
		if NexusSceneUtils.is_composition_gltf(path) or NexusSceneUtils.is_multimesh_manifest(path):
			return SAFETY_FRAMES_HEAVY
	return SAFETY_FRAMES_ASSET


func _on_flush_fallback_timeout() -> void:
	if _pending_reimport_after_signal.is_empty():
		return
	if _reimport_in_progress or _batch_reimport_active:
		var timer = _plugin.get_tree().create_timer(FLUSH_FALLBACK_TIMEOUT)
		timer.timeout.connect(_on_flush_fallback_timeout)
		return
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		var timer = _plugin.get_tree().create_timer(FLUSH_FALLBACK_TIMEOUT)
		timer.timeout.connect(_on_flush_fallback_timeout)
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
	if NexusImportContext.is_mass_import_active() and NexusSceneUtils.is_multimesh_manifest(canonical):
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

func _is_multimesh_manifest(gltf_path: String) -> bool:
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	return meta.get("export_type") == "MULTIMESH_MANIFEST"

func _gltf_has_tangent_attributes(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	return not json_text.is_empty() and "\"TANGENT\"" in json_text

func _has_custom_lods(gltf_path: String) -> bool:
	const SEARCH = "nexus_is_lod"
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	return not json_text.is_empty() and SEARCH in json_text

func prime_nexus_import_configs() -> int:
	_purge_binary_import_sidecars()
	var updated := 0
	var reimport_paths: Array[String] = []
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	var gltf_to_index_entry := _index_entries_by_gltf_path(asset_index)

	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path := str(entry.get("relative_path", ""))
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		if _prime_import_config_for_path(gltf_path, reimport_paths):
			updated += 1

	for gltf_path in _discover_nexus_gltf_paths():
		if gltf_to_index_entry.has(gltf_path):
			continue
		if _prime_import_config_for_path(gltf_path, reimport_paths):
			updated += 1

	# Config rewrite requires reimport; fs.update_file alone is not enough.
	if not reimport_paths.is_empty():
		queue_catchup_reimport([], reimport_paths)
	return updated

func _prime_import_config_for_path(
	gltf_path: String, reimport_paths: Array[String]
) -> bool:
	if not fix_import_config_if_needed(gltf_path, true):
		return false
	# Sidecar rewrite makes the cached scene stale; always queue reimport.
	if gltf_path not in reimport_paths:
		reimport_paths.append(gltf_path)
	return true

func _index_entries_by_gltf_path(asset_index: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path := str(entry.get("relative_path", ""))
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			continue
		result[gltf_path] = entry
	return result

func _discover_nexus_gltf_paths() -> Array[String]:
	var paths: Array[String] = []
	var props_root := _props_root_dir()
	if props_root.is_empty():
		return paths
	_collect_nexus_gltf_paths(props_root, paths)
	return paths

func _props_root_dir() -> String:
	for candidate in ["res://props", "res://assets"]:
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ""

func _collect_nexus_gltf_paths(dir_path: String, out: Array[String]) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = dir_path.path_join(name)
		if dir.current_is_dir():
			_collect_nexus_gltf_paths(full, out)
		elif name.get_extension().to_lower() in ["gltf", "glb"]:
			if not NexusUtils.get_nexus_metadata(full).is_empty():
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()

func _purge_binary_import_sidecars() -> void:
	for root in ["res://props", "res://assets", "res://textures"]:
		if DirAccess.dir_exists_absolute(root):
			_purge_binary_import_sidecars_in_dir(root)

func _purge_binary_import_sidecars_in_dir(dir_path: String) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = dir_path.path_join(name)
		if dir.current_is_dir():
			_purge_binary_import_sidecars_in_dir(full)
		elif name.ends_with(".import"):
			if NexusUtils.remove_corrupt_import_sidecar(full):
				if not _purged_binary_import_warned.has(full):
					_purged_binary_import_warned[full] = true
					push_warning(
						"Nexus: Removed corrupt binary import sidecar '%s'."
						% full.get_file()
					)
		name = dir.get_next()
	dir.list_dir_end()

func _salvage_sidecar_fields(config: ConfigFile, import_path: String) -> void:
	var text := NexusUtils.read_utf8_text(import_path)
	if text.is_empty():
		return
	var section := ""
	for line_raw in text.split("\n", false):
		var line = line_raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2)
			continue
		var eq = line.find("=")
		if eq < 0 or section.is_empty():
			continue
		var key = line.substr(0, eq).strip_edges()
		var value = _unquote_sidecar_value(line.substr(eq + 1).strip_edges())
		if key.is_empty():
			continue
		config.set_value(section, key, value)

func _unquote_sidecar_value(value: String) -> Variant:
	if value.begins_with("[") and value.ends_with("]"):
		var inner = value.substr(1, value.length() - 2)
		var parts: Array[String] = []
		var current := ""
		var in_quotes := false
		for i in range(inner.length()):
			var ch = inner[i]
			if ch == '"':
				in_quotes = not in_quotes
				continue
			if ch == "," and not in_quotes:
				parts.append(current.strip_edges())
				current = ""
				continue
			current += ch
		if not current.is_empty():
			parts.append(current.strip_edges())
		var arr: PackedStringArray = []
		for part in parts:
			arr.append(str(_unquote_sidecar_value(part)))
		return arr
	if value.length() >= 2 and value.begins_with('"') and value.ends_with('"'):
		return value.substr(1, value.length() - 2).replace('\\"', '"')
	if value == "true":
		return true
	if value == "false":
		return false
	if value == "null":
		return null
	return value

func _root_type_string(nexus_type: String) -> String:
	# VehicleBody3D is not supported by the glTF importer; post-import replaces RigidBody3D.
	if nexus_type == "VEHICLE":
		return "RigidBody3D"
	var map = {
		"NODE_3D": "Node3D", "STATIC": "StaticBody3D", "RIGID": "RigidBody3D",
		"AREA": "Area3D", "CHARACTER_BODY": "CharacterBody3D",
		"NAVMESH": "NavigationRegion3D", "ANIMATABLE": "AnimatableBody3D"
	}
	return map.get(nexus_type, "Node3D")
