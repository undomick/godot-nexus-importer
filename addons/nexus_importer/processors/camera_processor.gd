@tool
extends Object

## Applies nexus_camera metadata to Camera3D (perspective/orthographic, focal length, DOF).

func process(node: Node, node_meta: Dictionary) -> bool:
	if not node is Camera3D:
		return false
		
	if not node_meta.has("nexus_camera"):
		return false
		
	var cam_data = node_meta["nexus_camera"]
	
	# 1. Basic Settings
	var keep_aspect = cam_data.get("keep_aspect", 0)
	node.keep_aspect = keep_aspect as Camera3D.KeepAspect
	
	# Clipping Planes (apply to both types)
	node.near = cam_data.get("clip_start", 0.1)
	node.far = cam_data.get("clip_end", 100.0)

	# 2. Projection Mode Switching
	var cam_type = cam_data.get("camera_type", "PERSPECTIVE")
	
	if cam_type == "ORTHOGRAPHIC":
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
	
	# 1. Optics
	# Godot calculates FOV based on Focal Length and Sensor Size (Default 36mm).
	attrs.frustum_focal_length = data.get("focal_length", 50.0)
	
	# Here we synchronize clipping in the attribute as well, as it takes precedence
	attrs.frustum_near = node.near
	attrs.frustum_far = node.far
	
	# 2. Depth of Field & Exposure
	if data.get("dof_enabled", false):
		attrs.frustum_focus_distance = data.get("focus_distance", 10.0)
		attrs.exposure_aperture = data.get("f_stop", 2.8)
		# Enable Auto-Exposure to prevent overexposure at low aperture?
		# attrs.auto_exposure_enabled = true 
	else:
		# If DOF is off, set aperture to default, focus doesn't matter.
		attrs.exposure_aperture = 16.0 # High aperture = everything sharp
	
	print_verbose("Nexus Camera: Updated '%s' (Perspective, Lens: %.1fmm)" % [node.name, attrs.frustum_focal_length])
