@tool
extends Object

# This function is called for assets with the 'NAVMESH' root type.
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
		print(" -> NavCost data found. Travel cost multiplier set to %f." % travel_cost)

	scene_root.navigation_mesh = nav_mesh
	
	print(" -> Starting NavMesh bake (Manual Parsing Mode)...")

	# 2. MANUAL PARSING (The Fix)
	# Instead of asking Godot to parse the tree (which fails because there is no tree),
	# we manually feed the geometry into the SourceGeometryData container.
	var source_geometry_data = NavigationMeshSourceGeometryData3D.new()
	
	# We start traversing from the scene root. The root transform is Identity relative to itself.
	_parse_nodes_recursive(scene_root, Transform3D.IDENTITY, source_geometry_data)
	
	# 3. Bake using the collected data
	NavigationServer3D.bake_from_source_geometry_data(nav_mesh, source_geometry_data)

	print(" -> NavMesh bake completed.")

	# 4. Cleanup: Remove the source meshes since the data is now baked into the navmesh.
	_free_source_meshes_recursive(scene_root)


# Recursively collects geometry from MeshInstance3D nodes.
# We calculate the accumulated transform manually to simulate "global" positions relative to the root.
func _parse_nodes_recursive(node: Node, parent_accumulated_transform: Transform3D, source_data: NavigationMeshSourceGeometryData3D):
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

# Helper to remove source meshes after baking to prevent double geometry
func _free_source_meshes_recursive(node: Node):
	# We iterate backwards when removing children to be safe
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		_free_source_meshes_recursive(child)
		
	if node is MeshInstance3D:
		node.queue_free()
