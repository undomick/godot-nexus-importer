class_name NexusMeshSanitize
extends RefCounted

## Repair degenerate mesh normals and tangents before Godot rendering/import warnings.

const MIN_VECTOR_LEN_SQ := 0.0001

static var _warned_assets: Dictionary = {}


static func sanitize_mesh(mesh: Mesh, asset_label: String = "") -> Mesh:
	if mesh == null:
		return null

	var analysis := analyze_mesh(mesh)
	if not analysis.get("needs_repair", false):
		return mesh

	var repaired := _repair_mesh(mesh, analysis)
	var label := asset_label if not asset_label.is_empty() else mesh.resource_path.get_file()
	if label.is_empty():
		label = "mesh"
	if not _warned_assets.has(label):
		_warned_assets[label] = true
		push_warning(
			(
				"Nexus Mesh: Repaired degenerate geometry in '%s' "
				+ "(%d normal(s), %d tangent(s) across %d surface(s))."
			)
			% [
				label,
				int(analysis.get("degenerate_normals", 0)),
				int(analysis.get("degenerate_tangents", 0)),
				int(analysis.get("affected_surfaces", 0)),
			]
		)
	return repaired


static func analyze_mesh(mesh: Mesh) -> Dictionary:
	var degenerate_normals := 0
	var degenerate_tangents := 0
	var affected_surfaces := 0
	var surface_flags: Array = []

	for surface_idx in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		var normal_issues := _count_bad_normals(arrays)
		var tangent_issues := _count_bad_tangents(arrays)
		var needs := normal_issues > 0 or tangent_issues > 0
		if needs:
			affected_surfaces += 1
		degenerate_normals += normal_issues
		degenerate_tangents += tangent_issues
		surface_flags.append(needs)

	return {
		"needs_repair": affected_surfaces > 0,
		"degenerate_normals": degenerate_normals,
		"degenerate_tangents": degenerate_tangents,
		"affected_surfaces": affected_surfaces,
		"surface_flags": surface_flags,
	}


static func sanitize_mesh_instance(node: MeshInstance3D, asset_label: String = "") -> void:
	if node == null or not is_instance_valid(node.mesh):
		return
	var label := asset_label
	if label.is_empty():
		label = node.name
	var repaired := sanitize_mesh(node.mesh, label)
	if repaired != node.mesh:
		node.mesh = repaired


static func sanitize_scene_meshes(root: Node, asset_label: String = "") -> void:
	_sanitize_recursive(root, asset_label)


static func _sanitize_recursive(node: Node, asset_label: String) -> void:
	if node is MeshInstance3D:
		var label := asset_label
		if label.is_empty():
			label = node.name
		sanitize_mesh_instance(node as MeshInstance3D, label)
	for child in node.get_children():
		_sanitize_recursive(child, asset_label)


static func _repair_mesh(mesh: Mesh, analysis: Dictionary) -> Mesh:
	var flags: Array = analysis.get("surface_flags", [])
	var out := ArrayMesh.new()

	for surface_idx in range(mesh.get_surface_count()):
		var needs_repair := surface_idx < flags.size() and bool(flags[surface_idx])
		if needs_repair:
			var st := SurfaceTool.new()
			st.create_from(mesh, surface_idx)
			st.generate_normals(true)
			st.generate_tangents()
			st.commit(out)
		else:
			out.add_surface_from_arrays(
				mesh.surface_get_primitive_type(surface_idx),
				mesh.surface_get_arrays(surface_idx)
			)
		var material := mesh.surface_get_material(surface_idx)
		if material != null:
			out.surface_set_material(out.get_surface_count() - 1, material)

	return out


static func sanitize_surface_arrays(arrays: Array, primitive_type: int) -> Array:
	var normal_issues := _count_bad_normals(arrays)
	var tangent_issues := _count_bad_tangents(arrays)
	if normal_issues == 0 and tangent_issues == 0:
		return arrays
	var temp_mesh := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.create_from_arrays(arrays, primitive_type)
	st.generate_normals(true)
	st.generate_tangents()
	st.commit(temp_mesh)
	return temp_mesh.surface_get_arrays(0)


static func _count_bad_normals(arrays: Array) -> int:
	if arrays.size() <= Mesh.ARRAY_NORMAL:
		return 0
	var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
	if not normals is PackedVector3Array:
		return 0
	var count := 0
	for normal in normals:
		if not _vector3_is_valid(normal):
			count += 1
	return count


static func _count_bad_tangents(arrays: Array) -> int:
	if arrays.size() <= Mesh.ARRAY_TANGENT:
		return 0
	var tangents: Variant = arrays[Mesh.ARRAY_TANGENT]
	if not tangents is PackedFloat32Array and not tangents is PackedVector4Array:
		if tangents is Array:
			var count := 0
			for tangent in tangents:
				if tangent is Vector4 and not _tangent_is_valid(tangent):
					count += 1
			return count
		return 0
	if tangents is PackedVector4Array:
		var bad := 0
		for tangent in tangents:
			if not _tangent_is_valid(tangent):
				bad += 1
		return bad
	var bad_packed := 0
	for i in range(0, tangents.size(), 4):
		if i + 3 >= tangents.size():
			break
		var tangent := Vector4(tangents[i], tangents[i + 1], tangents[i + 2], tangents[i + 3])
		if not _tangent_is_valid(tangent):
			bad_packed += 1
	return bad_packed


static func _vector3_is_valid(value: Vector3) -> bool:
	return value.is_finite() and value.length_squared() >= MIN_VECTOR_LEN_SQ


static func _tangent_is_valid(value: Vector4) -> bool:
	var xyz := Vector3(value.x, value.y, value.z)
	return xyz.is_finite() and xyz.length_squared() >= MIN_VECTOR_LEN_SQ and is_finite(value.w)
