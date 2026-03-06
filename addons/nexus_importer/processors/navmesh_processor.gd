@tool
extends Object

## Bakes NavigationMesh from mesh geometry for assets with NAVMESH root type.
# It manually extracts mesh geometry to bypass SceneTree requirements during import.
func process(scene_root: Node, scene_meta: Dictionary) -> void:
	if scene_meta.get("root_type") != "NAVMESH":
		return

	if not scene_root is NavigationRegion3D:
		push_error("Nexus NavMesh: Root node is not a NavigationRegion3D.")
		return
	
	var navmesh_settings = scene_meta.get("navmesh_settings", {})
	
	# 1. Create and configure the NavigationMesh resource.
	var nav_mesh = NavigationMesh.new()
	nav_mesh.cell_size = navmesh_settings.get("cell_size", 0.25)
	nav_mesh.agent_height = navmesh_settings.get("agent_height", 2.0)
	nav_mesh.agent_radius = navmesh_settings.get("agent_radius", 0.5)
	
	# Configure to use Meshes (Visual Geometry)
	nav_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_MESH_INSTANCES
	
	# Check for cost metadata on the first mesh found (to apply global travel cost)
	var first_mesh = _find_first_mesh(scene_root)
	if first_mesh and first_mesh.has_meta("has_nav_cost_data"):
		var travel_cost = navmesh_settings.get("travel_cost", 1.0)
		scene_root.travel_cost = travel_cost
		print_verbose(" -> NavCost data found. Travel cost multiplier set to %f." % travel_cost)

	scene_root.navigation_mesh = nav_mesh
	
	print_verbose(" -> Starting NavMesh bake (Manual Parsing Mode)...")

	var source_geometry_data = NavigationMeshSourceGeometryData3D.new()
	
	# We start traversing from the scene root. The root transform is Identity relative to itself.
	_parse_nodes_recursive(scene_root, Transform3D.IDENTITY, source_geometry_data)
	
	# 2. Bake using the collected data
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry_data)

	print_verbose(" -> NavMesh bake completed.")

	# 3. Cleanup: Remove the source meshes since the data is now baked into the navmesh.
	var meshes_to_free = _collect_mesh_instances(scene_root)
	for mesh in meshes_to_free:
		mesh.queue_free()


# Recursively collects geometry from MeshInstance3D nodes.
# We calculate the accumulated transform manually to simulate "global" positions relative to the root.
func _parse_nodes_recursive(node: Node, parent_accumulated_transform: Transform3D, source_data: NavigationMeshSourceGeometryData3D) -> void:
	var current_transform = parent_accumulated_transform
	
	# If the node has a 3D transform, combine it with the parent's transform
	if node is Node3D:
		current_transform = parent_accumulated_transform * node.transform
		
	# If it's a MeshInstance, add it to the bake data
	if node is MeshInstance3D and node.mesh:
		source_data.add_mesh(node.mesh, current_transform)
	
	# Process children
	for child in node.get_children():
		_parse_nodes_recursive(child, current_transform, source_data)


# Helper to find the first mesh for metadata checking
func _find_first_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D: return node
	for child in node.get_children():
		var res = _find_first_mesh(child)
		if res: return res
	return null

## Recursively collects all MeshInstance3D nodes (before freeing to avoid recursion issues).
func _collect_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for child in node.get_children():
		result.append_array(_collect_mesh_instances(child))
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	return result
