@tool
extends EditorScenePostImportPlugin

const NEXUS_ASSET_META = "NEXUS_ASSET_METADATA"
const RootProcessor = preload("res://addons/nexus_importer/processors/root_processor.gd")
var root_processor = RootProcessor.new()

func _get_import_options(path: String):
	add_import_option("internal_nexus_path", path)

func _get_option_visibility(path, for_animation, option):
	return option != "internal_nexus_path"

# This function is executed as one of the final steps on the imported scene.
func _post_process(scene: Node) -> void:
	var gltf_path = get_option_value("internal_nexus_path")
	
	var scene_meta = _get_nexus_metadata(gltf_path)
	if scene_meta.is_empty(): return

	# === LOGIC RESTORED ===
	# We operate directly on the `scene` node provided by the engine.
	# This is the imported Root Node (e.g. StaticBody3D, Node3D).
	
	# 1. Apply the group directly to this node.
	var group_name = scene_meta.get("group_name", "")
	if not group_name.is_empty():
		# The `true` flag ensures the group assignment is saved persistently
		# in the imported .scn file within the .godot folder.
		scene.add_to_group(group_name, true)
		print("Nexus Finisher: Added imported scene '%s' to group '%s'." % [scene.name, group_name])

	# 2. Assigning the script is more complicated because the .tscn contains the instance.
	# We keep the logic to load the .tscn, as this is necessary for scripts.
	# However, group assignment is now decoupled from this.
	_apply_script_to_instanced_scene(gltf_path, scene, scene_meta)

# This function now only handles the script assignment to the wrapper scene.
func _apply_script_to_instanced_scene(gltf_path: String, scene: Node, scene_meta: Dictionary):
	var script_path = scene_meta.get("script_path", "")
	if script_path.is_empty(): return

	var tscn_path = gltf_path.get_base_dir().path_join(scene.name + ".tscn")
	if not ResourceLoader.exists(tscn_path):
		# If the .tscn does not exist yet, the script cannot be assigned.
		# The next re-import will resolve this.
		return
		
	var packed_scene: PackedScene = ResourceLoader.load(tscn_path)
	if not packed_scene: return
		
	var scene_root = packed_scene.instantiate()
	# Get the actual GLTF instance inside the wrapper
	var gltf_instance = scene_root.get_child(0) if scene_root.get_child_count() > 0 else null

	if is_instance_valid(gltf_instance):
		if root_processor.apply_script(gltf_instance, scene_meta):
			print("Nexus Finisher: Applied script to instance in '%s'." % tscn_path.get_file())
			# Resave the scene with the assigned script.
			if packed_scene.pack(scene_root) == OK:
				ResourceSaver.save(packed_scene, tscn_path)

	scene_root.free()

# Helper for safe metadata loading
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
