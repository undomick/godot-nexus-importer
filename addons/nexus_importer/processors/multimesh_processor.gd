@tool
extends Object

## Converts MULTIMESH_MANIFEST glTF to MultiMeshInstance3D with transforms and optional collisions.

func process(gltf_path: String, scene_meta: Dictionary) -> Node:
	print_verbose("Nexus Processor: Processing as MultiMesh Manifest...")

	# 1. Read metadata
	var source_asset_id = scene_meta.get("source_asset_id")
	var transforms = scene_meta.get("transforms")
	var colors = scene_meta.get("colors") 
	var generate_col = scene_meta.get("generate_collisions", false)

	if not source_asset_id or not transforms:
		push_error("Nexus MultiMesh: Manifest '%s' is missing data." % gltf_path)
		return _create_error_node("Manifest Missing Data")

	# 2. Load asset_index
	var asset_index_path = ProjectSettings.get_setting("nexus/import/asset_index_path", "res://asset_index.json")
	if not FileAccess.file_exists(asset_index_path):
		push_error("Nexus MultiMesh: Asset index missing at '%s'." % asset_index_path)
		return _create_error_node("Asset Index Missing")
	
	var index_file = FileAccess.open(asset_index_path, FileAccess.READ)
	var json = JSON.new()
	if json.parse(index_file.get_as_text()) != OK:
		return _create_error_node("Index Corrupt")
		
	var asset_index = json.get_data()
	if not asset_index.has(source_asset_id):
		push_error("Nexus MultiMesh: Source Asset ID '%s' not found." % source_asset_id)
		return _create_error_node("Source Asset ID Not Found")

	var entry = asset_index[source_asset_id]
	if not entry is Dictionary:
		push_error("Nexus MultiMesh: Invalid index entry for Asset ID '%s'." % source_asset_id)
		return _create_error_node("Index Entry Invalid")

	# 3. Find Source Paths
	var rel_path = entry.get("relative_path", "")
	var base_gltf_path = NexusUtils.validate_index_path(rel_path)
	if base_gltf_path.is_empty():
		push_error("Nexus MultiMesh: Invalid path in index for Asset ID '%s'." % source_asset_id)
		return _create_error_node("Invalid Path") 
	
	var base_no_ext = base_gltf_path.get_basename()
	var editable_scene_path = base_no_ext + "_editable.tscn"
	var standard_tscn_path = base_no_ext + ".tscn"
	
	var source_scene_path = ""
	if ResourceLoader.exists(editable_scene_path): 
		source_scene_path = editable_scene_path
	elif ResourceLoader.exists(standard_tscn_path): 
		source_scene_path = standard_tscn_path
	elif ResourceLoader.exists(base_gltf_path): 
		source_scene_path = base_gltf_path
	
	if source_scene_path == "":
		push_error("Nexus MultiMesh: Source file not found for ID %s." % source_asset_id)
		return _create_error_node("Source File Missing")
	
	# Load Mesh from Source
	var packed_scene = load(source_scene_path)
	if not packed_scene:
		return _create_error_node("Source Load Failed")
		
	var temp_instance = packed_scene.instantiate()
	var source_mesh_instance = _find_node_of_type(temp_instance, "MeshInstance3D")
	
	if not source_mesh_instance or not source_mesh_instance.mesh:
		temp_instance.free()
		return _create_error_node("No Mesh in Source")
		
	var source_mesh: Mesh = source_mesh_instance.mesh
	
	# 4. Handle Resource - always create fresh to avoid Godot bug #95617/#106950:
	# loading .multimesh.res can deserialize properties in wrong order, triggering
	# "Instance count must be 0 to change..." errors. We overwrite the file anyway.
	var res_filename = gltf_path.get_file().get_basename() + ".multimesh.res"
	var res_path = gltf_path.get_base_dir().path_join(res_filename)
	var multimesh_res := MultiMesh.new()

	# --- CONFIGURATION ---
	multimesh_res.instance_count = 0 
	
	if multimesh_res.transform_format != MultiMesh.TRANSFORM_3D:
		multimesh_res.transform_format = MultiMesh.TRANSFORM_3D
		
	if multimesh_res.use_custom_data: # We want false
		multimesh_res.use_custom_data = false
		
	if multimesh_res.mesh != source_mesh:
		multimesh_res.mesh = source_mesh
	
	var has_colors = (colors != null and colors.size() == transforms.size())
	if multimesh_res.use_colors != has_colors:
		multimesh_res.use_colors = has_colors
	
	# Now populate
	multimesh_res.instance_count = transforms.size()

	for i in range(transforms.size()):
		var t_data = transforms[i]
		var loc = Vector3(t_data["location"][0], t_data["location"][1], t_data["location"][2])
		var rot = Quaternion(t_data["rotation"][0], t_data["rotation"][1], t_data["rotation"][2], t_data["rotation"][3])
		var scale = Vector3(t_data["scale"][0], t_data["scale"][1], t_data["scale"][2])
		
		var basis = Basis(rot).scaled(scale)
		multimesh_res.set_instance_transform(i, Transform3D(basis, loc))
		
		if has_colors:
			var c = colors[i]
			multimesh_res.set_instance_color(i, Color(c[0], c[1], c[2], c[3]))

	var err = ResourceSaver.save(multimesh_res, res_path)
	if err != OK:
		temp_instance.free()
		return _create_error_node("Res Save Failed")

	# Use in-memory resource directly. Skipping ResourceLoader.load() avoids Godot bug #95617/#106950:
	# loading .multimesh.res can deserialize instance_count before transform_format/use_colors/use_custom_data,
	# triggering "Instance count must be 0 to change..." errors. Our multimesh_res is already configured correctly.
	# ResourceSaver.save() sets resource_path, so the node will reference the file for persistence.

	# 5. Create Node
	var mmi_node = MultiMeshInstance3D.new()
	mmi_node.name = gltf_path.get_file().get_basename()
	mmi_node.multimesh = multimesh_res

	# Collision Handling
	if generate_col:
		print_verbose("Nexus MultiMesh: Searching for collision shapes in '%s'..." % source_scene_path)
		var found_shapes: Array[Shape3D] = []
		var found_transforms: Array[Transform3D] = []
		
		var collect_shapes_recursive = func(node: Node, acc_transform: Transform3D, self_func):
			var current_transform = acc_transform
			if node is Node3D: current_transform = acc_transform * node.transform
			if node is CollisionShape3D and node.shape:
				found_shapes.append(node.shape)
				found_transforms.append(current_transform)
			for child in node.get_children():
				self_func.call(child, current_transform, self_func)
		
		collect_shapes_recursive.call(temp_instance, Transform3D.IDENTITY, collect_shapes_recursive)
		
		if found_shapes.size() > 0:
			var script_path = "res://addons/nexus_importer/runtime/multimesh_collider.gd"
			if ResourceLoader.exists(script_path):
				var script = load(script_path)
				mmi_node.set_script(script)
				mmi_node.collision_shapes = found_shapes
				mmi_node.shape_transforms = found_transforms
				print_verbose(" -> SUCCESS: Attached runtime script with %d shapes." % found_shapes.size())

	temp_instance.free()

	var count = multimesh_res.instance_count
	var col_info = "YES" if (mmi_node.get_script() != null) else "NO"
	var asset_name = mmi_node.name.replace("Collection_", "") 
	
	print_verbose("Nexus: %s (MULTIMESH) -> %d Instances -> Cols: %s" % [asset_name, count, col_info])
	
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

# --- ERROR VISUALIZER ---
func _create_error_node(reason: String) -> Node3D:
	var root = Node3D.new()
	root.name = "MULTIMESH_ERROR"
	
	var mesh_inst = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	mesh_inst.mesh = box
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0) # Red Error Color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat
	
	root.add_child(mesh_inst)
	
	var label = Label3D.new()
	label.text = "ERROR: " + reason
	label.pixel_size = 0.01
	label.position = Vector3(0, 1.2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)
	
	return root
