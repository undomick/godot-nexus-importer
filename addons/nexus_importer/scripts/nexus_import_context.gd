class_name NexusImportContext
extends RefCounted

## Tracks mass-import windows where loading external PackedScenes during glTF post-import can deadlock.

static var _mass_import_active: bool = false
static var _force_allow_external_loads: bool = false
static var _multimesh_wave_active: bool = false
# Active during a composition reimport that must resolve instance placeholders
# non-deferred (e.g. ensure_nexus_gltf_imported_async before an inherited build).
# Makes _on_resources_reimporting skip set_mass_import_active(true) and makes
# should_defer_external_scene_loads() return false so _post_import bakes the
# resolved instances into the glTF .import instead of leaving placeholders.
static var _composition_resolution_reimport: bool = false
static var _multimesh_post_import_active: bool = false
static var _levels_needing_instance_pass: Dictionary = {}
static var _instance_pass_queue: Array[String] = []
static var _current_instance_pass_path: String = ""
static var _skipped_instance_pass_levels: Dictionary = {}
static var _instance_pass_completed_paths: Array[String] = []
static var _pending_multimesh_retry_paths: Dictionary = {}

const MAX_MULTIMESH_REIMPORT_RETRIES := 3


static func set_mass_import_active(active: bool) -> void:
	_mass_import_active = active


static func is_mass_import_active() -> bool:
	return _mass_import_active


static func is_instance_pass_active() -> bool:
	return _force_allow_external_loads


static func should_defer_external_scene_loads() -> bool:
	if _force_allow_external_loads or _multimesh_wave_active or _composition_resolution_reimport:
		return false
	return _mass_import_active


static func set_composition_resolution_reimport(active: bool) -> void:
	_composition_resolution_reimport = active


static func is_composition_resolution_reimport() -> bool:
	return _composition_resolution_reimport


static func set_multimesh_wave_active(active: bool) -> void:
	_multimesh_wave_active = active


static func is_multimesh_wave_active() -> bool:
	return _multimesh_wave_active


static func set_multimesh_post_import_active(active: bool) -> void:
	_multimesh_post_import_active = active


static func is_multimesh_post_import_active() -> bool:
	return _multimesh_post_import_active


static func mark_level_needs_instance_pass(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	_levels_needing_instance_pass[gltf_path] = true


static func take_levels_needing_instance_pass() -> Array[String]:
	var paths: Array[String] = []
	for path in _levels_needing_instance_pass.keys():
		paths.append(path)
	_levels_needing_instance_pass.clear()
	return paths


static func has_levels_needing_instance_pass() -> bool:
	return not _levels_needing_instance_pass.is_empty()


static func is_level_pending_instance_pass(gltf_path: String) -> bool:
	if gltf_path.is_empty():
		return false
	if _levels_needing_instance_pass.has(gltf_path):
		return true
	if gltf_path == _current_instance_pass_path:
		return true
	return gltf_path in _instance_pass_queue


static func record_instance_pass_reimport(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	if gltf_path not in _instance_pass_completed_paths:
		_instance_pass_completed_paths.append(gltf_path)


static func take_instance_pass_completed_paths() -> Array[String]:
	var paths: Array[String] = []
	for path in _instance_pass_completed_paths:
		paths.append(path)
	_instance_pass_completed_paths.clear()
	return paths


static func start_instance_pass(levels: Array[String]) -> void:
	_instance_pass_queue.clear()
	_current_instance_pass_path = ""
	_skipped_instance_pass_levels.clear()
	for path in levels:
		if path is String and not path.is_empty() and path not in _instance_pass_queue:
			_instance_pass_queue.append(path)
	_force_allow_external_loads = not _instance_pass_queue.is_empty()


static func next_instance_pass_target() -> String:
	if not _current_instance_pass_path.is_empty():
		return _current_instance_pass_path
	while not _instance_pass_queue.is_empty():
		var candidate: String = _instance_pass_queue[0]
		if _skipped_instance_pass_levels.has(candidate):
			_instance_pass_queue.pop_front()
			continue
		_current_instance_pass_path = candidate
		return _current_instance_pass_path
	return ""


static func skip_instance_pass_level(gltf_path: String, reason: String) -> void:
	if gltf_path.is_empty():
		return
	_skipped_instance_pass_levels[gltf_path] = reason


static func resources_include_current_instance_pass_target(resources: PackedStringArray) -> bool:
	if _current_instance_pass_path.is_empty():
		return false
	for resource in resources:
		if resource == _current_instance_pass_path:
			return true
	return false


static func complete_current_instance_pass() -> void:
	if not _current_instance_pass_path.is_empty():
		record_instance_pass_reimport(_current_instance_pass_path)
	if (
		not _instance_pass_queue.is_empty()
		and _instance_pass_queue[0] == _current_instance_pass_path
	):
		_instance_pass_queue.pop_front()
	_current_instance_pass_path = ""
	if _instance_pass_queue.is_empty():
		_force_allow_external_loads = false


static func instance_pass_remaining() -> int:
	return _instance_pass_queue.size()


static func cancel_instance_pass() -> void:
	_instance_pass_queue.clear()
	_current_instance_pass_path = ""
	_skipped_instance_pass_levels.clear()
	_force_allow_external_loads = false


static func mark_multimesh_retry(gltf_path: String) -> bool:
	if gltf_path.is_empty():
		return false
	var canonical := NexusUtils.to_res_gltf_path(gltf_path)
	if canonical.is_empty():
		canonical = gltf_path
	var count: int = int(_pending_multimesh_retry_paths.get(canonical, 0))
	if count >= MAX_MULTIMESH_REIMPORT_RETRIES:
		return false
	_pending_multimesh_retry_paths[canonical] = count + 1
	return true


static func multimesh_retry_count(gltf_path: String) -> int:
	if gltf_path.is_empty():
		return 0
	var canonical := NexusUtils.to_res_gltf_path(gltf_path)
	if canonical.is_empty():
		canonical = gltf_path
	return int(_pending_multimesh_retry_paths.get(canonical, 0))


static func multimesh_retry_exhausted(gltf_path: String) -> bool:
	return multimesh_retry_count(gltf_path) >= MAX_MULTIMESH_REIMPORT_RETRIES


static func clear_multimesh_retry(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	var canonical := NexusUtils.to_res_gltf_path(gltf_path)
	if canonical.is_empty():
		canonical = gltf_path
	_pending_multimesh_retry_paths.erase(canonical)


static func has_multimesh_retry_paths() -> bool:
	return not _pending_multimesh_retry_paths.is_empty()


static func take_multimesh_retry_paths() -> Array[String]:
	var paths: Array[String] = []
	for path in _pending_multimesh_retry_paths.keys():
		paths.append(path)
	_pending_multimesh_retry_paths.clear()
	return paths


static func peek_multimesh_retry_paths() -> Array[String]:
	var paths: Array[String] = []
	for path in _pending_multimesh_retry_paths.keys():
		paths.append(path)
	return paths
