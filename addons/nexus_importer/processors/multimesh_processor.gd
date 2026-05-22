@tool
extends Object

## Converts MULTIMESH_MANIFEST glTF to MultiMeshInstance3D with transforms and optional collisions.

func process(gltf_path: String, scene_meta: Dictionary) -> Node:
	print_verbose("Nexus Processor: Processing as MultiMesh Manifest...")

	var manifest := _read_manifest(scene_meta)
	if manifest.is_empty():
		push_error("Nexus MultiMesh: Manifest '%s' is missing data." % gltf_path)
		return _create_error_node("Manifest Missing Data")

	var entry := _load_asset_index_entry(manifest.source_asset_id)
	if entry.is_empty():
		return _create_error_node("Asset Index Missing")

	var source_scene_path := _resolve_source_scene_path(entry, manifest.source_asset_id)
	if source_scene_path.is_empty():
		return _create_error_node("Source File Missing")

	var mesh_result := _load_source_mesh(source_scene_path)
	if not mesh_result.has("mesh"):
		return _create_error_node(mesh_result.get("error", "Source Load Failed"))

	var multimesh_res := _build_multimesh_resource(
		gltf_path,
		mesh_result.mesh,
		manifest.transforms,
		manifest.colors
	)
	if multimesh_res == null:
		return _create_error_node("Res Save Failed")

	var mmi_node := _create_multimesh_instance(gltf_path, multimesh_res)
	_attach_collision_script(mmi_node, mesh_result.temp_instance, manifest.generate_collisions, source_scene_path)
	mesh_result.temp_instance.free()

	var col_info = "YES" if mmi_node.get_script() != null else "NO"
	var asset_name = mmi_node.name.replace("Collection_", "")
	print_verbose(
		"Nexus: %s (MULTIMESH) -> %d Instances -> Cols: %s"
		% [asset_name, multimesh_res.instance_count, col_info]
	)
	return mmi_node


func _read_manifest(scene_meta: Dictionary) -> Dictionary:
	var source_asset_id = scene_meta.get("source_asset_id")
	var transforms = scene_meta.get("transforms")
	if not source_asset_id or not transforms:
		return {}
	return {
		"source_asset_id": source_asset_id,
		"transforms": transforms,
		"colors": scene_meta.get("colors"),
		"generate_collisions": scene_meta.get("generate_collisions", false),
	}


func _load_asset_index_entry(source_asset_id: String) -> Dictionary:
	var asset_index_path = NexusPaths.asset_index_path()
	if not FileAccess.file_exists(asset_index_path):
		push_error("Nexus MultiMesh: Asset index missing at '%s'." % asset_index_path)
		return {}

	var index_file = FileAccess.open(asset_index_path, FileAccess.READ)
	var json = JSON.new()
	if json.parse(index_file.get_as_text()) != OK:
		index_file.close()
		return {}
	var asset_index = json.get_data()
	index_file.close()
	if not asset_index.has(source_asset_id):
		push_error("Nexus MultiMesh: Source Asset ID '%s' not found." % source_asset_id)
		return {}

	var entry = asset_index[source_asset_id]
	if not entry is Dictionary:
		push_error("Nexus MultiMesh: Invalid index entry for Asset ID '%s'." % source_asset_id)
		return {}
	return entry


func _resolve_source_scene_path(entry: Dictionary, source_asset_id: String) -> String:
	var rel_path = entry.get("relative_path", "")
	var base_gltf_path = NexusUtils.validate_index_path(rel_path)
	if base_gltf_path.is_empty():
		push_error("Nexus MultiMesh: Invalid path in index for Asset ID '%s'." % source_asset_id)
		return ""

	var base_no_ext = base_gltf_path.get_basename()
	var editable_scene_path = base_no_ext + "_editable.tscn"
	var standard_tscn_path = base_no_ext + ".tscn"

	if ResourceLoader.exists(editable_scene_path):
		return editable_scene_path
	if ResourceLoader.exists(standard_tscn_path):
		return standard_tscn_path
	if ResourceLoader.exists(base_gltf_path):
		return base_gltf_path

	push_error("Nexus MultiMesh: Source file not found for ID %s." % source_asset_id)
	return ""


func _load_source_mesh(source_scene_path: String) -> Dictionary:
	var packed_scene = load(source_scene_path)
	if not packed_scene:
		return {"error": "Source Load Failed"}

	var temp_instance = packed_scene.instantiate()
	var source_mesh_instance = NexusSceneUtils.find_first_node_of_type(temp_instance, "MeshInstance3D")
	if not source_mesh_instance or not source_mesh_instance.mesh:
		temp_instance.free()
		return {"error": "No Mesh in Source"}

	return {"mesh": source_mesh_instance.mesh, "temp_instance": temp_instance}


func _build_multimesh_resource(
	gltf_path: String,
	source_mesh: Mesh,
	transforms: Array,
	colors: Variant
) -> MultiMesh:
	# Always create fresh to avoid Godot bug #95617/#106950 (wrong deserialize order on load).
	var res_filename = gltf_path.get_file().get_basename() + ".multimesh.res"
	var res_path = gltf_path.get_base_dir().path_join(res_filename)
	var multimesh_res := MultiMesh.new()
	multimesh_res.instance_count = 0

	if multimesh_res.transform_format != MultiMesh.TRANSFORM_3D:
		multimesh_res.transform_format = MultiMesh.TRANSFORM_3D
	if multimesh_res.use_custom_data:
		multimesh_res.use_custom_data = false
	if multimesh_res.mesh != source_mesh:
		multimesh_res.mesh = source_mesh

	var has_colors = colors != null and colors.size() == transforms.size()
	if multimesh_res.use_colors != has_colors:
		multimesh_res.use_colors = has_colors

	multimesh_res.instance_count = transforms.size()
	for i in range(transforms.size()):
		var t_data = transforms[i]
		if not t_data is Dictionary:
			push_warning("Nexus MultiMesh: Transform entry %d is not a dictionary - skipped." % i)
			continue
		if not t_data.has("location") or not t_data.has("rotation") or not t_data.has("scale"):
			push_warning("Nexus MultiMesh: Transform entry %d missing location/rotation/scale - skipped." % i)
			continue
		var loc_arr = t_data["location"]
		var rot_arr = t_data["rotation"]
		var scale_arr = t_data["scale"]
		if loc_arr.size() < 3 or rot_arr.size() < 4 or scale_arr.size() < 3:
			push_warning("Nexus MultiMesh: Transform entry %d has invalid array sizes - skipped." % i)
			continue
		var loc = Vector3(loc_arr[0], loc_arr[1], loc_arr[2])
		var rot = Quaternion(rot_arr[0], rot_arr[1], rot_arr[2], rot_arr[3])
		var scale = Vector3(scale_arr[0], scale_arr[1], scale_arr[2])
		multimesh_res.set_instance_transform(i, Transform3D(Basis(rot).scaled(scale), loc))
		if has_colors:
			var c = colors[i]
			multimesh_res.set_instance_color(i, Color(c[0], c[1], c[2], c[3]))

	if ResourceSaver.save(multimesh_res, res_path) != OK:
		return null
	return multimesh_res


func _create_multimesh_instance(gltf_path: String, multimesh_res: MultiMesh) -> MultiMeshInstance3D:
	var mmi_node = MultiMeshInstance3D.new()
	mmi_node.name = gltf_path.get_file().get_basename()
	mmi_node.multimesh = multimesh_res
	return mmi_node


func _attach_collision_script(
	mmi_node: MultiMeshInstance3D,
	source_instance: Node,
	generate_col: bool,
	source_scene_path: String
) -> void:
	if not generate_col:
		return
	print_verbose("Nexus MultiMesh: Searching for collision shapes in '%s'..." % source_scene_path)
	var found_shapes: Array[Shape3D] = []
	var found_transforms: Array[Transform3D] = []

	var collect_shapes_recursive = func(node: Node, acc_transform: Transform3D, self_func):
		var current_transform = acc_transform
		if node is Node3D:
			current_transform = acc_transform * node.transform
		if node is CollisionShape3D and node.shape:
			found_shapes.append(node.shape)
			found_transforms.append(current_transform)
		for child in node.get_children():
			self_func.call(child, current_transform, self_func)

	collect_shapes_recursive.call(source_instance, Transform3D.IDENTITY, collect_shapes_recursive)
	if found_shapes.is_empty():
		return

	var script_path = "res://addons/nexus_importer/runtime/multimesh_collider.gd"
	if not ResourceLoader.exists(script_path):
		return
	mmi_node.set_script(load(script_path))
	mmi_node.collision_shapes = found_shapes
	mmi_node.shape_transforms = found_transforms
	print_verbose(" -> SUCCESS: Attached runtime script with %d shapes." % found_shapes.size())


func _create_error_node(reason: String) -> Node3D:
	var root = Node3D.new()
	root.name = "MULTIMESH_ERROR"

	var mesh_inst = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	mesh_inst.mesh = box

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0)
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
