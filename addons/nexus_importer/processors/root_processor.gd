@tool
extends Object

## Applies the script from metadata to the node if path is valid.
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

## Sets physics properties (layers, masks, material) and RigidBody settings.
func set_collision_layers(node: Node, meta: Dictionary, stats: Dictionary) -> void:
	# Changed from PhysicsBody3D to CollisionObject3D to support Area3D as well
	if not node is CollisionObject3D: return

	# 1. Collision Layers & Masks
	if meta.has("collision_layer"):
		node.collision_layer = meta.get("collision_layer")
		node.collision_mask = meta.get("collision_mask", node.collision_layer)
	
	# 2. Physics Material (only for PhysicsBody3D; Area3D does not support override)
	if node is PhysicsBody3D and meta.has("physics_material_path"):
		var mat_path = meta["physics_material_path"]
		if not mat_path.is_empty() and ResourceLoader.exists(mat_path):
			if "physics_material_override" in node:
				var phys_mat = load(mat_path)
				if phys_mat:
					node.physics_material_override = phys_mat
					# Save info instead of printing
					stats["physics"] = mat_path.get_file()
	
	# 3. Metadata (nexus_metadata or legacy physics_surface_name)
	var meta_dict: Dictionary = {}
	if meta.has("nexus_metadata"):
		meta_dict = meta["nexus_metadata"].duplicate()
	# Backward compatibility: migrate legacy physics_surface_name
	elif meta.has("physics_surface_name"):
		var surface = meta["physics_surface_name"]
		if not surface.is_empty():
			meta_dict["surface"] = surface
	for key in meta_dict:
		var val = meta_dict[key]
		node.set_meta(key, val)
		if key == "surface":
			stats["surface"] = str(val)

	# 4. RigidBody Specific Settings
	if node is RigidBody3D and meta.has("rigid_body_settings"):
		var rb_settings = meta["rigid_body_settings"]
		
		# Sleeping
		if rb_settings.get("sleeping", false):
			node.sleeping = true
			
		# Lock Rotation
		if rb_settings.get("lock_rotation", false):
			node.lock_rotation = true
			
		# Freeze Logic
		if rb_settings.get("freeze", false):
			node.freeze = true
			
			var mode_str = rb_settings.get("freeze_mode", "STATIC")
			if mode_str == "KINEMATIC":
				node.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			else:
				node.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
				
	# AnimatableBody3D: sync_to_physics from manifest (default: false for keyframe-accurate animation)
	if node is AnimatableBody3D:
		node.sync_to_physics = meta.get("animatable_sync_to_physics", false)
