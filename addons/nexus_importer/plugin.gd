@tool
extends EditorPlugin

## Nexus Importer: Custom glTF importer for the Nexus Blender Export Pipeline.
## Handles auto-reimport, wrapper creation, custom root types, and collision layers.

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()
const RepathingTool = preload("res://addons/nexus_importer/repathing_tool.gd")
const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"
const SETTING_ASSET_INDEX = "nexus/import/asset_index_path"
const SETTING_MATERIAL_INDEX = "nexus/import/material_index_path"

const MENU_ID_IMPORT_MODE = 0
const MENU_ID_REPATHING = 1
const MENU_ID_EXPORT_ANIM_LIB = 2
const MENU_ID_REIMPORT_ASSETS = 3
const MENU_ID_ASSET_SANITIZATION = 4

var _tool_submenu: PopupMenu

# --- STATUS & QUEUES ---
var _wrapper_queue: Dictionary = {}  # path -> true (Set for O(1) lookup)
var _config_deferred_queue: Array[String] = []
var _reimport_queue: Array[String] = []
var _reimport_pending: bool = false  # async reimport in progress - don't start another
var _pending_reimport_after_signal: Dictionary = {}  # path -> true: config written, wait for resources_reimported
var _pending_flush_ready: bool = false  # true after first resources_reimported since add; allows flush on second
var _reimport_in_progress: bool = false  # true between resources_reimporting and resources_reimported
var _scan_needed: bool = false

# --- DEBOUNCING ---
var _cooldown_timer: int = 0
const SAFETY_FRAMES = 60

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
	if needs_save:
		ProjectSettings.save()
	
	_tool_submenu = PopupMenu.new()
	_tool_submenu.id_pressed.connect(_on_tool_submenu_id_pressed)
	add_tool_submenu_item("Nexus Importer", _tool_submenu)
	_update_tool_menu_items()
	print_rich("[color=green]Nexus Importer: Ready.[/color]")

func _exit_tree():
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

	# PRIORITY A: Auto Reimport (async - await process_frame to avoid progress_dialog errors)
	if ProjectSettings.get_setting(SETTING_AUTO_IMPORT) and not _reimport_queue.is_empty() and not _reimport_pending:
		var file_to_reimport = _reimport_queue.pop_front()
		_reimport_pending = true
		_reimport_safe_async(file_to_reimport)
		return

	# PRIORITY B: Wrapper Creation (one file per frame for editor responsiveness)
	# Block during reimport - ResourceSaver.save can trigger recursive reimport_files
	if not _wrapper_queue.is_empty() and not _reimport_pending and not _reimport_in_progress:
		var file_to_wrap = _wrapper_queue.keys()[0]
		_wrapper_queue.erase(file_to_wrap)
		_create_or_update_wrapper(file_to_wrap)
		if _wrapper_queue.is_empty():
			_scan_needed = true
		return

	# PRIORITY C: Final Scan
	if _scan_needed:
		_scan_needed = false
		fs.scan()

# --- ASYNC REIMPORT (avoid progress_dialog errors - see forum.godotengine.org/t/123523) ---

func _reimport_safe_async(file_path: String):
	# Minimal delay to escape signal/deferred context (forum #123523).
	# Reimport is now only queued AFTER resources_reimported fires (signal-based safety).
	const REIMPORT_DELAY = 4
	for i in REIMPORT_DELAY:
		await get_tree().process_frame
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_reimport_queue.push_front(file_path)
		_reimport_pending = false
		return
	if _reimport_in_progress:
		_reimport_queue.push_front(file_path)
		_reimport_pending = false
		return
	var selection = get_editor_interface().get_selection()
	var nodes_to_reselect = []
	for node in selection.get_selected_nodes():
		if node.scene_file_path == file_path:
			selection.remove_node(node)
			nodes_to_reselect.append(node)
	fs.reimport_files(PackedStringArray([file_path]))
	if not nodes_to_reselect.is_empty():
		call_deferred("_restore_selection", nodes_to_reselect)
	_cooldown_timer = SAFETY_FRAMES
	_reimport_pending = false

# --- EVENT HANDLER ---

func _on_resources_reimporting(_resources: PackedStringArray):
	_reimport_in_progress = true

func _on_resources_reimported(resources: PackedStringArray):
	_reimport_in_progress = false

	var is_auto_mode = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	if not is_auto_mode: return

	var activity_detected = false
	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext == "gltf":
			# 1. Config Check - defer .import write to avoid "Task 'reimport' already exists"
			if _check_and_fix_import_config(path, false):
				if path not in _config_deferred_queue:
					_config_deferred_queue.append(path)
				call_deferred("_apply_deferred_config_writes")
				activity_detected = true
			else:
				# 2. Wrapper Check
				if _needs_wrapper_processing(path):
					if not _wrapper_queue.has(path):
						_wrapper_queue[path] = true
					activity_detected = true
				elif _is_multimesh(path):
					_scan_needed = true
					activity_detected = true

		elif ext in ["tres", "png", "jpg"]:
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
	## (glTF still reimporting). On second cycle, paths still in _pending get queued for our reimport.
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
	# Second cycle: flush remaining to _reimport_queue
	for path in _pending_reimport_after_signal.keys():
		if path not in _reimport_queue:
			_reimport_queue.append(path)
	_pending_reimport_after_signal.clear()
	_pending_flush_ready = false

func _on_flush_fallback_timeout():
	## Fallback when resources_reimported does not fire again after config write.
	## Ensures reimport is triggered even if Godot skips the signal.
	if _pending_reimport_after_signal.is_empty(): return
	for path in _pending_reimport_after_signal.keys():
		if path not in _reimport_queue:
			_reimport_queue.append(path)
	_pending_reimport_after_signal.clear()
	_pending_flush_ready = false

# --- NOTIFICATION ---

func _show_nexus_notification(message: String, severity: int = 0) -> void:
	if not get_editor_interface().has_method("get_editor_toaster"):
		return
	var toaster = get_editor_interface().get_editor_toaster()
	if toaster and toaster.has_method("push_toast"):
		toaster.push_toast(message, severity)

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
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	for path in paths:
		if _check_and_fix_import_config(path, true):
			if is_auto:
				_pending_reimport_after_signal[path] = true
				_pending_flush_ready = false
			print_rich("[color=yellow]Nexus:[/color] Config updated for %s." % path.get_file())
	# Fallback: if resources_reimported never fires again, flush after delay
	if is_auto and not _pending_reimport_after_signal.is_empty():
		var timer = get_tree().create_timer(2.5)
		timer.timeout.connect(_on_flush_fallback_timeout)

func _needs_wrapper_processing(gltf_path: String) -> bool:
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty(): return false
	
	var export_type = meta.get("export_type", "")
	var root_type = meta.get("root_type", "")
	if export_type in ["MULTIMESH_MANIFEST", "ANIMATION_LIB"] or root_type == "NAVMESH":
		return false

	var tscn_path = gltf_path.get_base_dir().path_join(gltf_path.get_file().get_basename() + ".tscn")
	var target_script_path = meta.get("script_path", "")
	
	# Case A: Wrapper missing
	if not FileAccess.file_exists(tscn_path):
		return true
		
	# Case B: Script Update necessary
	if not target_script_path.is_empty():
		return true
		
	return false

func _create_or_update_wrapper(gltf_path: String):
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var tscn_path = gltf_path.get_base_dir().path_join(gltf_path.get_file().get_basename() + ".tscn")
	var target_script_path = meta.get("script_path", "")
	
	# Load metadata (for Anim Lib path)
	var gltf_resource = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		push_error("Nexus Wrapper: Could not load GLTF: %s" % gltf_path)
		return

	# Briefly instantiate to read generated meta tags (e.g. path to Anim Lib)
	var temp_instance = gltf_resource.instantiate()
	if not temp_instance:
		push_error("Nexus Wrapper: Could not instantiate GLTF: %s" % gltf_path)
		return
	var anim_lib_path = temp_instance.get_meta("nexus_anim_lib_path", "")
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
	
	# --- 3. Animation Player (always for SKELETAL_ASSET - prevents "Node not found: AnimationPlayer") ---
	var export_type = meta.get("export_type", "")
	_setup_wrapper_animation_player(root_node, gltf_instance, anim_lib_path, export_type)
	
	# --- 4. Script assignment (on container, not GLTF child) ---
	_assign_wrapper_script(root_node, target_script_path)

	# --- 5. Save ---
	if packed_scene.pack(root_node) == OK:
		var err = ResourceSaver.save(packed_scene, tscn_path)
		if err == OK:
			print_rich("[color=cyan]Nexus Wrapper:[/color] Updated '%s' (Container Mode)." % tscn_path.get_file())
		else:
			push_error("Nexus Wrapper: Failed to save %s: %s" % [tscn_path.get_file(), error_string(err)])
	
	root_node.free()

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
	root_node.add_child(anim_player)
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
		anim_player.autoplay = anim_list[0]
		anim_player.current_animation = anim_list[0]

func _assign_wrapper_script(root_node: Node3D, target_script_path: String) -> void:
	if target_script_path.is_empty() or not ResourceLoader.exists(target_script_path):
		return
	var script = ResourceLoader.load(target_script_path)
	if script is Script:
		root_node.set_script(script)

func _has_physics_body_recursive(node: Node) -> bool:
	if node is PhysicsBody3D:
		return true
	for child in node.get_children():
		if _has_physics_body_recursive(child):
			return true
	return false

func _has_custom_lods(gltf_path: String) -> bool:
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file:
		return false
	const SEARCH = "nexus_is_lod"
	while file.get_position() < file.get_length():
		var line = file.get_line()
		if SEARCH in line:
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
	var paths_to_reimport: Array[String] = []
	var skipped = 0
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
		paths_to_reimport.append(gltf_path)
	for path in paths_to_reimport:
		if path not in _reimport_queue:
			_reimport_queue.append(path)
	var total = paths_to_reimport.size() + skipped
	print_rich("[color=cyan]Nexus Reimport:[/color] Queued %d asset(s) for reimport. Skipped %d." % [paths_to_reimport.size(), skipped])
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

func _run_repathing_tool():
	var result = RepathingTool.run(get_editor_interface())
	var ok = result.get("ok", false)
	var msg = result.get("message", "")
	var color = "green" if ok else "yellow"
	print_rich("[color=%s]Nexus Repathing:[/color] %s" % [color, msg])
	if not ok:
		push_warning(msg)

func _run_export_animation_library():
	var result = RepathingTool.export_animation_library(get_editor_interface())
	var ok = result.get("ok", false)
	var msg = result.get("message", "")
	var color = "green" if ok else "yellow"
	print_rich("[color=%s]Nexus Export:[/color] %s" % [color, msg])
	if not ok:
		push_warning(msg)

func _on_tool_submenu_id_pressed(id: int) -> void:
	match id:
		MENU_ID_IMPORT_MODE:
			_toggle_import_mode()
		MENU_ID_REPATHING:
			_run_repathing_tool()
		MENU_ID_EXPORT_ANIM_LIB:
			_run_export_animation_library()
		MENU_ID_REIMPORT_ASSETS:
			_run_reimport_assets()
		MENU_ID_ASSET_SANITIZATION:
			_run_asset_sanitization()

func _toggle_import_mode():
	var current = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	ProjectSettings.set_setting(SETTING_AUTO_IMPORT, not current)
	ProjectSettings.save()
	_update_tool_menu_items()

func _update_tool_menu_items() -> void:
	if not _tool_submenu:
		return
	_tool_submenu.clear()
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	_tool_submenu.add_item("Import Mode (Auto)" if is_auto else "Import Mode (Manual)", MENU_ID_IMPORT_MODE)
	_tool_submenu.set_item_tooltip(-1, "Toggle automatic post-processing. When Auto: config updates and wrapper creation run on import. When Manual: run tools explicitly.")
	_tool_submenu.add_separator()
	_tool_submenu.add_item("Repathing Tool", MENU_ID_REPATHING)
	_tool_submenu.set_item_tooltip(-1, "Fix animation track paths after using 'Make Scene Root'. Removes the old root name prefix from all tracks in the open scene.")
	_tool_submenu.add_item("Export Animation Library", MENU_ID_EXPORT_ANIM_LIB)
	_tool_submenu.set_item_tooltip(-1, "Export the first AnimationPlayer's library to a .tres file next to the current scene. Useful after repathing.")
	_tool_submenu.add_item("Reimport Assets", MENU_ID_REIMPORT_ASSETS)
	_tool_submenu.set_item_tooltip(-1, "Read asset_index.json and reimport all glTFs that exist at their expected paths. Skips missing assets with a warning.")
	_tool_submenu.add_item("Asset Sanitization", MENU_ID_ASSET_SANITIZATION)
	_tool_submenu.set_item_tooltip(-1, "Remove asset_index.json entries whose glTF files no longer exist. Cleans orphaned index entries.")

func _restore_selection(nodes: Array[Node]):
	var selection = get_editor_interface().get_selection()
	for node in nodes:
		if is_instance_valid(node):
			selection.add_node(node)
