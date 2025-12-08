# file: addons/nexus_importer/processors/collision_processor.gd
@tool
extends Object

# This function processes collision metadata.
# It handles both primitive shapes (Box, Sphere, etc.) and mesh-based shapes.
func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var has_collision_data = meta.has("nexus_collision_dims") or meta.has("nexus_mesh_collision_shape")
	if not has_collision_data:
		return false

	var parent = node.get_parent()
	if not parent: return false

	var shape_resource = _create_shape_resource(node, meta)
	if not shape_resource:
		return false

	var col_data = meta.get("nexus_collision_dims", {})
	var shape_type = col_data.get("shape", "")
	
	# Calculate Transform
	var local_offset = Vector3(
		col_data.get("offset_x", 0.0),
		col_data.get("offset_y", 0.0),
		col_data.get("offset_z", 0.0)
	)
	var offset_transform = Transform3D(Basis(), local_offset)
	var final_transform = node.transform * offset_transform

	# Create the new node
	var col_shape_node = CollisionShape3D.new()
	col_shape_node.shape = shape_resource
	col_shape_node.transform = final_transform

	# --- LOGIC DECISION: REPLACE OR ADD SIBLING? ---
	var should_replace = meta.get("discard_mesh", false)
	
	# Rule 1: Always replace if it is a WorldBoundary (infinite, invisible plane).
	# Keeping the source mesh/empty serves no purpose here.
	if shape_type == "WORLDBOUNDARY":
		should_replace = true
		
	# Rule 2: If the source node is just a plain Node3D (Blender Empty), 
	# and it is being used to define a primitive collider, replace it to clean up the tree.
	if node.get_class() == "Node3D" and meta.has("nexus_collision_dims"):
		should_replace = true

	if should_replace:
		# Case 1: Replace the node (Clean Hierarchy)
		col_shape_node.name = node.name
		
		parent.remove_child(node)
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		
		node.free()
		
		print("Nexus Processor: Replaced '%s' with CollisionShape3D (%s)." % [col_shape_node.name, shape_type if shape_type else "MESH"])
		return true
	else:
		# Case 2: Add as Sibling (Keep Visuals)
		col_shape_node.name = node.name + "_Col"
		
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		
		print("Nexus Processor: Added sibling CollisionShape3D '%s' for node '%s'." % [col_shape_node.name, node.name])
		return false


# --- INTERNAL HELPER FUNCTIONS ---

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
			"WORLDBOUNDARY":
				shape_resource = WorldBoundaryShape3D.new()
			"HEIGHTMAP":
				# Placeholder logic for HeightMap (requires image data handling usually)
				pass 
				
	elif meta.has("nexus_mesh_collision_shape") and node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		if mesh:
			var shape_type = meta["nexus_mesh_collision_shape"]
			if shape_type == "TRIMESH":
				shape_resource = mesh.create_trimesh_shape()
			elif shape_type == "CONVEX_HULL":
				shape_resource = mesh.create_convex_shape()
	return shape_resource
