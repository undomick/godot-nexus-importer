@tool
extends Object

## Converts nexus_curve metadata to Path3D with Curve3D.

func process(node: Node, node_meta: Dictionary, parent: Node) -> bool:
	if not node_meta.has("nexus_curve"):
		return false
		
	var curve_data = node_meta["nexus_curve"]
	var points_array = curve_data.get("points", [])
	var is_cyclic = curve_data.get("is_cyclic", false)
	
	if points_array.size() < 2:
		return false
		
	print_verbose("Nexus Path: Converting '%s' to Path3D (%d points, Cyclic: %s)..." % [node.name, points_array.size(), str(is_cyclic)])
	
	var path_node = Path3D.new()
	path_node.name = node.name
	path_node.transform = node.transform
	
	var curve = Curve3D.new()
	curve.bake_interval = 0.1 
	
	var add_curve_point = func(p_data):
		var pos = Vector3(p_data[0], p_data[1], p_data[2])
		var in_vec = Vector3(p_data[3], p_data[4], p_data[5])
		var out_vec = Vector3(p_data[6], p_data[7], p_data[8])
		var tilt = p_data[9]
		
		curve.add_point(pos, in_vec, out_vec)
		curve.set_point_tilt(curve.point_count - 1, tilt)

	# 1. Add points
	for p_data in points_array:
		add_curve_point.call(p_data)
		
	# 2. Cyclic Logic (Smarter Fix)
	if is_cyclic and points_array.size() > 0:
		# We check the distance between first and last point.
		var p_start = Vector3(points_array[0][0], points_array[0][1], points_array[0][2])
		var p_end_data = points_array[points_array.size() - 1]
		var p_end = Vector3(p_end_data[0], p_end_data[1], p_end_data[2])
		
		# Only close if a gap > 1mm exists.
		# If they are already together (dist ~0), we DO NOT add a point (prevents "Zero length interval").
		if p_start.distance_to(p_end) > 0.001:
			add_curve_point.call(points_array[0])
			
		# Try to set the "Closed" property (compatibility check)
		# Using set_deferred/set to avoid errors if the property doesn't exist.
		if "closed" in curve:
			curve.set("closed", true)
	
	path_node.set_meta("nexus_cyclic", is_cyclic)
	path_node.curve = curve
	
	var owner = node.owner
	node.replace_by(path_node)
	node.queue_free()
	path_node.owner = owner
	
	return true
