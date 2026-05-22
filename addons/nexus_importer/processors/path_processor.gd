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

	print_verbose(
		"Nexus Path: Converting '%s' to Path3D (%d points, Cyclic: %s)..."
		% [node.name, points_array.size(), str(is_cyclic)]
	)

	var path_node = Path3D.new()
	path_node.name = node.name
	path_node.transform = node.transform
	path_node.curve = _build_curve_from_points(points_array, is_cyclic)
	path_node.set_meta("nexus_cyclic", is_cyclic)

	var owner = node.owner
	node.replace_by(path_node)
	node.queue_free()
	path_node.owner = owner
	return true


func _build_curve_from_points(points_array: Array, is_cyclic: bool) -> Curve3D:
	var curve = Curve3D.new()
	curve.bake_interval = 0.1

	for p_data in points_array:
		_add_curve_point(curve, p_data)

	if is_cyclic and points_array.size() > 0:
		_close_curve_if_needed(curve, points_array)

	return curve


func _add_curve_point(curve: Curve3D, p_data: Array) -> bool:
	if p_data.size() < 10:
		push_warning("Nexus Path: Curve point has %d values, expected 10 - skipped." % p_data.size())
		return false
	var pos = Vector3(p_data[0], p_data[1], p_data[2])
	var in_vec = Vector3(p_data[3], p_data[4], p_data[5])
	var out_vec = Vector3(p_data[6], p_data[7], p_data[8])
	var tilt = p_data[9]
	curve.add_point(pos, in_vec, out_vec)
	curve.set_point_tilt(curve.point_count - 1, tilt)
	return true


func _close_curve_if_needed(curve: Curve3D, points_array: Array) -> void:
	if points_array[0].size() < 3 or points_array[points_array.size() - 1].size() < 3:
		return
	var p_start = Vector3(points_array[0][0], points_array[0][1], points_array[0][2])
	var p_end_data = points_array[points_array.size() - 1]
	var p_end = Vector3(p_end_data[0], p_end_data[1], p_end_data[2])
	if p_start.distance_to(p_end) > 0.001:
		_add_curve_point(curve, points_array[0])
	if "closed" in curve:
		curve.set("closed", true)
