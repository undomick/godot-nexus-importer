# file: addons/nexus_importer/processors/root_processor.gd
@tool
extends Object


func apply_script(node: Node, meta: Dictionary) -> bool:
	var script_path = meta.get("script_path", "")
	if not script_path.is_empty() and script_path.begins_with("res://"):
		var script_resource = load(script_path)
		if script_resource is Script:
			node.set_script(script_resource)
			return true
		else:
			push_warning("Nexus Importer: Could not load script at path: " + script_path)
			return false 
	return false 

# Sets physics properties (Layers, Masks, Material)
func set_collision_layers(node: Node, meta: Dictionary):
	# Only PhysicsBody3D (Static, Rigid, Character, Animatable) has collision layers
	if not node is PhysicsBody3D: return
	
	# 1. Layers & Masks
	if meta.has("collision_layer"):
		node.collision_layer = meta.get("collision_layer")
		node.collision_mask = meta.get("collision_mask")
		
	# 2. Physics Material
	# This handles the assignment of .phymat or .tres resources for friction/bounce.
	if meta.has("physics_material_path"):
		var mat_path = meta["physics_material_path"]
		
		# Check if path is valid and resource exists
		if not mat_path.is_empty() and ResourceLoader.exists(mat_path):
			
			# Check if the node actually supports a physics material override.
			# StaticBody3D and RigidBody3D do. CharacterBody3D usually does NOT.
			if "physics_material_override" in node:
				var phys_mat = load(mat_path)
				if phys_mat:
					node.physics_material_override = phys_mat
					print("Nexus Root: Applied Physics Material '%s' to '%s'." % [mat_path.get_file(), node.name])
			else:
				# CharacterBody3D or Area3D logic (if needed in future)
				pass
	
	# 3. Surface Tag Metadata
	# This allows game scripts to do: 
	# var surface = collider.get_meta("surface", "Default")
	if meta.has("physics_surface_name"):
		var surface = meta["physics_surface_name"]
		if not surface.is_empty():
			node.set_meta("surface", surface)
			print("Nexus Root: Set surface tag '%s' on '%s'." % [surface, node.name])
