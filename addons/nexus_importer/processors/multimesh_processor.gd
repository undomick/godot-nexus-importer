@tool
extends Object

func process(gltf_path: String, scene_meta: Dictionary) -> Node:
	print("Nexus Processor: Processing as MultiMesh Manifest...")

	# 1. Read metadata
	var source_asset_id = scene_meta.get("source_asset_id")
	var transforms = scene_meta.get("transforms")
	var colors = scene_meta.get("colors") 
	var generate_col = scene_meta.get("generate_collisions", false)

	if not source_asset_id or not transforms:
		push_error("Nexus MultiMesh: Manifest '%s' is missing data (ID or Transforms)." % gltf_path)
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
		push_error("Nexus MultiMesh: Source Asset ID '%s' not found in index." % source_asset_id)
		return null

	# 3. Find Source Paths
	var rel_path = asset_index[source_asset_id]["relative_path"]
	if rel_path.begins_with("res://"): 
		rel_path = rel_path.substr(6)
		
	var base_gltf_path = "res://" + rel_path
	var editable_scene_path = base_gltf_path.get_slice(".", 0) + "_editable.tscn"
	var standard_tscn_path = base_gltf_path.get_slice(".", 0) + ".tscn"
	
	var source_scene_path = ""
	if ResourceLoader.exists(editable_scene_path): 
		source_scene_path = editable_scene_path
	elif ResourceLoader.exists(standard_tscn_path): 
		source_scene_path = standard_tscn_path
	elif ResourceLoader.exists(base_gltf_path): 
		source_scene_path = base_gltf_path
	
	if source_scene_path == "":
		push_error("Nexus MultiMesh: Source file not found for ID %s." % source_asset_id)
		return null
	
	# Load Mesh from Source
	var packed_scene = load(source_scene_path)
	if not packed_scene:
		push_error("Nexus MultiMesh: Could not load source scene at '%s'." % source_scene_path)
		return null
		
	var temp_instance = packed_scene.instantiate()
	var source_mesh_instance = _find_node_of_type(temp_instance, "MeshInstance3D")
	
	if not source_mesh_instance or not source_mesh_instance.mesh:
		push_error("Nexus MultiMesh: No MeshInstance3D found in source scene '%s'." % source_scene_path)
		temp_instance.free()
		return null
		
	var source_mesh: Mesh = source_mesh_instance.mesh
	
	# 4. Handle Resource (Create or Load MultiMesh)
	var res_filename = gltf_path.get_file().get_basename() + ".multimesh.res"
	var res_path = gltf_path.get_base_dir().path_join(res_filename)
	
	var multimesh_res: MultiMesh = null
	if ResourceLoader.exists(res_path):
		multimesh_res = ResourceLoader.load(res_path)
	
	if not multimesh_res:
		multimesh_res = MultiMesh.new()

	# --- RESET FIRST ---
	# Godot forbids changing formats while instances exist. 
	# We must reset count to 0 before configuring.
	multimesh_res.instance_count = 0

	# Configure MultiMesh
	multimesh_res.transform_format = MultiMesh.TRANSFORM_3D
	multimesh_res.use_custom_data = false
	multimesh_res.mesh = source_mesh
	
	var has_colors = (colors != null and colors.size() == transforms.size())
	multimesh_res.use_colors = has_colors
	
	# Set instance count exactly once (allocates memory)
	multimesh_res.instance_count = transforms.size()

	# Apply Transforms and Colors
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

	# Save the resource
	var err = ResourceSaver.save(multimesh_res, res_path)
	if err != OK:
		push_error("Nexus MultiMesh: Failed to save resource to '%s'" % res_path)
		temp_instance.free()
		return null

	# 5. Create Node
	var mmi_node = MultiMeshInstance3D.new()
	mmi_node.name = gltf_path.get_file().get_basename()
	mmi_node.multimesh = multimesh_res

	# --- COLLISION HANDLING (COMPOUND SUPPORT) ---
	if generate_col:
		print("Nexus MultiMesh: Searching for collision shapes in '%s'..." % source_scene_path)
		
		# Typed arrays to collect data
		var found_shapes: Array[Shape3D] = []
		var found_transforms: Array[Transform3D] = []
		
		# Recursive helper lambda
		var collect_shapes_recursive = func(node: Node, acc_transform: Transform3D, self_func):
			var current_transform = acc_transform
			
			if node is Node3D:
				current_transform = acc_transform * node.transform
			
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
				
				# Pass data to runtime script
				mmi_node.collision_shapes = found_shapes
				mmi_node.shape_transforms = found_transforms
				
				print(" -> SUCCESS: Attached runtime script with %d shapes." % found_shapes.size())
			else:
				push_error("Nexus MultiMesh: Runtime script missing at '%s'" % script_path)
		else:
			push_warning("Nexus MultiMesh: 'Generate Collisions' is ON, but NO CollisionShape3D found.")

	# Cleanup
	temp_instance.free()

	# --- SUMMARY PRINT ---
	var count = multimesh_res.instance_count
	var col_info = "YES" if (mmi_node.get_script() != null) else "NO"
	var asset_name = mmi_node.name.replace("Collection_", "") 
	
	print_rich("[color=cyan]Nexus:[/color] %s (MULTIMESH) -> [color=gray]%d Instances[/color] -> [color=green]Cols: %s[/color]" % [asset_name, count, col_info])
	
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
