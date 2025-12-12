@tool
extends EditorPlugin

# The core processor logic
var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()

# State tracking
var reimport_flag: bool = false
const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"

func _enter_tree():
	# 1. Register the Post-Import Plugin (The logic that runs during import)
	add_scene_post_import_plugin(scene_post_processor)
	
	# 2. Setup the Watchdog (File System Signals)
	var fs = get_editor_interface().get_resource_filesystem()
	fs.resources_reimporting.connect(_on_resources_reimporting)
	fs.sources_changed.connect(_on_sources_changed)
	fs.resources_reimported.connect(_on_resources_reimported)
	
	# 3. Setup Project Setting for the Toggle
	if not ProjectSettings.has_setting(SETTING_AUTO_IMPORT):
		ProjectSettings.set_setting(SETTING_AUTO_IMPORT, true)
		ProjectSettings.set_initial_value(SETTING_AUTO_IMPORT, true)
		ProjectSettings.save()
	
	# 4. Add Menu Item (Project > Tools)
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
	# One of them will exist, the other won't, but this ensures a clean slate.
	remove_tool_menu_item("Nexus: Import Mode (Auto)")
	remove_tool_menu_item("Nexus: Import Mode (Manual)")
	
	var is_auto = ProjectSettings.get_setting(SETTING_AUTO_IMPORT)
	var label = "Nexus: Import Mode (Auto)" if is_auto else "Nexus: Import Mode (Manual)"
	
	add_tool_menu_item(label, _toggle_import_mode)

# --- WATCHDOG LOGIC ---

func _on_resources_reimporting(paths: PackedStringArray):
	# THE GATEKEEPER: Only intervene if Auto-Mode is ON.
	if not ProjectSettings.get_setting(SETTING_AUTO_IMPORT):
		return

	for path in paths:
		if path.get_extension() == "gltf":
			# If this is a new file or existing one, we check/inject our script.
			# This modifies the .import file BEFORE the actual import happens.
			_prepare_import_config(path)
			
			# If it's a completely new file (no .import existed yet), we might need
			# to trigger a re-scan/re-import cycle to ensure the new config is picked up.
			if not FileAccess.file_exists(path + ".import"):
				reimport_flag = true

func _on_resources_reimported(resources: PackedStringArray):
	var current_root = get_editor_interface().get_edited_scene_root()
	var current_scene_path = current_root.scene_file_path if current_root else ""
	var needs_scene_reload = false
	
	for res_path in resources:
		var ext = res_path.get_extension()
		
		# 1. SCENE RELOAD LOGIC (If GLTF changed)
		if ext == "gltf":
			# Calculate where the .tscn wrapper lives
			var expected_tscn_path = res_path.get_base_dir().path_join(res_path.get_file().get_basename() + ".tscn")
			# If we are currently editing the scene that was just updated, reload it.
			if expected_tscn_path == current_scene_path:
				needs_scene_reload = true
		
		# 2. MATERIAL HOT RELOAD LOGIC (If TRES changed)
		elif ext == "tres":
			if ResourceLoader.has_cached(res_path):
				var res = ResourceLoader.load(res_path)
				res.emit_changed() # Notify inspector/viewport of changes
				print("Nexus Plugin: Hot-reloaded resource '%s'" % res_path.get_file())

	if needs_scene_reload:
		print("Nexus Plugin: Source GLTF changed. Reloading active scene '%s'..." % current_scene_path.get_file())
		get_editor_interface().reload_scene_from_path(current_scene_path)

func _on_sources_changed(exist: bool):
	if reimport_flag:
		# Trigger a scan to pick up the .import file changes we made for new files
		get_editor_interface().get_resource_filesystem().reimport_files([])
		reimport_flag = false

# --- CONFIG INJECTION LOGIC ---

func _prepare_import_config(gltf_path: String):
	# 1. Check if it is a Nexus Asset
	var scene_meta = _get_nexus_metadata(gltf_path)
	if scene_meta.is_empty(): 
		return # It's a normal GLTF, leave it alone.

	var import_config_path = gltf_path + ".import"
	var import_config = ConfigFile.new()
	
	# Load existing config if available, or create fresh
	if FileAccess.file_exists(import_config_path):
		import_config.load(import_config_path)
	
	# 2. INJECT OUR SCRIPT
	# This is the magic. We tell Godot: "Use this script to process this file."
	var current_script = import_config.get_value("params", "import_script/path", "")
	var target_script = "res://addons/nexus_importer/import_post_processor.gd"
	
	var needs_save = false
	
	if current_script != target_script:
		import_config.set_value("params", "import_script/path", target_script)
		needs_save = true
		print("Nexus Watchdog: Auto-assigned processor to '%s'" % gltf_path.get_file())
	
	# 3. INJECT ROOT TYPE (Optional Optimization)
	# If we know the root type (e.g. CharacterBody3D), we set it here.
	# This saves the processor from having to replace the root node later.
	if "root_type" in scene_meta:
		var desired_type = _get_root_type_string(scene_meta["root_type"])
		var current_type = import_config.get_value("params", "nodes/root_type", "")
		if current_type != desired_type:
			import_config.set_value("params", "nodes/root_type", desired_type)
			needs_save = true
	
	if needs_save:
		import_config.save(import_config_path)

# --- Helper Functions ---

func _get_nexus_metadata(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path): return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return {}
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return {}
	var gltf_data = json.get_data()
	
	# 1. Standard
	var meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 2. Optimizer Fallback
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
		
	return meta

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
