class_name NexusReimportManager
extends RefCounted

const NexusBatchLock = preload("res://addons/nexus_importer/scripts/nexus_batch_lock.gd")

## Phased reimport queues, import-config fixups, and signal-based flush logic.

const REIMPORT_DELAY = 2
const FLUSH_FALLBACK_TIMEOUT = 2.5
const SAFETY_FRAMES = 15

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
var _config_deferred_queue: Array[String] = []


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func is_reimport_active() -> bool:
	return _reimport_pending or _reimport_in_progress


func has_pending_paths() -> bool:
	return not _texture_paths.is_empty() or not _non_texture_paths.is_empty()


func tick_phased_reimport() -> bool:
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
		return true
	if has_pending_paths():
		if _reimport_phase == PHASE_IDLE:
			_reimport_phase = _initial_reimport_phase()
		return true
	return false


func on_resources_reimporting(_resources: PackedStringArray) -> void:
	_reimport_in_progress = true


func on_resources_reimported(
	resources: PackedStringArray,
	wrapper_builder: NexusWrapperBuilder,
	on_scan_needed: Callable
) -> bool:
	if NexusBatchLock.is_active():
		for path in resources:
			NexusBatchLock.defer_path(path)
		return false

	_reimport_in_progress = false
	_reimport_pending = false

	var activity_detected := false

	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext == "gltf" or ext == "glb":
			if fix_import_config_if_needed(path, false):
				if path not in _config_deferred_queue:
					_config_deferred_queue.append(path)
				_plugin.call_deferred("_nexus_apply_deferred_config_writes")
				activity_detected = true
			elif NexusPaths.auto_import_enabled() and wrapper_builder.needs_scene_processing(path):
				wrapper_builder.queue_scene(path)
				activity_detected = true
			elif NexusPaths.auto_import_enabled() and _is_multimesh_manifest(path):
				on_scan_needed.call(true)
				activity_detected = true
		elif ext in ["tres", "png", "jpg", "jpeg", "webp"]:
			activity_detected = true

	if not _pending_reimport_after_signal.is_empty():
		var resources_arr: Array[String] = []
		for i in range(resources.size()):
			resources_arr.append(resources[i])
		_plugin.call_deferred("_nexus_flush_pending_reimport_queue", resources_arr)

	if activity_detected:
		cooldown_remaining = SAFETY_FRAMES
	return activity_detected


func queue_paths(paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(paths)
		return
	for p in paths:
		if p is String:
			_route_path_to_queue(p)
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
		if p is String and p not in _non_texture_paths:
			_non_texture_paths.append(p)
	if _reimport_phase == PHASE_IDLE:
		_reimport_phase = _initial_reimport_phase()


func queue_dependent_gltfs_from_index() -> int:
	var asset_index_path := NexusPaths.asset_index_path()
	if not FileAccess.file_exists(asset_index_path):
		return 0

	var file = FileAccess.open(asset_index_path, FileAccess.READ)
	if not file:
		return 0
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		return 0
	var asset_index = json.get_data()
	file.close()
	if not asset_index is Dictionary:
		return 0

	var queued := 0
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
		var meta := NexusUtils.get_nexus_metadata(gltf_path)
		var export_type: String = meta.get("export_type", "")
		if export_type not in ["LEVEL", "MULTIMESH_MANIFEST"]:
			continue
		if gltf_path in _non_texture_paths:
			continue
		_non_texture_paths.append(gltf_path)
		queued += 1

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
	if fs.is_scanning() or _reimport_in_progress:
		_plugin.call_deferred("_nexus_apply_deferred_config_writes")
		return
	var paths = _config_deferred_queue.duplicate()
	_config_deferred_queue.clear()
	for path in paths:
		if fix_import_config_if_needed(path, true):
			_pending_reimport_after_signal[path] = true
			_pending_flush_ready = false
			print_rich("[color=yellow]Nexus:[/color] Config updated for %s." % path.get_file())
	if not _pending_reimport_after_signal.is_empty():
		var timer = _plugin.get_tree().create_timer(FLUSH_FALLBACK_TIMEOUT)
		timer.timeout.connect(_on_flush_fallback_timeout)


func flush_pending_reimport_queue(just_reimported: Array) -> void:
	if _pending_reimport_after_signal.is_empty():
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
	if FileAccess.file_exists(import_config_path):
		var load_err = import_config.load(import_config_path)
		if load_err != OK:
			push_warning(
				"Nexus: Could not load import config for %s: %s"
				% [gltf_path.get_file(), error_string(load_err)]
			)

	var changes_made := false

	if import_config.get_value("params", "import_script/path", "") != NexusPaths.IMPORT_POST_PROCESSOR:
		import_config.set_value("params", "import_script/path", NexusPaths.IMPORT_POST_PROCESSOR)
		changes_made = true

	if "root_type" in meta:
		var desired = _root_type_string(meta["root_type"])
		if import_config.get_value("params", "nodes/root_type", "") != desired:
			import_config.set_value("params", "nodes/root_type", desired)
			changes_made = true

	if _has_custom_lods(gltf_path):
		if import_config.get_value("params", "meshes/generate_lods", true):
			import_config.set_value("params", "meshes/generate_lods", false)
			changes_made = true

	var light_mode = meta.get("nexus_light_bake_mode", -1)
	if light_mode != -1:
		var desired = 2 if light_mode == 1 else 0
		if import_config.get_value("params", "meshes/light_baking", 0) != desired:
			import_config.set_value("params", "meshes/light_baking", desired)
			changes_made = true

	if _gltf_has_tangent_attributes(gltf_path):
		if import_config.get_value("params", "meshes/ensure_tangents", true):
			import_config.set_value("params", "meshes/ensure_tangents", false)
			changes_made = true

	if changes_made:
		if do_write:
			var err = import_config.save(import_config_path)
			if err != OK:
				push_error(
					"Nexus: Failed to save import config for %s: %s"
					% [gltf_path.get_file(), error_string(err)]
				)
				return false
		return true

	return false


func _reimport_safe_async_batch(paths: Array) -> void:
	if NexusBatchLock.is_active():
		NexusBatchLock.defer_paths(paths)
		_reimport_pending = false
		return
	for i in REIMPORT_DELAY:
		await _plugin.get_tree().process_frame
	var fs = _plugin.get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		queue_paths(paths)
		_reimport_pending = false
		return
	if _reimport_in_progress:
		queue_paths(paths)
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
	fs.reimport_files(PackedStringArray(paths))
	if not nodes_to_reselect.is_empty():
		_plugin.call_deferred("_nexus_restore_selection", nodes_to_reselect)
	cooldown_remaining = SAFETY_FRAMES
	_advance_reimport_phase()


func _on_flush_fallback_timeout() -> void:
	if _pending_reimport_after_signal.is_empty():
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
	elif path not in _non_texture_paths:
		_non_texture_paths.append(path)


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
		PHASE_GLTF:
			_reimport_phase = PHASE_IDLE
			_reimport_pending = false


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
	if gltf_path.get_extension().to_lower() == "glb":
		var j := NexusUtils.get_gltf_json_text(gltf_path)
		return SEARCH in j
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file:
		return false
	while file.get_position() < file.get_length():
		var line = file.get_line()
		if SEARCH in line:
			file.close()
			return true
	file.close()
	return false


func _root_type_string(nexus_type: String) -> String:
	var map = {
		"NODE_3D": "Node3D", "STATIC": "StaticBody3D", "RIGID": "RigidBody3D",
		"AREA": "Area3D", "CHARACTER_BODY": "CharacterBody3D",
		"NAVMESH": "NavigationRegion3D", "ANIMATABLE": "AnimatableBody3D"
	}
	return map.get(nexus_type, "Node3D")
