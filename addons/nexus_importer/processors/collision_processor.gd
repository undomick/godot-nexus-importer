@tool
extends Object

const RootProcessor = preload("res://addons/nexus_importer/processors/root_processor.gd")
const COLLISION_SHAPES_DIR := "collisionshapes"

var _root_processor = RootProcessor.new()

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

	if col_data.get("shape", "") == "SEPARATION_RAY":
		shape_resource = _externalize_separation_ray_shape(shape_resource, root, node.name)

	var collision_parent = _resolve_collision_parent(parent, node, scene_meta, root, stats)
	var col_shape_node = _build_collision_shape_node(
		node, shape_resource, local_offset, col_data, collision_parent
	)
	_apply_collision_meta(col_shape_node, scene_meta, node_meta)
	var should_replace = _should_replace_source_node(node, node_meta, col_data)
	stats["collisions"] = int(stats.get("collisions", 0)) + 1

	if should_replace:
		col_shape_node.name = node.name
		parent.remove_child(node)
		collision_parent.add_child(col_shape_node)
		col_shape_node.owner = root
		node.free()
		return true

	col_shape_node.name = node.name + "_Col"
	collision_parent.add_child(col_shape_node)
	col_shape_node.owner = root
	return false

func _resolve_collision_parent(
	parent: Node,
	node: Node,
	scene_meta: Dictionary,
	root: Node,
	stats: Dictionary
) -> Node:
	if parent is CollisionObject3D:
		return parent

	# Bone-attached hitboxes live under ModifierBoneTarget3D, not a physics body.
	if parent is ModifierBoneTarget3D:
		return _wrap_collision_in_hitzone(parent, node, scene_meta, root, stats)

	var ancestor := parent
	while ancestor:
		if ancestor is CollisionObject3D:
			return ancestor
		ancestor = ancestor.get_parent()

	return parent

func _wrap_collision_in_hitzone(
	parent: Node,
	node: Node,
	scene_meta: Dictionary,
	root: Node,
	stats: Dictionary
) -> Area3D:
	var area := Area3D.new()
	area.name = node.name + "_HitZone"
	area.transform = Transform3D.IDENTITY
	parent.add_child(area)
	area.owner = root
	_root_processor.set_collision_layers(area, scene_meta, stats)
	return area

func _build_collision_shape_node(
	node: Node,
	shape_resource: Shape3D,
	local_offset: Vector3,
	col_data: Dictionary,
	collision_parent: Node
) -> CollisionShape3D:
	var col_shape_node = CollisionShape3D.new()
	col_shape_node.shape = shape_resource
	var node3d := node as Node3D
	if node3d == null:
		push_warning("Nexus Collision: Expected Node3D for collision shape on '%s'." % node.name)
		return col_shape_node

	var local_basis = Basis.IDENTITY
	if col_data.get("shape", "") == "SEPARATION_RAY":
		local_basis = Basis.from_euler(Vector3(-PI / 2.0, 0.0, 0.0))
	var offset_transform := Transform3D(local_basis, local_offset)
	var safe_node_transform := NexusTransformSanitize.sanitize(node3d.transform, node3d.name)
	var immediate_parent := node3d.get_parent()
	if immediate_parent != null and collision_parent != immediate_parent:
		var safe_global := NexusTransformSanitize.sanitize(
			NexusTransformSanitize.composed_global_transform(node3d), node3d.name
		)
		var target_global: Transform3D = safe_global * offset_transform
		if collision_parent is Node3D:
			var parent_3d := collision_parent as Node3D
			var safe_parent_global := NexusTransformSanitize.sanitize(
				NexusTransformSanitize.composed_global_transform(parent_3d), parent_3d.name
			)
			col_shape_node.transform = safe_parent_global.affine_inverse() * target_global
		else:
			col_shape_node.transform = safe_node_transform * offset_transform
	else:
		col_shape_node.transform = safe_node_transform * offset_transform
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
		"SEPARATION_RAY":
			var shape = SeparationRayShape3D.new()
			shape.length = col_data.get("length", 1.0)
			shape.slide_on_slope = col_data.get("slide_on_slope", false)
			shape.custom_solver_bias = col_data.get("custom_solver_bias", 0.0)
			shape.margin = col_data.get("shape_margin", 0.04)
			return shape
	return null

func _externalize_separation_ray_shape(shape: Shape3D, root: Node, node_name: String) -> Shape3D:
	if not shape is SeparationRayShape3D:
		return shape

	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	if gltf_path.is_empty():
		return shape

	var shapes_dir := gltf_path.get_base_dir().path_join(COLLISION_SHAPES_DIR)
	var dir_err := DirAccess.make_dir_recursive_absolute(shapes_dir)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("Nexus Collision: Could not create shape folder '%s'." % shapes_dir)
		return shape

	var safe_name := NexusUtils.sanitize_path_segment(node_name)
	var shape_path := shapes_dir.path_join("%s.tres" % safe_name)
	var save_err := ResourceSaver.save(shape, shape_path)
	if save_err != OK:
		push_warning("Nexus Collision: Could not save shape to '%s'." % shape_path)
		return shape

	var loaded := ResourceLoader.load(shape_path) as Shape3D
	return loaded if loaded else shape

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
