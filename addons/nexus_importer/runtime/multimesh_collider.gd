extends MultiMeshInstance3D

## When enabled, shows red wireframe collision shapes at runtime for debugging.
@export var debug_mode: bool = false

## Collision shapes from the source scene (assigned by MultiMesh processor).
@export var collision_shapes: Array[Shape3D] = []

## Local transforms for each collision shape (assigned by MultiMesh processor).
@export var shape_transforms: Array[Transform3D] = []

const DEFAULT_COLLISION_LAYER := 1

# Internal lists for cleanup
var _body_rids: Array[RID] = []
var _debug_nodes: Array[Node3D] = []

func _ready() -> void:
	# Wait for the scene to fully initialize
	await get_tree().process_frame
	
	if collision_shapes.is_empty():
		push_warning("Nexus Collider: No collision shapes found.")
		return

	if not multimesh:
		push_warning("Nexus Collider: No MultiMesh resource assigned.")
		return

	# Cleanup previous debug meshes if script is reloaded
	_clear_debug_meshes()
	
	_generate_bodies()

func _generate_bodies() -> void:
	var ps = PhysicsServer3D
	var world_rid = get_world_3d().space
	var base_transform = global_transform
	var instance_count = multimesh.instance_count

	if debug_mode:
		print("Nexus Collider: Starting generation (Debug Mode: %s)..." % str(debug_mode))
	
	for i in range(instance_count):
		var inst_transform = multimesh.get_instance_transform(i)
		var final_transform = base_transform * inst_transform
		
		# 1. Create Physics Body (Invisible static body)
		var body_rid = ps.body_create()
		ps.body_set_mode(body_rid, PhysicsServer3D.BODY_MODE_STATIC)
		ps.body_set_space(body_rid, world_rid)
		
		# Add all assigned shapes to the body
		for s_index in range(collision_shapes.size()):
			var shape = collision_shapes[s_index]
			
			var local_xform = Transform3D.IDENTITY
			if s_index < shape_transforms.size():
				local_xform = shape_transforms[s_index]
			
			# Add shape to physics server
			ps.body_add_shape(body_rid, shape.get_rid(), local_xform)
			
			# 2. Debug Visualization (Red Wireframe)
			if debug_mode:
				_create_visual_debug_shape(shape, final_transform * local_xform)
		
		# Set final position of the body
		ps.body_set_state(body_rid, PhysicsServer3D.BODY_STATE_TRANSFORM, final_transform)
		
		# Set Collision Layers
		ps.body_set_collision_layer(body_rid, DEFAULT_COLLISION_LAYER)
		ps.body_set_collision_mask(body_rid, DEFAULT_COLLISION_LAYER)

		_body_rids.append(body_rid)

	if debug_mode:
		print("Nexus Collider: Done. Created %d physics bodies." % _body_rids.size())

func _create_visual_debug_shape(shape: Shape3D, global_pos: Transform3D) -> void:
	# Retrieve the debug mesh directly from the Shape3D resource
	var debug_mesh = shape.get_debug_mesh()
	if not debug_mesh:
		return
		
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.mesh = debug_mesh
	
	# Create a bright red, unshaded material
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0) # Red
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	mesh_instance.material_override = mat
	
	# Add to scene tree to make it visible
	add_child(mesh_instance)
	mesh_instance.global_transform = global_pos
	
	_debug_nodes.append(mesh_instance)

func _clear_debug_meshes() -> void:
	for node in _debug_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_debug_nodes.clear()

func _exit_tree() -> void:
	# CLEANUP: Free RIDs from PhysicsServer to prevent memory leaks
	var ps = PhysicsServer3D
	for rid in _body_rids:
		ps.free_rid(rid)
	_body_rids.clear()
	_clear_debug_meshes()
