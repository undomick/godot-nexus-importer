class_name NexusVisibilityRange
extends RefCounted

## Sanitize and apply Godot visibility_range for LOD meshes and MultiMesh LOD layers.

const MIN_RANGE_GAP := 0.001


static func sanitize_dict(range_data: Dictionary) -> Dictionary:
	var begin := float(range_data.get("begin", 0.0))
	var begin_margin := maxf(float(range_data.get("begin_margin", 0.0)), 0.0)
	var end := float(range_data.get("end", 0.0))
	var end_margin := maxf(float(range_data.get("end_margin", 0.0)), 0.0)

	if not is_finite(begin):
		begin = 0.0
	if not is_finite(begin_margin):
		begin_margin = 0.0
	if not is_finite(end):
		end = 0.0
	if not is_finite(end_margin):
		end_margin = 0.0

	if end > 0.0 and begin > end:
		begin = end

	if end > 0.0:
		var fade_begin := begin + begin_margin
		var fade_end := end - end_margin
		if fade_begin > fade_end:
			var overlap := fade_begin - fade_end + MIN_RANGE_GAP
			begin_margin = maxf(begin_margin - overlap * 0.5, 0.0)
			end_margin = maxf(end_margin - overlap * 0.5, 0.0)

	return {
		"begin": begin,
		"begin_margin": begin_margin,
		"end": end,
		"end_margin": end_margin,
	}


static func apply_mesh_lod(node: GeometryInstance3D, range_data: Dictionary) -> void:
	_apply_fade_lod(node, range_data)


static func apply_multimesh_lod_from_dict(node: GeometryInstance3D, range_data: Dictionary) -> void:
	_apply_fade_lod(node, range_data)


static func _apply_fade_lod(node: GeometryInstance3D, range_data: Dictionary) -> void:
	var values := sanitize_dict(range_data)
	node.visibility_range_begin = values["begin"]
	node.visibility_range_begin_margin = values["begin_margin"]
	node.visibility_range_end = values["end"]
	node.visibility_range_end_margin = values["end_margin"]
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


static func read_range_from_mesh_node(mesh_node: MeshInstance3D) -> Dictionary:
	if mesh_node.has_meta("extras"):
		var extras = mesh_node.get_meta("extras")
		if extras is Dictionary and extras.has("nexus_visibility_range"):
			var range_data = extras["nexus_visibility_range"]
			if range_data is Dictionary:
				return sanitize_dict(range_data)
	return sanitize_dict(
		{
			"begin": mesh_node.visibility_range_begin,
			"begin_margin": mesh_node.visibility_range_begin_margin,
			"end": mesh_node.visibility_range_end,
			"end_margin": mesh_node.visibility_range_end_margin,
		}
	)
