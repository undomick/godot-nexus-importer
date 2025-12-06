# file: addons/nexus_importer/processors/collision_processor.gd
@tool
extends Object

# This function is a direct, 1:1 translation of the original, working logic.
# It returns 'true' only if the original node was deleted.
func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var has_collision_data = meta.has("nexus_collision_dims") or meta.has("nexus_mesh_collision_shape")
	if not has_collision_data:
		return false

	var parent = node.get_parent()
	if not parent: return false

	var shape_resource = _create_shape_resource(node, meta)
	if not shape_resource:
		return false

	# --- THIS LOGIC IS NOW IDENTICAL TO YOUR ORIGINAL SCRIPT ---
	
	var col_data = meta.get("nexus_collision_dims", {})
	var local_offset = Vector3(
		col_data.get("offset_x", 0.0),
		col_data.get("offset_y", 0.0),
		col_data.get("offset_z", 0.0)
	)
	var offset_transform = Transform3D(Basis(), local_offset)
	var final_transform = node.transform * offset_transform

	var col_shape_node = CollisionShape3D.new()
	col_shape_node.shape = shape_resource
	col_shape_node.transform = final_transform

	if meta.get("discard_mesh", false):
		# Case 1: Replace the node.
		col_shape_node.name = node.name
		
		parent.remove_child(node)
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		
		# THE CRITICAL FIX: Use free() for immediate deletion to prevent name clashes.
		node.free()
		
		print("Nexus Processor: Replaced mesh '%s' with a CollisionShape3D." % col_shape_node.name)
		return true
	else:
		# Case 2: Add the shape as a sibling.
		col_shape_node.name = node.name + "_Col"
		
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		
		print("Nexus Processor: Added sibling CollisionShape3D '%s' for node '%s'." % [col_shape_node.name, node.name])
		return false


# --- INTERNAL HELPER FUNCTIONS (UNCHANGED) ---

func _create_shape_resource(node: Node, meta: Dictionary) -> Shape3D:
	var shape_resource: Shape3D = null
	if meta.has("nexus_collision_dims"):
		var col_data = meta["nexus_collision_dims"]
		match col_data.get("shape"):
			"BOX":
				var shape = BoxShape3D.new()
				shape.size = Vector3(col_data.get("size_x", 0)*2.0, col_data.get("size_y", 0)*2.0, col_data.get("size_z", 0)*2.0)
				shape_resource = shape
			"SPHERE":
				var shape = SphereShape3D.new()
				shape.radius = col_data.get("radius", 0.5)
				shape_resource = shape
			"CAPSULE":
				var shape = CapsuleShape3D.new()
				shape.radius = col_data.get("radius", 0.5)
				shape.height = col_data.get("height", 1.0)
				shape_resource = shape
			"CYLINDER":
				var shape = CylinderShape3D.new()
				shape.radius = col_data.get("radius", 0.5)
				shape.height = col_data.get("height", 1.0)
				shape_resource = shape
	elif meta.has("nexus_mesh_collision_shape") and node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		if mesh:
			var shape_type = meta["nexus_mesh_collision_shape"]
			if shape_type == "TRIMESH":
				shape_resource = mesh.create_trimesh_shape()
			elif shape_type == "CONVEX_HULL":
				shape_resource = mesh.create_convex_shape()
	return shape_resource
