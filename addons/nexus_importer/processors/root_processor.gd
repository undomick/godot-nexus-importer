@tool
extends Object

func set_collision_layers(node: Node, meta: Dictionary, stats: Dictionary) -> void:
	if not node is CollisionObject3D:
		return

	_apply_collision_layers(node, meta)
	_apply_physics_material(node, meta, stats)
	_apply_surface_metadata(node, meta, stats)
	_apply_rigid_body_settings(node, meta)
	_apply_vehicle_body_settings(node, meta)
	if node is AnimatableBody3D:
		node.sync_to_physics = meta.get("animatable_sync_to_physics", false)


func ensure_vehicle_body_root(node: Node, meta: Dictionary) -> Node:
	if meta.get("root_type", "") != "VEHICLE":
		return node
	if node is VehicleBody3D:
		return node
	if not node is RigidBody3D:
		push_warning(
			"Nexus Importer: Expected RigidBody3D root for VEHICLE asset '%s', got %s."
			% [node.name, node.get_class()]
		)
		return node

	var vehicle := VehicleBody3D.new()
	vehicle.name = node.name
	vehicle.transform = node.transform
	var owner = node.owner
	node.replace_by(vehicle)
	node.queue_free()
	vehicle.owner = owner
	return vehicle


func _apply_collision_layers(node: CollisionObject3D, meta: Dictionary) -> void:
	if not meta.has("collision_layer"):
		return
	node.collision_layer = meta.get("collision_layer")
	node.collision_mask = meta.get("collision_mask", node.collision_layer)


func _apply_physics_material(node: Node, meta: Dictionary, stats: Dictionary) -> void:
	if not node is PhysicsBody3D or not meta.has("physics_material_path"):
		return
	var raw_mat_path := str(meta["physics_material_path"])
	var mat_path := NexusUtils.validate_index_path(raw_mat_path)
	if mat_path.is_empty():
		if not raw_mat_path.is_empty():
			push_warning("Nexus Importer: Rejected unsafe physics_material_path '%s'." % raw_mat_path)
		return
	if not ResourceLoader.exists(mat_path):
		return
	if not "physics_material_override" in node:
		return
	var phys_mat = load(mat_path)
	if phys_mat:
		node.physics_material_override = phys_mat
		stats["physics"] = mat_path.get_file()


func _apply_surface_metadata(node: Node, meta: Dictionary, stats: Dictionary) -> void:
	var meta_dict: Dictionary = {}
	if meta.has("nexus_metadata"):
		meta_dict = meta["nexus_metadata"].duplicate()
	elif meta.has("physics_surface_name"):
		var surface = meta["physics_surface_name"]
		if not surface.is_empty():
			meta_dict["surface"] = surface
	for key in meta_dict:
		var val = meta_dict[key]
		node.set_meta(key, val)
		if key == "surface":
			stats["surface"] = str(val)


func _apply_rigid_body_settings(node: Node, meta: Dictionary) -> void:
	if not node is RigidBody3D or not meta.has("rigid_body_settings"):
		return
	var rb_settings = meta["rigid_body_settings"]
	if rb_settings.get("sleeping", false):
		node.sleeping = true
	if rb_settings.get("lock_rotation", false):
		node.lock_rotation = true
	if rb_settings.get("freeze", false):
		node.freeze = true
		var mode_str = rb_settings.get("freeze_mode", "STATIC")
		node.freeze_mode = (
			RigidBody3D.FREEZE_MODE_KINEMATIC
			if mode_str == "KINEMATIC"
			else RigidBody3D.FREEZE_MODE_STATIC
		)


func _apply_vehicle_body_settings(node: Node, meta: Dictionary) -> void:
	if not node is VehicleBody3D or not meta.has("vehicle_body_settings"):
		return
	var settings = meta["vehicle_body_settings"]
	if settings.has("brake"):
		node.brake = float(settings["brake"])
	if settings.has("engine_force"):
		node.engine_force = float(settings["engine_force"])
	if settings.has("steering"):
		node.steering = float(settings["steering"])
	if settings.has("mass"):
		node.mass = float(settings["mass"])
