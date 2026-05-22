@tool
extends Object

## Creates CollisionShape3D from nexus_collision_dims or nexus_mesh_collision_shape.

func process(node: Node, node_meta: Dictionary, scene_meta: Dictionary, root: Node, stats: Dictionary) -> bool:
	var shape_type = node_meta.get("nexus_mesh_collision_shape", "")
	if shape_type in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
		return false

	var has_collision_data = node_meta.has("nexus_collision_dims") or node_meta.has("nexus_mesh_collision_shape")
	if not has_collision_data:
		return false

	var parent = node.get_parent()
	if not parent:
		return false

	var col_data = node_meta.get("nexus_collision_dims", {})
	var local_offset = Vector3(
		col_data.get("offset_x", 0), col_data.get("offset_y", 0), col_data.get("offset_z", 0)
	)
	var shape_resource = _create_shape_resource(node, node_meta, local_offset)
	if not shape_resource:
		return false

	var col_shape_node = _build_collision_shape_node(node, shape_resource, local_offset)
	_apply_collision_meta(col_shape_node, scene_meta, node_meta)

	var should_replace = _should_replace_source_node(node, node_meta, col_data)
	stats.collisions += 1

	if should_replace:
		col_shape_node.name = node.name
		parent.remove_child(node)
		parent.add_child(col_shape_node)
		col_shape_node.owner = root
		node.free()
		return true

	col_shape_node.name = node.name + "_Col"
	parent.add_child(col_shape_node)
	col_shape_node.owner = root
	return false


func _build_collision_shape_node(
	node: Node,
	shape_resource: Shape3D,
	local_offset: Vector3
) -> CollisionShape3D:
	var col_shape_node = CollisionShape3D.new()
	col_shape_node.shape = shape_resource
	col_shape_node.transform = node.transform * Transform3D(Basis(), local_offset)
	return col_shape_node


func _apply_collision_meta(
	col_shape_node: CollisionShape3D,
	scene_meta: Dictionary,
	node_meta: Dictionary
) -> void:
	var final_meta: Dictionary = {}
	if scene_meta.has("nexus_metadata"):
		for k in scene_meta["nexus_metadata"]:
			final_meta[k] = scene_meta["nexus_metadata"][k]
	if node_meta.has("nexus_metadata"):
		for k in node_meta["nexus_metadata"]:
			final_meta[k] = node_meta["nexus_metadata"][k]
	if node_meta.has("nexus_surface_override") and not final_meta.has("surface"):
		final_meta["surface"] = node_meta["nexus_surface_override"]
	elif scene_meta.has("physics_surface_name") and not final_meta.has("surface"):
		var legacy = scene_meta["physics_surface_name"]
		if not legacy.is_empty():
			final_meta["surface"] = legacy
	for key in final_meta:
		col_shape_node.set_meta(key, final_meta[key])


func _should_replace_source_node(node: Node, node_meta: Dictionary, col_data: Dictionary) -> bool:
	var col_shape = col_data.get("shape", "")
	var discard_mesh = node_meta.get("discard_mesh", false)
	if discard_mesh:
		return true
	return col_shape == "WORLDBOUNDARY" or not node is MeshInstance3D


func _create_shape_resource(node: Node, meta: Dictionary, offset: Vector3) -> Shape3D:
	if meta.has("nexus_collision_dims") and not meta.has("nexus_mesh_collision_shape"):
		return _create_primitive_shape(meta["nexus_collision_dims"])
	if meta.has("nexus_mesh_collision_shape") and node is MeshInstance3D:
		return _create_mesh_shape(node.mesh, meta["nexus_mesh_collision_shape"], offset)
	return null


func _create_primitive_shape(col_data: Dictionary) -> Shape3D:
	match col_data.get("shape"):
		"BOX":
			var shape = BoxShape3D.new()
			shape.size = Vector3(
				col_data.get("size_x", 0) * 2.0,
				col_data.get("size_y", 0) * 2.0,
				col_data.get("size_z", 0) * 2.0
			)
			return shape
		"SPHERE":
			var shape = SphereShape3D.new()
			shape.radius = col_data.get("radius", 0.5)
			return shape
		"CAPSULE", "CYLINDER":
			var shape = CapsuleShape3D.new() if col_data.get("shape") == "CAPSULE" else CylinderShape3D.new()
			shape.radius = col_data.get("radius", 0.5)
			shape.height = col_data.get("height", 2.0)
			return shape
		"WORLDBOUNDARY":
			return WorldBoundaryShape3D.new()
	return null


func _create_mesh_shape(mesh: Mesh, shape_type: String, offset: Vector3) -> Shape3D:
	if not mesh:
		return null
	if shape_type == "CONVEX_HULL":
		var convex = mesh.create_convex_shape()
		if offset != Vector3.ZERO:
			var p = convex.points.duplicate()
			for i in range(p.size()):
				p[i] -= offset
			convex.points = p
		return convex
	if shape_type == "TRIMESH":
		var trimesh = mesh.create_trimesh_shape()
		if offset != Vector3.ZERO:
			var f = trimesh.get_faces().duplicate()
			for i in range(f.size()):
				f[i] -= offset
			trimesh.set_faces(f)
		return trimesh
	return null
