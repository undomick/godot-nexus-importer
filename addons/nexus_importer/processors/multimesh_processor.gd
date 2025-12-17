# file: addons/nexus_importer/processors/multimesh_processor.gd
@tool
extends Object

func process(gltf_path: String, scene_meta: Dictionary) -> Node:
	print("Nexus Processor: Processing as MultiMesh Manifest...")

	# 1. Read metadata
	var source_asset_id = scene_meta.get("source_asset_id")
	var transforms = scene_meta.get("transforms")

	if not source_asset_id or not transforms:
		push_error("Nexus MultiMesh: Manifest '%s' is missing data." % gltf_path)
		return null

	# 2. Load asset_index
	if not FileAccess.file_exists('res://asset_index.json'):
		push_error("Nexus MultiMesh: asset_index.json missing.")
		return null
	
	var index_file = FileAccess.open('res://asset_index.json', FileAccess.READ)
	var json = JSON.new()
	if json.parse(index_file.get_as_text()) != OK:
		push_error("Nexus MultiMesh: Could not parse asset_index.json.")
		return null
		
	var asset_index = json.get_data()
	if not asset_index.has(source_asset_id):
		push_error("Nexus MultiMesh: Source Asset ID '%s' not found in asset_index.json." % source_asset_id)
		return null

	# 3. Extract source mesh
	var rel_path = asset_index[source_asset_id]["relative_path"]
	if rel_path.begins_with("res://"): rel_path = rel_path.substr(6)
	var base_gltf_path = "res://" + rel_path
	var editable_scene_path = base_gltf_path.get_slice(".", 0) + "_editable.tscn"
	var source_scene_path = ""

	if ResourceLoader.exists(editable_scene_path): source_scene_path = editable_scene_path
	elif ResourceLoader.exists(base_gltf_path): source_scene_path = base_gltf_path
	else:
		push_error("Nexus MultiMesh: Source file not found at '%s'." % base_gltf_path)
		return null
	
	var packed_scene: PackedScene = load(source_scene_path)
	if not packed_scene:
		push_error("Nexus MultiMesh: Could not load source scene.")
		return null
		
	var temp_instance = packed_scene.instantiate()
	var source_mesh_instance = _find_node_of_type(temp_instance, "MeshInstance3D")
	
	if not source_mesh_instance or not source_mesh_instance.mesh:
		push_error("Nexus MultiMesh: No MeshInstance3D found in source scene.")
		temp_instance.free()
		return null
		
	var source_mesh: Mesh = source_mesh_instance.mesh
	temp_instance.free()

	# 4. Handle External Resource (UPDATE IN-PLACE STRATEGY)
	var res_filename = gltf_path.get_file().get_basename() + ".multimesh.res"
	var res_path = gltf_path.get_base_dir().path_join(res_filename)
	
	var multimesh_res: MultiMesh = null
	
	# Try to load existing resource. 
	# If the scene is open, this gives us the instance currently in memory.
	if ResourceLoader.exists(res_path):
		multimesh_res = ResourceLoader.load(res_path)
	
	if not multimesh_res:
		multimesh_res = MultiMesh.new()

	# 5. Update Data
	# CRITICAL: Reset count to 0 immediately. 
	# This clears the internal buffer and allows changing flags (colors, format) safely,
	# preventing the "Instance count must be 0" error during updates.
	multimesh_res.instance_count = 0
	
	# Now configure flags
	multimesh_res.transform_format = MultiMesh.TRANSFORM_3D
	multimesh_res.use_colors = false
	multimesh_res.use_custom_data = false
	multimesh_res.mesh = source_mesh
	
	# Allocate Memory
	multimesh_res.instance_count = transforms.size()

	# Populate Transforms
	for i in range(transforms.size()):
		var t_data = transforms[i]
		
		var location = Vector3(t_data["location"][0], t_data["location"][1], t_data["location"][2])
		var rotation = Quaternion(t_data["rotation"][0], t_data["rotation"][1], t_data["rotation"][2], t_data["rotation"][3])
		var scale = Vector3(t_data["scale"][0], t_data["scale"][1], t_data["scale"][2])
		
		var basis = Basis(rotation).scaled(scale)
		var transform = Transform3D(basis, location)
		
		multimesh_res.set_instance_transform(i, transform)

	# 6. Save Resource to Disk
	var err = ResourceSaver.save(multimesh_res, res_path)
	if err != OK:
		push_error("Nexus MultiMesh: Failed to save resource to '%s'" % res_path)
		return null

	print(" -> Saved MultiMesh resource to '%s'" % res_path)

	# 7. Create Node
	var mmi_node = MultiMeshInstance3D.new()
	mmi_node.name = gltf_path.get_file().get_basename()
	
	# Assign the resource we just modified (it's the same pointer if loaded)
	mmi_node.multimesh = multimesh_res

	print(" -> Success: Created MultiMeshInstance with %d instances." % multimesh_res.instance_count)
	return mmi_node

func _find_node_of_type(root: Node, class_type: StringName) -> Node:
	var queue = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.is_class(class_type):
			return current
		for child in current.get_children():
			queue.push_back(child)
	return null
