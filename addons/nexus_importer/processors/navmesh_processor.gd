# file: addons/nexus_importer/processors/navmesh_processor.gd
@tool
extends Object

# This function is called for assets with the 'NAVMESH' root type.
# It finds the source mesh, configures, and bakes the navigation mesh.
func process(scene_root: Node, scene_meta: Dictionary) -> void:
	if scene_meta.get("root_type") != "NAVMESH":
		return

	if not scene_root is NavigationRegion3D:
		push_error("Nexus NavMesh: Root node is not a NavigationRegion3D, cannot bake NavMesh.")
		return
	
	var navmesh_settings = scene_meta.get("navmesh_settings")
	if not navmesh_settings:
		push_warning("Nexus NavMesh: No 'navmesh_settings' found in metadata. Using default values.")
		navmesh_settings = {}
	
	# Find the first MeshInstance3D in the scene, which will be our bake source.
	var mesh_instance = _find_node_of_type(scene_root, "MeshInstance3D")
	if not mesh_instance:
		push_error("Nexus NavMesh: No MeshInstance3D found inside NavigationRegion3D to bake from.")
		return
	
	print("Nexus Processor: Found source mesh '%s' for NavMesh baking." % mesh_instance.name)
	
	# Create and configure a new NavigationMesh resource.
	var nav_mesh = NavigationMesh.new()
	nav_mesh.cell_size = navmesh_settings.get("cell_size", 0.25)
	nav_mesh.agent_height = navmesh_settings.get("agent_height", 2.0)
	nav_mesh.agent_radius = navmesh_settings.get("agent_radius", 0.5)
	
	# Check if the vertex color processor marked this mesh as having cost data.
	if mesh_instance.has_meta("has_nav_cost_data"):
		# Tell the baker to use the geometry of child nodes.
		nav_mesh.source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		
		# Set the travel cost on the region. This triggers Godot to use the vertex colors.
		var travel_cost = navmesh_settings.get("travel_cost", 1.0)
		scene_root.travel_cost = travel_cost
		print(" -> NavCost data found. Travel cost multiplier set to %f." % travel_cost)

	# Assign the resource to the region.
	scene_root.navigation_mesh = nav_mesh
	
	print(" -> Configured NavigationMesh resource. Starting bake...")

	# Start the baking process.
	NavigationServer3D.region_bake_navigation_mesh(nav_mesh, scene_root)

	print(" -> NavMesh bake completed.")

	# Optional but recommended: Remove the visible source mesh after baking.
	mesh_instance.queue_free()


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
