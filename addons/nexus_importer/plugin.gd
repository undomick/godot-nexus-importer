@tool
extends EditorPlugin

# The core processor logic
var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()

# State tracking
var _files_needing_reimport: PackedStringArray = []
const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"

func _enter_tree():
	add_scene_post_import_plugin(scene_post_processor)
	
	var fs = get_editor_interface().get_resource_filesystem()
	if not fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.connect(_on_resources_reimporting)
	if not fs.sources_changed.is_connected(_on_sources_changed):
		fs.sources_changed.connect(_on_sources_changed)
	if not fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.connect(_on_resources_reimported)
	
	if not ProjectSettings.has_setting(SETTING_AUTO_IMPORT):
		ProjectSettings.set_setting(SETTING_AUTO_IMPORT, true)
		ProjectSettings.set_initial_value(SETTING_AUTO_IMPORT, true)
		ProjectSettings.save()
	
	_update_tool_menu_item()
	print("Nexus Importer Plugin: Watcher started.")

func _exit_tree():
	remove_scene_post_import_plugin(scene_post_processor)
	remove_tool_menu_item("Nexus: Import Mode")
	
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.disconnect(_on_resources_reimporting)
	if fs.sources_changed.is_connected(_on_sources_changed):
		fs.sources_changed.disconnect(_on_sources_changed)
	if fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.disconnect(_on_resources_reimported)
	
	print("Nexus Importer Plugin: Watcher stopped.")

# --- MENU / TOGGLE LOGIC ---

func _toggle_import_mode():
	var current_mode = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	ProjectSettings.set_setting(SETTING_AUTO_IMPORT, not current_mode)
	ProjectSettings.save()
	_update_tool_menu_item()

func _update_tool_menu_item():
	remove_tool_menu_item("Nexus: Import Mode (Auto)")
	remove_tool_menu_item("Nexus: Import Mode (Manual)")
	
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	var label = "Nexus: Import Mode (Auto)" if is_auto else "Nexus: Import Mode (Manual)"
	
	add_tool_menu_item(label, _toggle_import_mode)

# --- WATCHDOG LOGIC ---

func _on_resources_reimporting(paths: PackedStringArray):
	var is_auto_mode = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	
	# Determine if we should process based on Mode OR Selection (User Action)
	var selected_paths = get_editor_interface().get_selected_paths()
	
	for path in paths:
		if path.get_extension() == "gltf":
			var process_this_file = is_auto_mode
			
			# MANUAL MODE OVERRIDE:
			# If the file is currently selected in the FileSystem dock, we assume
			# the user triggered this reimport manually (e.g. by clicking "Reimport").
			# New files dragged from OS are usually NOT selected yet during first import.
			if not process_this_file:
				if path in selected_paths:
					process_this_file = true
			
			if process_this_file:
				if _prepare_import_config(path):
					if not path in _files_needing_reimport:
						_files_needing_reimport.append(path)

func _on_sources_changed(exist: bool):
	if not _files_needing_reimport.is_empty():
		print("Nexus Watchdog: Triggering re-import for %d modified files..." % _files_needing_reimport.size())
		var files_to_process = _files_needing_reimport.duplicate()
		_files_needing_reimport.clear()
		get_editor_interface().get_resource_filesystem().reimport_files(files_to_process)

func _on_resources_reimported(resources: PackedStringArray):
	var current_root = get_editor_interface().get_edited_scene_root()
	var current_scene_path = current_root.scene_file_path if current_root else ""
	var needs_scene_reload = false
	
	for res_path in resources:
		var ext = res_path.get_extension()
		
		# 1. GLTF REIMPORTED
		if ext == "gltf":
			_try_create_wrapper_scene(res_path)
			
			var expected_tscn_path = res_path.get_base_dir().path_join(res_path.get_file().get_basename() + ".tscn")
			if expected_tscn_path == current_scene_path:
				needs_scene_reload = true
		
		# 2. MATERIAL HOT RELOAD
		elif ext == "tres":
			if ResourceLoader.has_cached(res_path):
				var res = ResourceLoader.load(res_path)
				res.emit_changed()

	if needs_scene_reload:
		print("Nexus Plugin: Source GLTF changed. Reloading active scene '%s'..." % current_scene_path.get_file())
		get_editor_interface().reload_scene_from_path(current_scene_path)

# --- WRAPPER CREATION LOGIC ---

func _try_create_wrapper_scene(gltf_path: String):
	var tscn_path = gltf_path.get_base_dir().path_join(gltf_path.get_file().get_basename() + ".tscn")
	if FileAccess.file_exists(tscn_path):
		return

	# CHECK: Does this file use the Nexus Processor?
	var import_config_path = gltf_path + ".import"
	if not FileAccess.file_exists(import_config_path): return
	
	var import_config = ConfigFile.new()
	import_config.load(import_config_path)
	var current_script = import_config.get_value("params", "import_script/path", "")
	
	if current_script != "res://addons/nexus_importer/import_post_processor.gd":
		return

	# Read Metadata
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return
	var gltf_data = json.get_data()
	var meta = _extract_nexus_metadata(gltf_data)
	if meta.is_empty(): return
	
	var export_type = meta.get("export_type", "")
	var root_type = meta.get("root_type", "")
	
	# Skip AnimationLib (Pure Data)
	# FIX: Removed 'MULTIMESH_MANIFEST' from exclusion list. We WANT a TSCN for it.
	if export_type == "ANIMATION_LIB":
		return
	
	if root_type == "NAVMESH":
		print("Nexus Info: Asset '%s' is a Navigation Region. Skipping auto-TSCN creation." % gltf_path.get_file())
		print(" -> Tip: Drag the .gltf file directly into your level scene to use the NavMesh.")
		return

	# Create Wrapper
	var gltf_resource = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		push_warning("Nexus Watchdog: Failed to load imported GLTF '%s'" % gltf_path)
		return
		
	print("Nexus Watchdog: Creating wrapper scene for processed asset '%s'..." % gltf_path.get_file())
	
	var packed_scene = PackedScene.new()
	var root_node = Node3D.new()
	root_node.name = gltf_path.get_file().get_basename()
	
	var gltf_instance = gltf_resource.instantiate()
	root_node.add_child(gltf_instance)
	gltf_instance.owner = root_node
	
	if packed_scene.pack(root_node) == OK:
		ResourceSaver.save(packed_scene, tscn_path)
		print(" -> Created '%s'" % tscn_path)
	
	root_node.free()

# --- CONFIG INJECTION LOGIC ---

func _prepare_import_config(gltf_path: String) -> bool:
	if not FileAccess.file_exists(gltf_path): return false
	
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return false
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return false
	var gltf_data = json.get_data()

	var scene_meta = _extract_nexus_metadata(gltf_data)
	if scene_meta.is_empty(): return false

	var import_config_path = gltf_path + ".import"
	var import_config = ConfigFile.new()
	
	if FileAccess.file_exists(import_config_path):
		import_config.load(import_config_path)
	
	var changes_made = false

	# 1. INJECT SCRIPT
	var current_script = import_config.get_value("params", "import_script/path", "")
	var target_script = "res://addons/nexus_importer/import_post_processor.gd"
	
	if current_script != target_script:
		import_config.set_value("params", "import_script/path", target_script)
		changes_made = true
		print("Nexus Watchdog: Auto-assigned processor to '%s'" % gltf_path.get_file())
	
	# 2. INJECT ROOT TYPE
	if "root_type" in scene_meta:
		var desired_type = _get_root_type_string(scene_meta["root_type"])
		var current_type = import_config.get_value("params", "nodes/root_type", "")
		if current_type != desired_type:
			import_config.set_value("params", "nodes/root_type", desired_type)
			changes_made = true

	# 3. DISABLE AUTO-LOD
	if _has_custom_lods(gltf_data):
		var current_gen_lods = import_config.get_value("params", "meshes/generate_lods", true)
		if current_gen_lods == true:
			import_config.set_value("params", "meshes/generate_lods", false)
			changes_made = true
			print("Nexus Watchdog: Detected custom LODs in '%s'. Disabled auto-LOD generation." % gltf_path.get_file())
	
	# 4. CONFIGURE LIGHT BAKING
	# Check metadata for our calculated mode
	var light_mode = scene_meta.get("nexus_light_bake_mode", -1)
	
	if light_mode != -1:
		# Godot Import Settings for 'meshes/light_baking':
		# 0 = Disabled
		# 1 = Static (VoxelGI only)
		# 2 = Static Lightmaps (Generates UV2)
		
		# If Blender said "Static" (1), we force Godot Mode 2 (Static Lightmaps) 
		# because that covers everything (Lightmaps + VoxelGI).
		var desired_godot_import_value = 2 if light_mode == 1 else 0
		
		var current_val = import_config.get_value("params", "meshes/light_baking", 0)
		
		if current_val != desired_godot_import_value:
			import_config.set_value("params", "meshes/light_baking", desired_godot_import_value)
			changes_made = true
			var mode_str = "Static Lightmaps" if desired_godot_import_value == 2 else "Dynamic/Disabled"
			print("Nexus Watchdog: Auto-configured Light Baking to '%s' for '%s'." % [mode_str, gltf_path.get_file()])
	
	if changes_made:
		import_config.save(import_config_path)
		
	return changes_made

# --- Helper Functions ---

func _extract_nexus_metadata(gltf_data: Dictionary) -> Dictionary:
	# 1. Root
	var meta = gltf_data.get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 2. Scene
	if meta.is_empty():
		meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 3. Asset (Optimizer)
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
		
	return meta

func _has_custom_lods(gltf_data: Dictionary) -> bool:
	if not "nodes" in gltf_data: return false
	for node in gltf_data["nodes"]:
		var node_extras = node.get("extras", {})
		if "NEXUS_NODE_METADATA" in node_extras:
			if node_extras["NEXUS_NODE_METADATA"].get("nexus_is_lod", false):
				return true
	return false

func _get_root_type_string(nexus_type: String) -> String:
	var map = {
		"NODE_3D": "Node3D", 
		"STATIC": "StaticBody3D", 
		"RIGID": "RigidBody3D",
		"AREA": "Area3D", 
		"CHARACTER_BODY": "CharacterBody3D", 
		"NAVMESH": "NavigationRegion3D",
		"ANIMATABLE": "AnimatableBody3D"
	}
	return map.get(nexus_type, "Node3D")
