@tool
extends EditorPlugin

## Nexus Importer: Custom glTF importer for the Nexus Blender Export Pipeline.
## Handles auto-reimport, wrapper creation, custom root types, and collision layers.

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()
const RepathingTool = preload("res://addons/nexus_importer/repathing_tool.gd")
const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"
const SETTING_ASSET_INDEX = "nexus/import/asset_index_path"
const SETTING_MATERIAL_INDEX = "nexus/import/material_index_path"

# --- STATUS & QUEUES ---
var _wrapper_queue: Dictionary = {}  # path -> true (Set for O(1) lookup)
var _config_deferred_queue: Array[String] = []
var _reimport_queue: Array[String] = []
var _reimport_pending: bool = false  # async reimport in progress - don't start another
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
	
	_update_tool_menu_item()
	add_tool_menu_item("Nexus: Repathing-Tool", _run_repathing_tool)
	add_tool_menu_item("Nexus: Export Animation Library", _run_export_animation_library)
	print_rich("[color=green]Nexus Importer: Ready.[/color]")

func _exit_tree():
	remove_scene_post_import_plugin(scene_post_processor)
	remove_tool_menu_item("Nexus: Import Mode (Auto)")
	remove_tool_menu_item("Nexus: Import Mode (Manual)")
	remove_tool_menu_item("Nexus: Repathing-Tool")
	remove_tool_menu_item("Nexus: Export Animation Library")
	
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.disconnect(_on_resources_reimported)

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
	if not _wrapper_queue.is_empty():
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
	# Await 4 frames - ensures we're NOT in signal/deferred context (forum #123523, GitHub #100900)
	# progress_dialog fails when called during message queue flush
	for i in 4:
		await get_tree().process_frame
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
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

func _on_resources_reimported(resources: PackedStringArray):
	var is_auto_mode = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	if not is_auto_mode: return

	var activity_detected = false
	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext == "gltf":
			# 1. Config Check - defer .import write to avoid "Task 'reimport' already exists"
			if _check_and_fix_import_config(path, false):
				if not path in _config_deferred_queue:
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

	if activity_detected:
		_cooldown_timer = SAFETY_FRAMES

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
		import_config.load(import_config_path)
	
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
			import_config.save(import_config_path)
		return true
	
	return false

func _apply_deferred_config_writes():
	## Write .import files deferred - avoids "Task 'reimport' already exists" when
	## file watcher triggers reimport while Godot's reimport task is still active.
	if _config_deferred_queue.is_empty(): return
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		call_deferred("_apply_deferred_config_writes")
		return
	var paths = _config_deferred_queue.duplicate()
	_config_deferred_queue.clear()
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	for path in paths:
		_check_and_fix_import_config(path, true)
		if is_auto and not path in _reimport_queue:
			_reimport_queue.append(path)
		print_rich("[color=yellow]Nexus:[/color] Config updated for %s." % path.get_file())

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
	var is_skeletal = export_type == "SKELETAL_ASSET"
	var needs_anim_player = is_skeletal or (not anim_lib_path.is_empty() and ResourceLoader.exists(anim_lib_path))
	if needs_anim_player:
		var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
		var anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		if nexus_script:
			anim_player.set_script(nexus_script)
		root_node.add_child(anim_player)
		anim_player.owner = root_node
		
		if not anim_lib_path.is_empty() and ResourceLoader.exists(anim_lib_path):
			var library = ResourceLoader.load(anim_lib_path)
			anim_player.add_animation_library("", library)
			
			# PhysicsBody: Callback mode for correct physics sync (including PhysicsBody in children)
			if _has_physics_body_recursive(gltf_instance):
				anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
			
			# Retargeting and Autoplay
			var animation_processor = preload("res://addons/nexus_importer/processors/animation_processor.gd").new()
			animation_processor.apply_scene_retargeting(root_node, anim_player)
			
			var anim_list = library.get_animation_list()
			if anim_list.size() > 0:
				anim_player.autoplay = anim_list[0]
				anim_player.current_animation = anim_list[0]
	
	# --- 4. Script assignment ---
	# Script goes on the container (Node3D), not on the GLTF child!
	if not target_script_path.is_empty() and ResourceLoader.exists(target_script_path):
		var script = ResourceLoader.load(target_script_path)
		if script is Script:
			root_node.set_script(script)

	# --- 5. Save ---
	if packed_scene.pack(root_node) == OK:
		ResourceSaver.save(packed_scene, tscn_path)
		print_rich("[color=cyan]Nexus Wrapper:[/color] Updated '%s' (Container Mode)." % tscn_path.get_file())
	
	root_node.free()

# --- HELPER ---

func _has_physics_body_recursive(node: Node) -> bool:
	if node is PhysicsBody3D:
		return true
	for child in node.get_children():
		if _has_physics_body_recursive(child):
			return true
	return false

func _has_custom_lods(gltf_path: String) -> bool:
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return false
	var txt = file.get_as_text()
	return "nexus_is_lod" in txt

func _get_root_type_string(nexus_type: String) -> String:
	var map = {
		"NODE_3D": "Node3D", "STATIC": "StaticBody3D", "RIGID": "RigidBody3D",
		"AREA": "Area3D", "CHARACTER_BODY": "CharacterBody3D", 
		"NAVMESH": "NavigationRegion3D", "ANIMATABLE": "AnimatableBody3D"
	}
	return map.get(nexus_type, "Node3D")

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

func _toggle_import_mode():
	var current = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	ProjectSettings.set_setting(SETTING_AUTO_IMPORT, not current)
	ProjectSettings.save()
	_update_tool_menu_item()

func _update_tool_menu_item():
	remove_tool_menu_item("Nexus: Import Mode (Auto)")
	remove_tool_menu_item("Nexus: Import Mode (Manual)")
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	add_tool_menu_item("Nexus: Import Mode (Auto)" if is_auto else "Nexus: Import Mode (Manual)", _toggle_import_mode)

func _restore_selection(nodes: Array[Node]):
	var selection = get_editor_interface().get_selection()
	for node in nodes:
		if is_instance_valid(node):
			selection.add_node(node)
