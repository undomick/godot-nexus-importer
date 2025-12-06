# file: addons/nexus_importer/processors/multimesh_processor.gd
@tool
extends Object

# This function processes a 'MULTIMESH_MANIFEST' export type.
# It builds a new MultiMeshInstance3D node from scratch based on the metadata.
func process(gltf_path: String, scene_meta: Dictionary) -> Node:
	print("Nexus Processor: Processing as MultiMesh Manifest...")

	# 1. Read metadata
	var source_asset_id = scene_meta.get("source_asset_id")
	var transforms = scene_meta.get("transforms")

	if not source_asset_id or not transforms:
		push_error("Nexus MultiMesh: Manifest '%s' is missing 'source_asset_id' or 'transforms'." % gltf_path)
		return null

	# 2. Load asset_index to find the path to the source asset
	var index_file = FileAccess.open('res://asset_index.json', FileAccess.READ)
	if not index_file:
		push_error("Nexus MultiMesh: asset_index.json not found. Cannot resolve source.")
		return null
	
	var json = JSON.new()
	if json.parse(index_file.get_as_text()) != OK:
		push_error("Nexus MultiMesh: Could not parse asset_index.json.")
		return null
		
	var asset_index = json.get_data()
	if not asset_index.has(source_asset_id):
		push_error("Nexus MultiMesh: Source Asset ID '%s' not found in asset_index.json." % source_asset_id)
		return null

	# 3. Extract the source mesh from the referenced scene
	# We prefer the editable scene if it exists.
	var base_gltf_path = "res://" + asset_index[source_asset_id]["relative_path"]
	var editable_scene_path = base_gltf_path.get_slice(".", 0) + "_editable.tscn"
	var source_scene_path = ""

	if ResourceLoader.exists(editable_scene_path):
		source_scene_path = editable_scene_path
	else:
		source_scene_path = base_gltf_path
	
	var packed_scene: PackedScene = load(source_scene_path)
	
	if not packed_scene:
		push_error("Nexus MultiMesh: Could not load source scene at '%s'." % source_scene_path)
		return null
		
	var temp_instance = packed_scene.instantiate()
	var source_mesh_instance = _find_node_of_type(temp_instance, "MeshInstance3D")
	
	if not source_mesh_instance or not source_mesh_instance.mesh:
		push_error("Nexus MultiMesh: No MeshInstance3D with a valid mesh found in source scene '%s'." % source_scene_path)
		temp_instance.queue_free()
		return null
		
	var source_mesh: Mesh = source_mesh_instance.mesh
	# IMPORTANT: Free the temporary instance immediately!
	temp_instance.queue_free()

	print(" -> Successfully extracted source mesh from '%s'." % source_scene_path)

	# 4. Create and configure the MultiMesh resource
	var multimesh_res = MultiMesh.new()
	multimesh_res.mesh = source_mesh
	multimesh_res.transform_format = MultiMesh.TRANSFORM_3D
	multimesh_res.instance_count = transforms.size()

	# 5. Populate the resource with the exported transforms
	for i in range(transforms.size()):
		var t_data = transforms[i]
		
		var location = Vector3(t_data["location"][0], t_data["location"][1], t_data["location"][2])
		var rotation = Quaternion(t_data["rotation"][0], t_data["rotation"][1], t_data["rotation"][2], t_data["rotation"][3])
		var scale = Vector3(t_data["scale"][0], t_data["scale"][1], t_data["scale"][2])
		
		var basis = Basis(rotation).scaled(scale)
		var transform = Transform3D(basis, location)
		
		multimesh_res.set_instance_transform(i, transform)

	# 6. Create the MultiMeshInstance3D node that will use the resource
	var mmi_node = MultiMeshInstance3D.new()
	mmi_node.multimesh = multimesh_res
	mmi_node.name = gltf_path.get_file().get_basename()

	print(" -> Created MultiMeshInstance3D '%s' with %d instances." % [mmi_node.name, multimesh_res.instance_count])

	# 7. Return the completed node so it can be saved as the imported scene
	return mmi_node


# Helper to find the first node of a specific class type in a scene tree.
func _find_node_of_type(root: Node, class_type: StringName) -> Node:
	var queue = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.get_class() == class_type:
			return current
		for child in current.get_children():
			queue.push_back(child)
	return null
