@tool
extends Object

func process(node: Node, node_meta: Dictionary, scene_meta: Dictionary, root: Node, stats: Dictionary) -> bool:
	var has_collision_data = node_meta.has("nexus_collision_dims") or node_meta.has("nexus_mesh_collision_shape")
	if not has_collision_data: return false

	var parent = node.get_parent()
	if not parent: return false

	# 1. Read Offset
	var col_data = node_meta.get("nexus_collision_dims", {})
	var local_offset = Vector3(col_data.get("offset_x", 0), col_data.get("offset_y", 0), col_data.get("offset_z", 0))
	
	# 2. Create Resource
	var shape_resource = _create_shape_resource(node, node_meta, local_offset)
	if not shape_resource:
		return false
	
	# 3. Create and position the CollisionShape3D
	var col_shape_node = CollisionShape3D.new()
	col_shape_node.shape = shape_resource
	
	# Apply pivot correction: Node position = Original + Offset
	var offset_transform = Transform3D(Basis(), local_offset)
	col_shape_node.transform = node.transform * offset_transform
	
	# 4. Meta-Data (Surface Tags)
	var final_tag = ""
	if node_meta.has("nexus_surface_override"):
		final_tag = node_meta["nexus_surface_override"]
	elif scene_meta.has("physics_surface_name"):
		final_tag = scene_meta["physics_surface_name"]
	if not final_tag.is_empty():
		col_shape_node.set_meta("surface", final_tag)

	# --- REPLACE LOGIC ---
	var shape_type = col_data.get("shape", "")
	var discard_mesh = node_meta.get("discard_mesh", false)
	var should_replace = discard_mesh
	if shape_type == "WORLDBOUNDARY" or not node is MeshInstance3D: should_replace = true
	if node.get_class() == "Node3D" and node_meta.has("nexus_collision_dims") and not node_meta.has("nexus_mesh_collision_shape"): should_replace = true

	# STATS UPDATE STATT PRINT
	stats.collisions += 1
	
	if should_replace:
		col_shape_node.name = node.name
		parent.remove_child(node)
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		node.free()
		return true
	else:
		col_shape_node.name = node.name + "_Col"
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		return false

func _create_shape_resource(node: Node, meta: Dictionary, offset: Vector3) -> Shape3D:
	var shape_resource: Shape3D = null
	
	# CASE A: Primitive Shapes (Box, Sphere, etc.)
	if meta.has("nexus_collision_dims") and not meta.has("nexus_mesh_collision_shape"):
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
			"CAPSULE", "CYLINDER":
				var shape = CapsuleShape3D.new() if col_data.get("shape") == "CAPSULE" else CylinderShape3D.new()
				shape.radius = col_data.get("radius", 0.5)
				# FIX: Height Assignment
				shape.height = col_data.get("height", 2.0)
				shape_resource = shape
			"WORLDBOUNDARY":
				shape_resource = WorldBoundaryShape3D.new()
				
	# CASE B: Mesh-Based Shapes (Convex, Trimesh)
	elif meta.has("nexus_mesh_collision_shape") and node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		if mesh:
			var shape_type = meta["nexus_mesh_collision_shape"]
			
			if shape_type == "CONVEX_HULL":
				var convex = mesh.create_convex_shape()
				if offset != Vector3.ZERO:
					var p = convex.points.duplicate()
					for i in range(p.size()):
						p[i] -= offset
					convex.points = p
				shape_resource = convex
				
			elif shape_type == "TRIMESH":
				var trimesh = mesh.create_trimesh_shape()
				if offset != Vector3.ZERO:
					var f = trimesh.get_faces().duplicate()
					for i in range(f.size()):
						f[i] -= offset
					trimesh.set_faces(f)
				shape_resource = trimesh
				
	return shape_resource
