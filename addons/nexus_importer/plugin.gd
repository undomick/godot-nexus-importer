@tool
extends EditorPlugin

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()
const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"

# --- STATUS & QUEUES ---
var _reimport_queue: Array[String] = [] 
var _wrapper_queue: Array[String] = []  
var _scan_needed: bool = false               

# --- DEBOUNCING TIMER ---
var _cooldown_timer: int = 0
const SAFETY_FRAMES = 60

func _enter_tree():
	add_scene_post_import_plugin(scene_post_processor)
	var fs = get_editor_interface().get_resource_filesystem()
	if not fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.connect(_on_resources_reimported)
	
	if not ProjectSettings.has_setting(SETTING_AUTO_IMPORT):
		ProjectSettings.set_setting(SETTING_AUTO_IMPORT, true)
		ProjectSettings.set_initial_value(SETTING_AUTO_IMPORT, true)
		ProjectSettings.save()
	
	_update_tool_menu_item()
	print_rich("[color=green]Nexus Importer: Ready.[/color]")

func _exit_tree():
	remove_scene_post_import_plugin(scene_post_processor)
	remove_tool_menu_item("Nexus: Import Mode (Auto)")
	remove_tool_menu_item("Nexus: Import Mode (Manual)")
	
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

	# PRIORITY A: Reimports
	if not _reimport_queue.is_empty():
		var unique_files = _deduplicate_array(_reimport_queue)
		_reimport_queue.clear()
		
		# --- SELECTION HANDLING ---
		var selection = get_editor_interface().get_selection()
		var selected_nodes = selection.get_selected_nodes()
		var nodes_to_reselect = []
		
		for node in selected_nodes:
			# Check if the node belongs to the file we are reimporting
			if node.scene_file_path in unique_files:
				selection.remove_node(node)
				nodes_to_reselect.append(node)
		
		# Execute reimport (while nothing is selected)
		fs.reimport_files(unique_files)
		
		# Restore selection (as soon as possible)
		if not nodes_to_reselect.is_empty():
			call_deferred("_restore_selection", nodes_to_reselect)
		
		_cooldown_timer = SAFETY_FRAMES
		return

	# PRIORITY B: Wrapper Creation
	if not _wrapper_queue.is_empty():
		var file_to_wrap = _wrapper_queue.pop_front()
		_create_or_update_wrapper(file_to_wrap)
		
		if _wrapper_queue.is_empty():
			_scan_needed = true
		return

	# PRIORITY C: Final Scan
	if _scan_needed:
		_scan_needed = false
		fs.scan()

# --- EVENT HANDLER (DEBOUNCER) ---

func _on_resources_reimported(resources: PackedStringArray):
	var is_auto_mode = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	if not is_auto_mode: return

	var activity_detected = false
	for path in resources:
		var ext = path.get_extension().to_lower()
		if ext == "gltf":
			# 1. Config Check
			if _check_and_fix_import_config(path):
				if not path in _reimport_queue:
					_reimport_queue.append(path)
				activity_detected = true
			
			else:
				# 2. Wrapper Check
				if _needs_wrapper_processing(path):
					if not path in _wrapper_queue:
						_wrapper_queue.append(path)
					activity_detected = true
				
				# 3. MULTIMESH CHECK
				elif _is_multimesh(path):
					_scan_needed = true
					activity_detected = true

		elif ext in ["tres", "png", "jpg"]:
			activity_detected = true

	if activity_detected:
		_cooldown_timer = SAFETY_FRAMES

# --- HELPER UTILS ---

func _is_multimesh(gltf_path: String) -> bool:
	# Fresh read of metadata
	var meta = _get_nexus_metadata(gltf_path)
	return meta.get("export_type") == "MULTIMESH_MANIFEST"

func _deduplicate_array(arr: Array) -> Array:
	var unique = []
	for item in arr:
		if not item in unique: unique.append(item)
	return unique

# --- LOGIC STEPS ---

func _check_and_fix_import_config(gltf_path: String) -> bool:
	if not FileAccess.file_exists(gltf_path): return false
	
	var meta = _get_nexus_metadata(gltf_path)
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
		import_config.save(import_config_path)
		get_editor_interface().get_resource_filesystem().update_file(import_config_path)
		return true
	
	return false

func _needs_wrapper_processing(gltf_path: String) -> bool:
	var meta = _get_nexus_metadata(gltf_path)
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
	var meta = _get_nexus_metadata(gltf_path)
	var tscn_path = gltf_path.get_base_dir().path_join(gltf_path.get_file().get_basename() + ".tscn")
	var target_script_path = meta.get("script_path", "")
	
	# 1. NEW CREATION
	if not FileAccess.file_exists(tscn_path):
		var gltf_resource = ResourceLoader.load(gltf_path)
		if not gltf_resource: return
		var packed_scene = PackedScene.new()
		var root_node = Node3D.new()
		root_node.name = gltf_path.get_file().get_basename()
		var gltf_instance = gltf_resource.instantiate()
		root_node.add_child(gltf_instance)
		gltf_instance.owner = root_node
		if not target_script_path.is_empty() and ResourceLoader.exists(target_script_path):
			var script = ResourceLoader.load(target_script_path)
			if script is Script:
				gltf_instance.set_script(script)
		if packed_scene.pack(root_node) == OK:
			ResourceSaver.save(packed_scene, tscn_path)
			print_rich("[color=cyan]Nexus Wrapper:[/color] Created '%s'." % tscn_path.get_file())
		root_node.free()
		
	# 2. UPDATE EXISTING
	else:
		if target_script_path.is_empty(): return
		var packed_scene = ResourceLoader.load(tscn_path)
		if not packed_scene is PackedScene: return
		var root = packed_scene.instantiate()
		var gltf_instance = null
		for child in root.get_children():
			if child.scene_file_path == gltf_path:
				gltf_instance = child
				break
		var needs_save = false
		if gltf_instance:
			var current_script = gltf_instance.get_script()
			var new_script = ResourceLoader.load(target_script_path)
			if current_script != new_script and new_script is Script:
				gltf_instance.set_script(new_script)
				needs_save = true
		if needs_save:
			if packed_scene.pack(root) == OK:
				ResourceSaver.save(packed_scene, tscn_path)
				print_rich("[color=cyan]Nexus Wrapper:[/color] Updated script on '%s'." % tscn_path.get_file())
		root.free()

# --- HELPER ---

func _get_nexus_metadata(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path): return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return {}
	var gltf_data = json.get_data()
	
	var meta = gltf_data.get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	if meta.is_empty():
		meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	return meta

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

func _restore_selection(nodes: Array):
	var selection = get_editor_interface().get_selection()
	for node in nodes:
		if is_instance_valid(node):
			selection.add_node(node)
