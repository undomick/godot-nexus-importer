@tool
extends Object

## Applies nexus_camera metadata to Camera3D (perspective/orthographic, focal length, DOF).

func process(node: Node, node_meta: Dictionary) -> bool:
	if not node is Camera3D:
		return false
		
	if not node_meta.has("nexus_camera"):
		return false
		
	var cam_data = node_meta["nexus_camera"]

	node.keep_aspect = cam_data.get("keep_aspect", 0) as Camera3D.KeepAspect
	node.near = cam_data.get("clip_start", 0.1)
	node.far = cam_data.get("clip_end", 100.0)

	if cam_data.get("camera_type", "PERSPECTIVE") == "ORTHOGRAPHIC":
		_apply_orthographic(node, cam_data)
	else:
		_apply_perspective_physical(node, cam_data)
		
	return true

func _apply_orthographic(node: Camera3D, data: Dictionary) -> void:
	# Ortho cameras do not need physical lens attributes
	node.projection = Camera3D.PROJECTION_ORTHOGONAL
	node.size = data.get("ortho_size", 10.0)
	node.attributes = null 
	
	print_verbose("Nexus Camera: Updated '%s' (Orthographic, Size: %.2f)" % [node.name, node.size])

func _apply_perspective_physical(node: Camera3D, data: Dictionary) -> void:
	node.projection = Camera3D.PROJECTION_PERSPECTIVE
	
	# We ALWAYS use Physical Attributes for Perspective, 
	# to correctly map Focal Length (Blender Standard).
	var attrs = node.attributes as CameraAttributesPhysical
	if not attrs:
		attrs = CameraAttributesPhysical.new()
		node.attributes = attrs

	attrs.frustum_focal_length = data.get("focal_length", 50.0)
	attrs.frustum_near = node.near
	attrs.frustum_far = node.far

	if data.get("dof_enabled", false):
		attrs.frustum_focus_distance = data.get("focus_distance", 10.0)
		attrs.exposure_aperture = data.get("f_stop", 2.8)
	else:
		attrs.exposure_aperture = 16.0
	
	print_verbose("Nexus Camera: Updated '%s' (Perspective, Lens: %.1fmm)" % [node.name, attrs.frustum_focal_length])
