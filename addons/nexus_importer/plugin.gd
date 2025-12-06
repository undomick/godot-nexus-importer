@tool
extends EditorPlugin

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()

var reimport_flag: bool = false

func _enter_tree():
	add_scene_post_import_plugin(scene_post_processor)
	
	var fs = get_editor_interface().get_resource_filesystem()
	fs.resources_reimporting.connect(_on_resources_reimporting)
	fs.sources_changed.connect(_on_sources_changed)
	print("Nexus Importer Plugin: Watcher started (Final Architecture).")

func _exit_tree():
	remove_scene_post_import_plugin(scene_post_processor)
	
	var fs = get_editor_interface().get_resource_filesystem()
	if fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.disconnect(_on_resources_reimporting)
	if fs.sources_changed.is_connected(_on_sources_changed):
		fs.sources_changed.disconnect(_on_sources_changed)
	print("Nexus Importer Plugin: Watcher stopped.")

func _on_resources_reimporting(paths: PackedStringArray):
	for path in paths:
		if path.get_extension() == "gltf":
			if not FileAccess.file_exists(path + ".import"):
				reimport_flag = true
			_prepare_import_config(path)

func _on_sources_changed(exist: bool):
	if reimport_flag:
		get_editor_interface().get_resource_filesystem().reimport_files([])
		reimport_flag = false

func _prepare_import_config(gltf_path: String):
	# WICHTIG: Hier rufen wir die verbesserte Helper-Funktion auf
	var scene_meta = _get_nexus_metadata(gltf_path)
	
	# Wenn keine Metadaten gefunden wurden, brechen wir ab.
	# Das ist der Grund, warum dein Import-Script leer war!
	if scene_meta.is_empty(): return

	var import_config_path = gltf_path + ".import"
	if not FileAccess.file_exists(import_config_path): return

	var import_config = ConfigFile.new()
	if import_config.load(import_config_path) != OK: return

	# Setze das Import-Skript
	import_config.set_value("params", "import_script/path", "res://addons/nexus_importer/import_post_processor.gd")
	
	# Setze Root Type
	if "root_type" in scene_meta:
		import_config.set_value("params", "nodes/root_type", _get_root_type_string(scene_meta["root_type"]))
	
	import_config.save(import_config_path)

# --- Helper Functions ---

func _get_nexus_metadata(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path): return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return {}
	var gltf_data = json.get_data()
	
	# 1. Versuche Standard-Ort (scenes -> extras)
	var meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 2. Versuche Fallback-Ort für Optimizer (asset -> extras)
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
		
	return meta

func _get_root_type_string(nexus_type: String) -> String:
	var map = {
		"NODE_3D": "Node3D", "STATIC": "StaticBody3D", "RIGID": "RigidBody3D",
		"AREA": "Area3D", "CHARACTER_BODY": "CharacterBody3D", "NAVMESH": "NavigationRegion3D"
	}
	return map.get(nexus_type, "Node3D")
