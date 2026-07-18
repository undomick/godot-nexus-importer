@tool
extends Object

## Creates ResonanceGeometry from nexus_mesh_collision_shape. Saves mesh sidecars to .res and
## optionally removes the glTF MeshInstance3D when discard_mesh is set. ResonanceGeometry nodes
## are attached when building wrapper or inherited scenes from nexus_resonance_nodes metadata.

func process(node: Node, node_meta: Dictionary, scene_meta: Dictionary, root: Node, stats: Dictionary) -> bool:
	var shape_type = node_meta.get("nexus_mesh_collision_shape", "")
	if shape_type not in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
		return false

	if not node is MeshInstance3D or not node.mesh:
		return false

	var parent = node.get_parent()
	if not parent:
		return false

	var discard_mesh = node_meta.get("discard_mesh", false) or node_meta.get("nexus_discard_mesh", false)
	var raw_material_path := str(node_meta.get("nexus_resonance_material_path", ""))
	var material_path := NexusUtils.validate_index_path(raw_material_path)
	if not raw_material_path.is_empty() and material_path.is_empty():
		push_warning(
			"Nexus Resonance: Rejected unsafe material path '%s' on '%s'."
			% [raw_material_path, node.name]
		)
	# Sidecar mesh for ResonanceGeometry; drop the glTF MeshInstance3D only when explicitly requested.
	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	if gltf_path.is_empty():
		push_warning("Nexus Resonance: No _nexus_gltf_path on root - cannot save mesh sidecar.")
		return false

	var mesh_ref = node.mesh
	var node_name_for_resonance: String = node.name
	var gltf_dir = gltf_path.get_base_dir()
	var gltf_basename = gltf_path.get_file().get_basename()
	# Avoid duplication: if node.name is "SM_Door_reso", use "reso" as short part
	var short_name: String = node.name
	if node.name.begins_with(gltf_basename + "_"):
		short_name = node.name.substr((gltf_basename + "_").length())
	var base_file = gltf_basename + "_" + NexusUtils.sanitize_node_name(short_name)

	const RID_PATH_META := "nexus_resonance_mesh_rid_to_path"
	var mesh_rid: RID = mesh_ref.get_rid()
	var rid_valid: bool = mesh_rid.is_valid()
	var rid_key: String = str(mesh_rid) if rid_valid else ""
	var rid_to_path: Dictionary = root.get_meta(RID_PATH_META, {})

	var mesh_path: String
	if rid_valid and rid_to_path.has(rid_key):
		mesh_path = rid_to_path[rid_key]
	else:
		# Use deterministic path and overwrite on reimport. idx / RID suffix for same-name, different-mesh collisions.
		var paths_used: Array = root.get_meta("nexus_resonance_paths_used", [])
		var mesh_file = base_file + ".res"
		mesh_path = NexusUtils.ensure_res_path(gltf_dir.path_join(mesh_file))
		var idx = 0
		while mesh_path in paths_used:
			idx += 1
			if idx == 1:
				var rid_hex := _mesh_rid_file_suffix(mesh_ref.get_rid())
				mesh_file = base_file + "_m" + rid_hex + ".res"
			else:
				mesh_file = base_file + "_" + str(idx) + ".res"
			mesh_path = NexusUtils.ensure_res_path(gltf_dir.path_join(mesh_file))
		paths_used.append(mesh_path)
		root.set_meta("nexus_resonance_paths_used", paths_used)

		var save_err = ResourceSaver.save(mesh_ref, mesh_path)
		if save_err != OK:
			push_error("Nexus Resonance: Failed to save mesh sidecar '%s': %s" % [mesh_path, error_string(save_err)])
			return false

		if rid_valid:
			rid_to_path[rid_key] = mesh_path
			root.set_meta(RID_PATH_META, rid_to_path)

	var transform_rel = _get_transform_relative_to_root(root, node)
	var transform_str = var_to_str(transform_rel)

	if discard_mesh:
		parent.remove_child(node)
		node.free()

	var nodes_array: Array = root.get_meta("nexus_resonance_nodes", [])
	nodes_array.append({
		"mesh_path": mesh_path,
		"transform_str": transform_str,
		"node_name": node_name_for_resonance,
		"material_path": material_path,
		"type": shape_type,
		"discard_mesh": discard_mesh
	})
	root.set_meta("nexus_resonance_nodes", nodes_array)
	if stats.has("resonance"):
		stats.resonance += 1
	return true


## Computes node's transform relative to root by walking the parent chain.
## Works during import when nodes may not be in the scene tree (is_inside_tree() false).
func _get_transform_relative_to_root(root: Node, node: Node) -> Transform3D:
	var t = node.transform
	var p = node.get_parent()
	while p and p != root:
		t = p.transform * t
		p = p.get_parent()
	return t


## Up to 8 hex chars from RID for stable sidecar names when the base filename collides (different meshes).
func _mesh_rid_file_suffix(rid: RID) -> String:
	if not rid.is_valid():
		return "0"
	var h := String.num_uint64(rid.get_id(), 16)
	if h.length() > 8:
		return h.substr(h.length() - 8, 8)
	return h
