@tool
extends Object

func process(scene_root: Node, scene_meta: Dictionary) -> void:
	if scene_meta.get("root_type") != "NAVMESH":
		return
	if not scene_root is NavigationRegion3D:
		push_error("Nexus NavMesh: Root node is not a NavigationRegion3D.")
		return

	var nav_mesh := _configure_nav_mesh(scene_root, scene_meta)
	_bake_nav_mesh(scene_root, nav_mesh)
	_remove_source_meshes(scene_root)


func _configure_nav_mesh(scene_root: NavigationRegion3D, scene_meta: Dictionary) -> NavigationMesh:
	var navmesh_settings = scene_meta.get("navmesh_settings", {})
	var nav_mesh = NavigationMesh.new()
	nav_mesh.cell_size = navmesh_settings.get("cell_size", 0.25)
	nav_mesh.agent_height = navmesh_settings.get("agent_height", 2.0)
	nav_mesh.agent_radius = navmesh_settings.get("agent_radius", 0.5)
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES

	var first_mesh = _find_first_mesh(scene_root)
	if first_mesh and first_mesh.has_meta("has_nav_cost_data"):
		scene_root.travel_cost = navmesh_settings.get("travel_cost", 1.0)
		print_verbose(
			" -> NavCost data found. Travel cost multiplier set to %f." % scene_root.travel_cost
		)

	scene_root.navigation_mesh = nav_mesh
	return nav_mesh


func _bake_nav_mesh(scene_root: NavigationRegion3D, nav_mesh: NavigationMesh) -> void:
	print_verbose(" -> Starting NavMesh bake (Manual Parsing Mode)...")
	var source_geometry_data = NavigationMeshSourceGeometryData3D.new()
	_parse_nodes_recursive(scene_root, Transform3D.IDENTITY, source_geometry_data)
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry_data)
	print_verbose(" -> NavMesh bake completed.")


func _remove_source_meshes(scene_root: Node) -> void:
	for mesh in _collect_mesh_instances(scene_root):
		mesh.queue_free()


func _parse_nodes_recursive(
	node: Node,
	parent_accumulated_transform: Transform3D,
	source_data: NavigationMeshSourceGeometryData3D
) -> void:
	var current_transform = parent_accumulated_transform
	if node is Node3D:
		current_transform = parent_accumulated_transform * node.transform
	if node is MeshInstance3D and node.mesh:
		source_data.add_mesh(node.mesh, current_transform)
	for child in node.get_children():
		_parse_nodes_recursive(child, current_transform, source_data)


func _find_first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var res = _find_first_mesh(child)
		if res:
			return res
	return null


func _collect_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for child in node.get_children():
		result.append_array(_collect_mesh_instances(child))
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	return result
