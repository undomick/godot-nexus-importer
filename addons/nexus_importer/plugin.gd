@tool
extends EditorPlugin

## Nexus Importer: Custom glTF importer for the Nexus Blender Export Pipeline.
## Handles auto-reimport, wrapper creation, custom root types, and collision layers.

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()
const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"
const SETTING_SCENE_STYLE = "nexus/import/scene_style"
const SETTING_ASSET_INDEX = "nexus/import/asset_index_path"
const SETTING_MATERIAL_INDEX = "nexus/import/material_index_path"

const SCENE_STYLE_WRAPPER = "wrapper"
const SCENE_STYLE_INHERITED = "inherited"

const MENU_ID_IMPORT_MODE = 0
const MENU_ID_SCENE_STYLE = 1
const MENU_ID_REIMPORT_ASSETS = 2
const MENU_ID_ASSET_SANITIZATION = 3

## Frames to wait before reimport (avoids progress_dialog errors - forum #123523)
const REIMPORT_DELAY = 2
## Seconds before flush fallback when resources_reimported may not fire
const FLUSH_FALLBACK_TIMEOUT = 2.5
## Frames to wait for scene load in inherited creation
const SCENE_LOAD_WAIT_FRAMES = 3

var _tool_submenu: PopupMenu

# --- STATUS & QUEUES ---
var _wrapper_queue: Dictionary = {}  # path -> "wrapper" | "inherited"
var _fs_context_plugin: RefCounted
var _config_deferred_queue: Array[String] = []
var _texture_paths: Array[String] = []
var _non_texture_paths: Array[String] = []
var _reimport_phase: int = 0  # 0=idle, 1=textures, 2=non-textures
var _reimport_pending: bool = false  # async reimport in progress - don't start another
var _pending_reimport_after_signal: Dictionary = {}  # path -> true: config written, wait for resources_reimported
var _pending_flush_ready: bool = false  # true after first resources_reimported since add; allows flush on second
var _reimport_in_progress: bool = false  # true between resources_reimporting and resources_reimported
var _scan_needed: bool = false
var _inherited_creation_in_progress: bool = false

# --- DEBOUNCING ---
var _cooldown_timer: int = 0
const SAFETY_FRAMES = 15

## Never write .import during resources_reimported - triggers "Task 'reimport' already exists".
## Use await process_frame before reimport_files - avoids progress_dialog errors (see Godot forum #123523).

func _enter_tree():
	add_scene_post_import_plugin(scene_post_processor)
	var fs = get_editor_interface().get_resource_filesystem()
	if not fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.connect(_on_resources_reimported)
	if not fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.connect(_on_resources_reimporting)
	
	var needs_save = false
	if not ProjectSettings.has_setting(SETTING_AUTO_IMPORT):
		ProjectSettings.set_setting(SETTING_AUTO_IMPORT, true)
		ProjectSettings.set_initial_value(SETTING_AUTO_IMPORT, true)
		needs_save = true
	if not ProjectSettings.has_setting(SETTING_ASSET_INDEX):
		ProjectSettings.set_setting(SETTING_ASSET_INDEX, "res://asset_index.json")
		ProjectSettings.set_initial_value(SETTING_ASSET_INDEX, "res://asset_index.json")
		needs_save = true
	if not ProjectSettings.has_setting(SETTING_MATERIAL_INDEX):
		ProjectSettings.set_setting(SETTING_MATERIAL_INDEX, "res://material_index.json")
		ProjectSettings.set_initial_value(SETTING_MATERIAL_INDEX, "res://material_index.json")
		needs_save = true
	if not ProjectSettings.has_setting(SETTING_SCENE_STYLE):
		ProjectSettings.set_setting(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)
		ProjectSettings.set_initial_value(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)
		needs_save = true
	if needs_save:
		ProjectSettings.save()
	
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

# --- THE WATCHDOG ---

func _process(_delta):
	if _cooldown_timer > 0:
		_cooldown_timer -= 1
		return 

	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_cooldown_timer = 10 
		return

	# PRIORITY A: Phased reimport (textures first, then non-textures)
	if not _reimport_pending and _reimport_phase > 0:
		_reimport_pending = true
		if _reimport_phase == 1 and not _texture_paths.is_empty():
			_reimport_safe_async_batch(_texture_paths.duplicate())
			_texture_paths.clear()
		elif _reimport_phase == 2 and not _non_texture_paths.is_empty():
			_reimport_safe_async_batch(_non_texture_paths.duplicate())
			_non_texture_paths.clear()
		else:
			_reimport_phase = 0
			_reimport_pending = false
		return
	elif not _texture_paths.is_empty() or not _non_texture_paths.is_empty():
		if _reimport_phase == 0:
			# Start phased reimport: phase 1 if we have textures, else phase 2
			_reimport_phase = 2 if _texture_paths.is_empty() else 1
		return

	# PRIORITY B: Scene Creation - Wrapper or Inherited (one file per frame for editor responsiveness)
	# Block during reimport - ResourceSaver.save / EditorInterface can trigger recursive reimport_files
	if not _wrapper_queue.is_empty() and not _reimport_pending and not _reimport_in_progress and not _inherited_creation_in_progress:
		var file_to_process = _wrapper_queue.keys()[0]
		var scene_type: String = _wrapper_queue[file_to_process]
		_wrapper_queue.erase(file_to_process)
		if scene_type == SCENE_STYLE_INHERITED:
			_inherited_creation_in_progress = true
			_create_inherited_scene_async(file_to_process)
		else:
			_create_or_update_wrapper(file_to_process)
			if _wrapper_queue.is_empty():
				_scan_needed = true
		return

	# PRIORITY C: Final Scan
	if _scan_needed:
		_scan_needed = false
		fs.scan()

# --- ASYNC REIMPORT (avoid progress_dialog errors - see forum.godotengine.org/t/123523) ---

func _reimport_safe_async_batch(paths: Array) -> void:
	# Minimal delay to escape signal/deferred context (forum #123523).
	for i in REIMPORT_DELAY:
		await get_tree().process_frame
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_queue_paths_by_type(paths)
		_reimport_pending = false
		return
	if _reimport_in_progress:
		_queue_paths_by_type(paths)
		_reimport_pending = false
		return
	var path_set: Dictionary = {}
	for p in paths:
		path_set[p] = true
	var selection = get_editor_interface().get_selection()
	var nodes_to_reselect = []
	for node in selection.get_selected_nodes():
		if node.scene_file_path in path_set:
			selection.remove_node(node)
			nodes_to_reselect.append(node)
	fs.reimport_files(PackedStringArray(paths))
	if not nodes_to_reselect.is_empty():
		call_deferred("_restore_selection", nodes_to_reselect)
	_cooldown_timer = SAFETY_FRAMES
	# Advance phase: if we ran phase 1 and have non-textures, go to phase 2; else idle
	if _reimport_phase == 1 and not _non_texture_paths.is_empty():
		_reimport_phase = 2
	elif _reimport_phase == 2 or _texture_paths.is_empty():
		_reimport_phase = 0
	_reimport_pending = false

func _queue_paths_by_type(paths: Array) -> void:
	for p in paths:
		if p is String:
			if _is_texture_path(p):
				if p not in _texture_paths:
					_texture_paths.append(p)
			else:
				if p not in _non_texture_paths:
					_non_texture_paths.append(p)
	if _reimport_phase == 0:
		_reimport_phase = 2 if _texture_paths.is_empty() else 1

func _is_texture_path(path: String) -> bool:
	var ext = path.get_extension().to_lower()
	return ext in ["png", "jpg", "jpeg", "webp"]

# --- EVENT HANDLER ---

func _on_resources_reimporting(_resources: PackedStringArray):
	_reimport_in_progress = true

func _on_resources_reimported(resources: PackedStringArray):
	_reimport_in_progress = false

	var is_auto_mode = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	var activity_detected = false

	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext == "gltf" or ext == "glb":
			# 1. Config Check - always run so glTFs get Nexus import script (manual + auto)
			if _check_and_fix_import_config(path, false):
				if path not in _config_deferred_queue:
					_config_deferred_queue.append(path)
				call_deferred("_apply_deferred_config_writes")
				activity_detected = true
			else:
				# 2. Wrapper/Inherited creation - only in auto mode
				if is_auto_mode and _needs_wrapper_processing(path):
					var scene_style = ProjectSettings.get_setting(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)
					if not _wrapper_queue.has(path):
						_wrapper_queue[path] = scene_style
					activity_detected = true
				elif is_auto_mode and _is_multimesh(path):
					_scan_needed = true
					activity_detected = true

		elif ext in ["tres", "png", "jpg", "jpeg", "webp"]:
			activity_detected = true

	# Signal-based reimport safety: only queue our reimport AFTER a reimport cycle completes
	if not _pending_reimport_after_signal.is_empty():
		var resources_arr: Array[String] = []
		for i in range(resources.size()):
			resources_arr.append(resources[i])
		call_deferred("_flush_pending_reimport_queue", resources_arr)

	if activity_detected:
		_cooldown_timer = SAFETY_FRAMES
		_show_nexus_notification("Nexus: Import complete", EditorToaster.SEVERITY_INFO)

# --- REIMPORT QUEUE FLUSH (signal-based) ---

func _flush_pending_reimport_queue(just_reimported: Array):
	## Called deferred after resources_reimported. Waits two cycles: first cycle may be textures only
	## (glTF still reimporting). On second cycle, paths still in _pending get queued for phased reimport.
	if _pending_reimport_after_signal.is_empty(): return
	var reimported_set: Dictionary = {}
	for path in just_reimported:
		reimported_set[path] = true
	# Remove paths Godot just reimported - no need for our reimport
	for path in reimported_set:
		_pending_reimport_after_signal.erase(path)
	if _pending_reimport_after_signal.is_empty(): return
	# Paths still pending: either Godot hasn't reimported yet (wait) or won't (queue now)
	if not _pending_flush_ready:
		_pending_flush_ready = true
		return
	# Second cycle: flush remaining to phased queues (config-fix paths are glTFs only)
	for path in _pending_reimport_after_signal.keys():
		if _is_texture_path(path):
			if path not in _texture_paths:
				_texture_paths.append(path)
		else:
			if path not in _non_texture_paths:
				_non_texture_paths.append(path)
	if _reimport_phase == 0:
		_reimport_phase = 2 if _texture_paths.is_empty() else 1
	_pending_reimport_after_signal.clear()
	_pending_flush_ready = false

func _on_flush_fallback_timeout():
	## Fallback when resources_reimported does not fire again after config write.
	## Ensures reimport is triggered even if Godot skips the signal.
	if _pending_reimport_after_signal.is_empty(): return
	for path in _pending_reimport_after_signal.keys():
		if _is_texture_path(path):
			if path not in _texture_paths:
				_texture_paths.append(path)
		else:
			if path not in _non_texture_paths:
				_non_texture_paths.append(path)
	if _reimport_phase == 0:
		_reimport_phase = 2 if _texture_paths.is_empty() else 1
	_pending_reimport_after_signal.clear()
	_pending_flush_ready = false

# --- NOTIFICATION ---

func _show_nexus_notification(message: String, severity: int = 0) -> void:
	if not get_editor_interface().has_method("get_editor_toaster"):
		return
	var toaster = get_editor_interface().get_editor_toaster()
	if toaster and toaster.has_method("push_toast"):
		toaster.push_toast(message, severity)

## Called from fs_context_menu when user selects "Create Nexus Wrapper/Inherited Scene" on a glTF.
func queue_scene_creation(gltf_path: String, scene_type: String) -> void:
	if gltf_path.is_empty() or scene_type.is_empty():
		return
	if scene_type != SCENE_STYLE_WRAPPER and scene_type != SCENE_STYLE_INHERITED:
		return
	if not FileAccess.file_exists(gltf_path):
		push_warning("Nexus: glTF/GLB not found: %s" % gltf_path)
		return
	_wrapper_queue[gltf_path] = scene_type

## Called from fs_context_menu when user selects "Create Nexus Wrapper/Inherited Scenes (Recursive)" on a folder.
## Recursively finds all Nexus glTFs in folder and subfolders, queues them for scene creation.
func queue_scene_creation_for_folder(folder_path: String, scene_type: String) -> int:
	if folder_path.is_empty() or scene_type.is_empty():
		return 0
	if scene_type != SCENE_STYLE_WRAPPER and scene_type != SCENE_STYLE_INHERITED:
		return 0
	if not DirAccess.dir_exists_absolute(folder_path):
		push_warning("Nexus: Folder not found: %s" % folder_path)
		return 0
	var gltf_paths = _collect_gltfs_recursive(folder_path)
	var queued = 0
	for gltf_path in gltf_paths:
		var meta = NexusUtils.get_nexus_metadata(gltf_path)
		if meta.is_empty():
			continue
		var export_type = meta.get("export_type", "")
		var root_type = meta.get("root_type", "")
		if export_type in ["MULTIMESH_MANIFEST", "ANIMATION_LIB"] or root_type == "NAVMESH":
			continue
		queue_scene_creation(gltf_path, scene_type)
		queued += 1
	if queued > 0:
		print_rich("[color=cyan]Nexus Folder:[/color] Queued %d glTF(s) for %s scene creation." % [queued, scene_type])
	return queued

func _collect_gltfs_recursive(folder_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(folder_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = folder_path.path_join(name)
		if dir.current_is_dir():
			result.append_array(_collect_gltfs_recursive(full))
		elif NexusUtils.is_gltf_container_path(full):
			result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result

func _collect_textures_recursive(folder_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(folder_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = folder_path.path_join(name)
		if dir.current_is_dir():
			result.append_array(_collect_textures_recursive(full))
		else:
			var ext = name.get_extension().to_lower()
			if ext in ["png", "jpg", "jpeg", "webp"]:
				result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result

# --- HELPER UTILS ---

## Returns true if the glTF file is a MultiMesh manifest.
func _is_multimesh(gltf_path: String) -> bool:
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	return meta.get("export_type") == "MULTIMESH_MANIFEST"

# --- LOGIC STEPS ---

func _check_and_fix_import_config(gltf_path: String, do_write: bool = true) -> bool:
	if not FileAccess.file_exists(gltf_path): return false
	
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty(): return false
	
	var import_config_path = gltf_path + ".import"
	var import_config = ConfigFile.new()
	if FileAccess.file_exists(import_config_path):
		var load_err = import_config.load(import_config_path)
		if load_err != OK:
			push_warning("Nexus: Could not load import config for %s: %s" % [gltf_path.get_file(), error_string(load_err)])
	
	var changes_made = false
	
	# A. Inject Import Script
	var target_script = "res://addons/nexus_importer/import_post_processor.gd"
	if import_config.get_value("params", "import_script/path", "") != target_script:
		import_config.set_value("params", "import_script/path", target_script)
		changes_made = true
	
	# B. Root Type
	if "root_type" in meta:
		var desired = _get_root_type_string(meta["root_type"])
		if import_config.get_value("params", "nodes/root_type", "") != desired:
			import_config.set_value("params", "nodes/root_type", desired)
			changes_made = true
	
	# C. Auto-LOD Disable
	if _has_custom_lods(gltf_path):
		if import_config.get_value("params", "meshes/generate_lods", true) == true:
			import_config.set_value("params", "meshes/generate_lods", false)
			changes_made = true
	
	# D. Light Baking
	var light_mode = meta.get("nexus_light_bake_mode", -1)
	if light_mode != -1:
		var desired = 2 if light_mode == 1 else 0
		if import_config.get_value("params", "meshes/light_baking", 0) != desired:
			import_config.set_value("params", "meshes/light_baking", desired)
			changes_made = true
	
	if changes_made:
		if do_write:
			var err = import_config.save(import_config_path)
			if err != OK:
				push_error("Nexus: Failed to save import config for %s: %s" % [gltf_path.get_file(), error_string(err)])
				return false
		return true
	
	return false

func _apply_deferred_config_writes():
	## Write .import files deferred - avoids "Task 'reimport' already exists" when
	## file watcher triggers reimport while Godot's reimport task is still active.
	if _config_deferred_queue.is_empty(): return
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning() or _reimport_in_progress:
		call_deferred("_apply_deferred_config_writes")
		return
	var paths = _config_deferred_queue.duplicate()
	_config_deferred_queue.clear()
	for path in paths:
		if _check_and_fix_import_config(path, true):
			_pending_reimport_after_signal[path] = true
			_pending_flush_ready = false
			print_rich("[color=yellow]Nexus:[/color] Config updated for %s." % path.get_file())
	# Fallback: if resources_reimported never fires again, flush after delay
	if not _pending_reimport_after_signal.is_empty():
		var timer = get_tree().create_timer(FLUSH_FALLBACK_TIMEOUT)
		timer.timeout.connect(_on_flush_fallback_timeout)

func _get_tscn_path_for_gltf(gltf_path: String, scene_style: String) -> String:
	var basename = gltf_path.get_file().get_basename()
	return gltf_path.get_base_dir().path_join(basename + "_" + scene_style + ".tscn")

func _needs_wrapper_processing(gltf_path: String) -> bool:
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty(): return false
	
	var export_type = meta.get("export_type", "")
	var root_type = meta.get("root_type", "")
	if export_type in ["MULTIMESH_MANIFEST", "ANIMATION_LIB"] or root_type == "NAVMESH":
		return false

	var scene_style = ProjectSettings.get_setting(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)
	var tscn_path = _get_tscn_path_for_gltf(gltf_path, scene_style)
	var target_script_path = meta.get("script_path", "")
	
	# Case A: Wrapper missing
	if not FileAccess.file_exists(tscn_path):
		return true
		
	# Case B: Script Update necessary
	if not target_script_path.is_empty():
		return true

	# Case C: Resonance nodes - need wrapper to attach ResonanceGeometry as child of gltf_instance
	if _has_resonance_nodes(gltf_path):
		return true
		
	return false

func _create_or_update_wrapper(gltf_path: String):
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var tscn_path = _get_tscn_path_for_gltf(gltf_path, SCENE_STYLE_WRAPPER)
	var target_script_path = meta.get("script_path", "")
	
	# Load metadata (for Anim Lib path)
	var gltf_resource = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		push_error("Nexus Wrapper: Could not load GLTF: %s" % gltf_path)
		return

	# Briefly instantiate to read generated meta tags (e.g. path to Anim Lib, resonance nodes)
	var temp_instance = gltf_resource.instantiate()
	if not temp_instance:
		push_error("Nexus Wrapper: Could not instantiate GLTF: %s" % gltf_path)
		return
	var anim_lib_path = temp_instance.get_meta("nexus_anim_lib_path", "")
	var resonance_nodes: Array = temp_instance.get_meta("nexus_resonance_nodes", [])
	temp_instance.free()

	var packed_scene = PackedScene.new()
	
	# --- 1. Root Node is ALWAYS Node3D (Container) ---
	var root_node = Node3D.new()
	# Wrapper name = filename
	root_node.name = gltf_path.get_file().get_basename()

	# --- 2. Add GLTF instance ---
	var gltf_instance = gltf_resource.instantiate()
	# IMPORTANT: Instance name must match exactly what AnimationProcessor expects (filename without extension).
	var asset_name = gltf_path.get_file().get_basename()
	gltf_instance.name = asset_name
	
	root_node.add_child(gltf_instance)
	gltf_instance.owner = root_node
	
	# --- 3. ResonanceGeometry (as CHILD of gltf_instance - outside glTF file, editable after placement) ---
	_setup_wrapper_resonance_nodes(gltf_instance, resonance_nodes, false)

	# --- 4. Animation Player (always for SKELETAL_ASSET - prevents "Node not found: AnimationPlayer") ---
	var export_type = meta.get("export_type", "")
	_setup_wrapper_animation_player(root_node, gltf_instance, anim_lib_path, export_type)
	
	# --- 5. Script assignment (on container, not GLTF child) ---
	_assign_wrapper_script(root_node, target_script_path)

	# --- 6. Save ---
	if packed_scene.pack(root_node) == OK:
		var err = ResourceSaver.save(packed_scene, tscn_path)
		if err == OK:
			print_rich("[color=cyan]Nexus Wrapper:[/color] Updated '%s' (Container Mode)." % tscn_path.get_file())
		else:
			push_error("Nexus Wrapper: Failed to save %s: %s" % [tscn_path.get_file(), error_string(err)])
	
	root_node.free()

# --- INHERITED SCENE (Option A: EditorInterface) ---

func _create_inherited_scene_async(gltf_path: String) -> void:
	## Uses EditorInterface.open_scene_from_path(gltf_path, true) to create inherited scene,
	## adds AnimationPlayer/Resonance/Script, then save_scene_as and close_scene.
	var ei = get_editor_interface()
	var tscn_path = _get_tscn_path_for_gltf(gltf_path, SCENE_STYLE_INHERITED)
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var target_script_path = meta.get("script_path", "")
	var export_type = meta.get("export_type", "")

	# Store current scene path to restore after (optional - close_scene leaves editor in clean state)
	var previous_scene_path := ""
	var current_root = ei.get_edited_scene_root()
	if current_root and current_root.scene_file_path:
		previous_scene_path = current_root.scene_file_path

	# Open glTF as inherited scene (set_inherited = true)
	ei.open_scene_from_path(gltf_path, true)

	# Wait for scene to load
	for i in SCENE_LOAD_WAIT_FRAMES:
		await get_tree().process_frame

	var root = ei.get_edited_scene_root()
	if not root:
		push_error("Nexus Inherited: Could not get edited scene root after opening %s" % gltf_path)
		_inherited_creation_in_progress = false
		if _wrapper_queue.is_empty():
			_scan_needed = true
		return

	# Read meta from the loaded scene (set during import)
	var anim_lib_path: String = root.get_meta("nexus_anim_lib_path", "")
	var resonance_nodes: Array = root.get_meta("nexus_resonance_nodes", [])

	# Add nodes: in inherited mode, root IS the glTF - add AnimationPlayer, Resonance, Script as children
	_setup_wrapper_resonance_nodes(root, resonance_nodes, true)
	_setup_wrapper_animation_player(root, root, anim_lib_path, export_type)
	_assign_wrapper_script(root, target_script_path)

	# Save as .tscn (save_scene_as returns void)
	ei.save_scene_as(tscn_path)
	print_rich("[color=cyan]Nexus Inherited:[/color] Created '%s'." % tscn_path.get_file())

	# Close the scene (discards unsaved - we already saved)
	var close_err = ei.close_scene()
	if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
		push_warning("Nexus Inherited: close_scene returned %s" % error_string(close_err))

	# Optionally restore previous scene
	if not previous_scene_path.is_empty() and FileAccess.file_exists(previous_scene_path):
		ei.open_scene_from_path(previous_scene_path, false)

	_inherited_creation_in_progress = false
	if _wrapper_queue.is_empty():
		_scan_needed = true

# --- HELPER ---

func _setup_wrapper_animation_player(root_node: Node3D, gltf_instance: Node, anim_lib_path: String, export_type: String) -> void:
	var is_skeletal = export_type == "SKELETAL_ASSET"
	var needs_anim_player = is_skeletal or (not anim_lib_path.is_empty() and ResourceLoader.exists(anim_lib_path))
	if not needs_anim_player:
		return
	var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
	var anim_player = AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	if nexus_script:
		anim_player.set_script(nexus_script)
	# Add as child of gltf_instance so ".." path resolves to animatable node in both Wrapper and Inherited
	gltf_instance.add_child(anim_player)
	anim_player.owner = root_node

	if anim_lib_path.is_empty() or not ResourceLoader.exists(anim_lib_path):
		return
	var library = ResourceLoader.load(anim_lib_path)
	if not library:
		push_error("Nexus Wrapper: Could not load animation library: %s" % anim_lib_path)
		return
	anim_player.add_animation_library("", library)

	if _has_physics_body_recursive(gltf_instance):
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

	var animation_processor = preload("res://addons/nexus_importer/processors/animation_processor.gd").new()
	animation_processor.apply_scene_retargeting(root_node, anim_player)

	var anim_list = library.get_animation_list()
	if anim_list.size() > 0:
		anim_player.set_meta("nexus_autoplay", anim_list[0])

func _assign_wrapper_script(root_node: Node3D, target_script_path: String) -> void:
	if target_script_path.is_empty() or not ResourceLoader.exists(target_script_path):
		return
	var script = ResourceLoader.load(target_script_path)
	if script is Script:
		root_node.set_script(script)

func _setup_wrapper_resonance_nodes(gltf_instance: Node, resonance_nodes: Array, is_inherited: bool = false) -> void:
	if resonance_nodes.is_empty():
		return
	if not ClassDB.class_exists("ResonanceStaticGeometry"):
		push_warning("Nexus Wrapper: Nexus Resonance addon not active. ResonanceGeometry nodes were skipped.")
		return
	for entry in resonance_nodes:
		if not entry is Dictionary:
			continue
		# All entries use mesh_path (Sidecar); process both discard_mesh true and false.
		var material_path: String = entry.get("material_path", "")
		var shape_type: String = entry.get("type", "RESONANCE_STATIC")
		var discard_mesh = entry.get("discard_mesh", false)
		var base_name = NexusUtils.sanitize_node_name(entry.get("node_name", "Resonance"))
		if base_name.is_empty():
			base_name = "Resonance"

		# New path: mesh_path + transform_str (inherited, mesh saved to sidecar)
		var mesh_path: String = entry.get("mesh_path", "")
		if not mesh_path.is_empty():
			var mesh_ref = ResourceLoader.load(mesh_path)
			if not mesh_ref or not mesh_ref is Mesh:
				push_warning("Nexus Wrapper: Could not load resonance mesh from '%s' - skipped." % mesh_path)
				continue
			# Use .res filename as node name (e.g. SM_Door_reso) - guaranteed valid, no @ or special chars
			var name_from_res = mesh_path.get_file().get_basename()
			base_name = NexusUtils.sanitize_node_name(name_from_res)
			if base_name.is_empty():
				base_name = "Resonance"
			var transform_str: String = entry.get("transform_str", "")
			var resonance_node: Node3D
			if shape_type == "RESONANCE_STATIC":
				resonance_node = ClassDB.instantiate("ResonanceStaticGeometry")
			else:
				resonance_node = ClassDB.instantiate("ResonanceDynamicGeometry")
			if not transform_str.is_empty():
				var t = str_to_var(transform_str)
				if t is Transform3D:
					resonance_node.transform = t
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
			resonance_node.name = base_name if discard_mesh else (base_name + "_Resonance")
			gltf_instance.add_child(resonance_node)
			resonance_node.owner = gltf_instance.owner if gltf_instance.owner else gltf_instance
			continue

		# Legacy path: path_from_root (mesh from MeshInstance3D in scene)
		var path_from_root: String = entry.get("path_from_root", "")
		if path_from_root.is_empty():
			continue
		var mesh_instance = gltf_instance.get_node_or_null(NodePath(path_from_root))
		if not mesh_instance or not mesh_instance is MeshInstance3D or not mesh_instance.mesh:
			push_warning("Nexus Wrapper: Resonance node path '%s' not found or invalid - skipped." % path_from_root)
			continue
		var mesh_ref = mesh_instance.mesh
		var resonance_node: Node3D
		if shape_type == "RESONANCE_STATIC":
			resonance_node = ClassDB.instantiate("ResonanceStaticGeometry")
		else:
			resonance_node = ClassDB.instantiate("ResonanceDynamicGeometry")
		resonance_node.transform = mesh_instance.transform
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
		resonance_node.name = base_name if discard_mesh else (base_name + "_Resonance")
		gltf_instance.add_child(resonance_node)
		resonance_node.owner = gltf_instance.owner if gltf_instance.owner else gltf_instance

func _load_resonance_material(path: String) -> Resource:
	if path.is_empty():
		return _create_default_resonance_material()
	if ResourceLoader.exists(path):
		var res = load(path)
		if res and res.get_class() == "ResonanceMaterial":
			return res
	return _create_default_resonance_material()

func _create_default_resonance_material() -> Resource:
	if not ClassDB.class_exists("ResonanceMaterial"):
		return null
	return ClassDB.instantiate("ResonanceMaterial")

func _collect_resonance_geometry(node: Node, result: Array[Node]) -> void:
	var cls = node.get_class()
	if cls == "ResonanceStaticGeometry" or cls == "ResonanceDynamicGeometry":
		result.append(node)
		return
	for child in node.get_children():
		_collect_resonance_geometry(child, result)

func _has_physics_body_recursive(node: Node) -> bool:
	if node is PhysicsBody3D:
		return true
	for child in node.get_children():
		if _has_physics_body_recursive(child):
			return true
	return false

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

## Returns true if the glTF contains nodes with nexus_mesh_collision_shape RESONANCE_STATIC or RESONANCE_DYNAMIC.
## Resonance nodes require a wrapper so ResonanceGeometry can be attached as siblings of gltf_instance.
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

func _get_root_type_string(nexus_type: String) -> String:
	var map = {
		"NODE_3D": "Node3D", "STATIC": "StaticBody3D", "RIGID": "RigidBody3D",
		"AREA": "Area3D", "CHARACTER_BODY": "CharacterBody3D",
		"NAVMESH": "NavigationRegion3D", "ANIMATABLE": "AnimatableBody3D"
	}
	return map.get(nexus_type, "Node3D")

func _load_asset_index() -> Dictionary:
	var asset_index_path = ProjectSettings.get_setting(SETTING_ASSET_INDEX, "res://asset_index.json")
	if not FileAccess.file_exists(asset_index_path):
		push_error("Nexus: Asset index not found at '%s'." % asset_index_path)
		return {}
	var file = FileAccess.open(asset_index_path, FileAccess.READ)
	if not file:
		push_error("Nexus: Could not open asset index.")
		return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		push_error("Nexus: Asset index is not valid JSON.")
		return {}
	file.close()
	var data = json.get_data()
	if not data is Dictionary:
		push_error("Nexus: Asset index root must be an object.")
		return {}
	return data

func _run_reimport_assets() -> void:
	var asset_index = _load_asset_index()
	if asset_index.is_empty():
		return
	var gltf_paths: Array[String] = []
	var material_paths: Array[String] = []
	var skipped = 0
	
	# Collect glTFs from asset index
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			push_warning("Nexus: Asset '%s' has invalid entry - skipped." % asset_id)
			skipped += 1
			continue
		var rel_path = entry.get("relative_path", "")
		if rel_path.is_empty():
			push_warning("Nexus: Asset '%s' has no relative_path - skipped." % asset_id)
			skipped += 1
			continue
		var gltf_path = NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			push_warning("Nexus: Asset '%s' has invalid path - skipped." % asset_id)
			skipped += 1
			continue
		if not FileAccess.file_exists(gltf_path):
			push_warning("Nexus: Asset '%s' not found at '%s' - skipped." % [asset_id, gltf_path])
			skipped += 1
			continue
		gltf_paths.append(gltf_path)
	
	# Collect materials from material index
	var material_index_path = ProjectSettings.get_setting(SETTING_MATERIAL_INDEX, "res://material_index.json")
	if FileAccess.file_exists(material_index_path):
		var file = FileAccess.open(material_index_path, FileAccess.READ)
		if file:
			var json = JSON.new()
			if json.parse(file.get_as_text()) == OK:
				var mat_data = json.get_data()
				if mat_data is Dictionary:
					for mat_id in mat_data.keys():
						var mat_entry = mat_data[mat_id]
						if mat_entry is Dictionary:
							var rel = mat_entry.get("relative_path", "")
							if not rel.is_empty():
								var p = NexusUtils.validate_index_path(rel)
								if not p.is_empty() and FileAccess.file_exists(p):
									material_paths.append(p)
			file.close()
	
	# Discover textures: scan directories that contain glTFs and materials
	var dirs_to_scan: Dictionary = {}
	for p in gltf_paths:
		dirs_to_scan[p.get_base_dir()] = true
	for p in material_paths:
		dirs_to_scan[p.get_base_dir()] = true
	var texture_paths: Array[String] = []
	for dir_path in dirs_to_scan.keys():
		texture_paths.append_array(_collect_textures_recursive(dir_path))
	
	# Add to phased queues: textures first, then glTFs. Materials (.tres) must NOT be reimported -
	# they are native Godot resources with no importer; reimport_files() would fail with "importer for type ''".
	for p in texture_paths:
		if p not in _texture_paths:
			_texture_paths.append(p)
	for p in gltf_paths:
		if p not in _non_texture_paths:
			_non_texture_paths.append(p)
	if _reimport_phase == 0:
		_reimport_phase = 2 if _texture_paths.is_empty() else 1
	
	var total = texture_paths.size() + material_paths.size() + gltf_paths.size() + skipped
	print_rich("[color=cyan]Nexus Reimport:[/color] Queued %d texture(s), %d glTF/GLB. %d material(s) (no reimport). Skipped %d." % [texture_paths.size(), gltf_paths.size(), material_paths.size(), skipped])
	if total == 0:
		print_rich("[color=yellow]Nexus Reimport:[/color] No assets in index.")

func _run_asset_sanitization() -> void:
	var asset_index = _load_asset_index()
	if asset_index.is_empty():
		return
	var sanitized: Dictionary = {}
	var removed = 0
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			removed += 1
			continue
		var rel_path = entry.get("relative_path", "")
		if rel_path.is_empty():
			removed += 1
			continue
		var gltf_path = NexusUtils.ensure_res_path(rel_path)
		if FileAccess.file_exists(gltf_path):
			sanitized[asset_id] = entry
		else:
			removed += 1
	var asset_index_path = ProjectSettings.get_setting(SETTING_ASSET_INDEX, "res://asset_index.json")
	var file = FileAccess.open(asset_index_path, FileAccess.WRITE)
	if not file:
		push_error("Nexus: Could not write asset index.")
		return
	file.store_string(JSON.stringify(sanitized))
	file.close()
	if removed > 0:
		print_rich("[color=cyan]Nexus Sanitization:[/color] Removed %d orphaned entries from asset_index." % removed)
	else:
		print_rich("[color=green]Nexus Sanitization:[/color] No orphaned entries found.")

func _on_tool_submenu_id_pressed(id: int) -> void:
	match id:
		MENU_ID_IMPORT_MODE:
			_toggle_import_mode()
		MENU_ID_SCENE_STYLE:
			_toggle_scene_style()
		MENU_ID_REIMPORT_ASSETS:
			_run_reimport_assets()
		MENU_ID_ASSET_SANITIZATION:
			_run_asset_sanitization()

func _toggle_import_mode():
	var current = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	ProjectSettings.set_setting(SETTING_AUTO_IMPORT, not current)
	ProjectSettings.save()
	_update_tool_menu_items()

func _toggle_scene_style():
	var current = ProjectSettings.get_setting(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)
	var next_val = SCENE_STYLE_INHERITED if current == SCENE_STYLE_WRAPPER else SCENE_STYLE_WRAPPER
	ProjectSettings.set_setting(SETTING_SCENE_STYLE, next_val)
	ProjectSettings.save()
	_update_tool_menu_items()

func _update_tool_menu_items() -> void:
	if not _tool_submenu:
		return
	_tool_submenu.clear()
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	var scene_style = ProjectSettings.get_setting(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)
	_tool_submenu.add_item("Import Mode (Auto)" if is_auto else "Import Mode (Manual)", MENU_ID_IMPORT_MODE)
	_tool_submenu.set_item_tooltip(-1, "Toggle automatic post-processing. When Auto: config updates and scene creation run on import. When Manual: run tools explicitly.")
	_tool_submenu.add_item("Scene Style (%s)" % (scene_style.capitalize()), MENU_ID_SCENE_STYLE)
	_tool_submenu.set_item_tooltip(-1, "Toggle scene creation style. Wrapper = Node3D container with GLTF instance. Inherited = Scene inherits directly from the GLTF.")
	_tool_submenu.add_separator()
	_tool_submenu.add_item("Reimport Assets", MENU_ID_REIMPORT_ASSETS)
	_tool_submenu.set_item_tooltip(-1, "Read asset_index.json and reimport all glTF/GLB files that exist at their expected paths. Skips missing assets with a warning.")
	_tool_submenu.add_item("Asset Sanitization", MENU_ID_ASSET_SANITIZATION)
	_tool_submenu.set_item_tooltip(-1, "Remove asset_index.json entries whose glTF/GLB files no longer exist. Cleans orphaned index entries.")

func _restore_selection(nodes: Array[Node]):
	var selection = get_editor_interface().get_selection()
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			selection.add_node(node)
