@tool
extends Object

## Manifest schema (v2): scene_meta.sources[] with source_asset_id, source_name, transforms, colors.
## Legacy v1: top-level source_asset_id + transforms (normalized to a single sources[] entry).

func process(gltf_path: String, scene_meta: Dictionary) -> Node:
	print_verbose("Nexus Processor: Processing as MultiMesh Manifest...")

	var manifest := _read_manifest(scene_meta)
	if manifest.is_empty():
		push_error("Nexus MultiMesh: Manifest '%s' is missing data." % gltf_path)
		return _stamp_nexus_meta(_create_error_node("Manifest Missing Data"), gltf_path)

	var sources: Array = manifest.get("sources", [])
	if sources.is_empty():
		return _stamp_nexus_meta(_create_error_node("Manifest Missing Data"), gltf_path)

	var composite_root := Node3D.new()
	var manifest_name: String = str(manifest.get("asset_name", ""))
	if manifest_name.is_empty():
		manifest_name = gltf_path.get_file().get_basename()
	composite_root.name = manifest_name
	_stamp_nexus_meta(composite_root, gltf_path)

	var built_sources := 0
	var total_instances := 0
	var total_layers := 0
	var generate_collisions: bool = manifest.get("generate_collisions", false)
	var collision_layer := int(scene_meta.get("collision_layer", 1))
	var collision_mask := int(scene_meta.get("collision_mask", collision_layer))
	var source_errors: PackedStringArray = []

	for source_entry in sources:
		if not source_entry is Dictionary:
			continue
		var build_result := _build_source_multimesh_tree(
			gltf_path,
			source_entry,
			generate_collisions,
			collision_layer,
			collision_mask
		)
		var source_root: Node = build_result.get("root")
		if source_root == null:
			var reason: String = str(build_result.get("error", "Build Failed"))
			source_errors.append("%s: %s" % [source_entry.get("source_name", "?"), reason])
			push_error(
				"Nexus MultiMesh: Source '%s' failed: %s"
				% [source_entry.get("source_name", "?"), reason]
			)
			var error_node := _create_error_node(reason)
			error_node.name = "MULTIMESH_ERROR_%s" % str(source_entry.get("source_name", "Source"))
			composite_root.add_child(error_node)
			continue

		composite_root.add_child(source_root)
		built_sources += 1
		total_instances += int(build_result.get("instance_count", 0))
		total_layers += int(build_result.get("layer_count", 0))

	if built_sources == 0:
		_remove_stale_multimesh_sidecars(gltf_path)
		composite_root.free()
		var detail := ", ".join(source_errors) if not source_errors.is_empty() else "unknown"
		push_error("Nexus MultiMesh: All sources failed for '%s': %s" % [gltf_path.get_file(), detail])
		return _stamp_nexus_meta(_create_error_node("All Sources Failed"), gltf_path)

	var mmi_count := _count_multimesh_instances_recursive(composite_root)
	_assign_import_owner_recursive(composite_root, composite_root)
	print_rich(
		"[color=cyan]Nexus MultiMesh:[/color] %s -> %d sources, %d MMIs"
		% [composite_root.name, built_sources, mmi_count]
	)
	print_verbose(
		"Nexus: %s (MULTIMESH) -> %d source(s), %d instance(s), %d LOD layer(s)"
		% [composite_root.name, built_sources, total_instances, total_layers]
	)
	return composite_root

func _read_manifest(scene_meta: Dictionary) -> Dictionary:
	var generate_collisions: bool = scene_meta.get("generate_collisions", false)
	var asset_name: String = str(scene_meta.get("asset_name", ""))

	if scene_meta.has("sources") and scene_meta["sources"] is Array:
		var sources: Array = []
		for entry in scene_meta["sources"]:
			if not entry is Dictionary:
				continue
			var source_asset_id = entry.get("source_asset_id")
			var transforms = entry.get("transforms")
			if not source_asset_id or not transforms:
				continue
			sources.append(
				{
					"source_asset_id": source_asset_id,
					"source_name": str(entry.get("source_name", source_asset_id)),
					"transforms": transforms,
					"colors": entry.get("colors"),
				}
			)
		if sources.is_empty():
			return {}
		return {
			"sources": sources,
			"generate_collisions": generate_collisions,
			"asset_name": asset_name,
		}

	var source_asset_id = scene_meta.get("source_asset_id")
	var transforms = scene_meta.get("transforms")
	if not source_asset_id or not transforms:
		return {}
	return {
		"sources": [
			{
				"source_asset_id": source_asset_id,
				"source_name": asset_name if not asset_name.is_empty() else str(source_asset_id),
				"transforms": transforms,
				"colors": scene_meta.get("colors"),
			}
		],
		"generate_collisions": generate_collisions,
		"asset_name": asset_name,
	}

func _build_source_multimesh_tree(
	gltf_path: String,
	source_entry: Dictionary,
	generate_collisions: bool,
	collision_layer: int = 1,
	collision_mask: int = 1
) -> Dictionary:
	if NexusImportContext.should_defer_external_scene_loads():
		return {"error": "Source Deferred"}

	var source_asset_id: String = str(source_entry.get("source_asset_id", ""))
	var source_name: String = str(source_entry.get("source_name", source_asset_id))
	var transforms: Array = source_entry.get("transforms", [])
	var colors: Variant = source_entry.get("colors")

	var index_entry := _load_asset_index_entry(source_asset_id)
	if index_entry.is_empty():
		return {"error": "Asset Index Missing"}

	var source_scene_path := _resolve_source_scene_path(index_entry, source_asset_id)
	if source_scene_path.is_empty():
		return {"error": "Source File Missing"}

	var layer_result := _collect_lod_layers(source_scene_path)
	var layers: Array = layer_result.get("layers", [])
	if layers.is_empty():
		var layer_error: String = str(layer_result.get("error", "No Mesh in Source"))
		return {"error": layer_error}

	var root_mmi: MultiMeshInstance3D = null
	var has_shadow_proxy := false
	for layer in layers:
		if layer.get("is_shadow", false):
			has_shadow_proxy = true
			break

	for layer in layers:
		var layer_result_save := _build_multimesh_resource(
			gltf_path,
			source_name,
			layer["mesh"],
			transforms,
			colors,
			layer.get("resource_suffix", "")
		)
		if layer_result_save.is_empty():
			_free_temp_instance(layer_result)
			return {"error": "Res Save Failed"}

		var res_path: String = layer_result_save.get("path", "")
		var multimesh_res: MultiMesh = layer_result_save.get("resource")
		if multimesh_res == null:
			_free_temp_instance(layer_result)
			return {"error": "Res Save Failed"}

		var mmi_node := _create_multimesh_instance(
			source_name,
			multimesh_res,
			res_path,
			layer.get("node_suffix", "")
		)
		if layer.get("is_shadow", false):
			mmi_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		elif has_shadow_proxy:
			mmi_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		if layer.get("lod_level", 0) == 0 and not layer.get("is_shadow", false):
			root_mmi = mmi_node
		elif root_mmi:
			root_mmi.add_child(mmi_node)
		elif root_mmi == null:
			root_mmi = mmi_node

		_apply_visibility_range_from_source(mmi_node, layer.get("visibility_range", {}))

	if root_mmi == null:
		_free_temp_instance(layer_result)
		return {"error": "No Mesh in Source"}

	if generate_collisions:
		_attach_collision_script(
			root_mmi,
			layer_result["temp_instance"],
			true,
			source_scene_path,
			collision_layer,
			collision_mask
		)

	var instance_count := 0
	if root_mmi.multimesh:
		instance_count = root_mmi.multimesh.instance_count

	_free_temp_instance(layer_result)
	return {
		"root": root_mmi,
		"instance_count": instance_count,
		"layer_count": layers.size(),
	}

func _load_asset_index_entry(source_asset_id: String) -> Dictionary:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		if FileAccess.file_exists(NexusPaths.asset_index_path()):
			push_error("Nexus MultiMesh: asset_index.json could not be loaded.")
		else:
			push_error(
				"Nexus MultiMesh: Asset index missing at '%s'." % NexusPaths.asset_index_path()
			)
		return {}
	if not asset_index.has(source_asset_id):
		push_error("Nexus MultiMesh: Source Asset ID '%s' not found." % source_asset_id)
		return {}

	var entry = asset_index[source_asset_id]
	if not entry is Dictionary:
		push_error("Nexus MultiMesh: Invalid index entry for Asset ID '%s'." % source_asset_id)
		return {}
	return entry

func _resolve_source_scene_path(entry: Dictionary, source_asset_id: String) -> String:
	var rel_path = entry.get("relative_path", "")
	var base_gltf_path = NexusUtils.validate_index_path(rel_path)
	if base_gltf_path.is_empty():
		push_error("Nexus MultiMesh: Invalid path in index for Asset ID '%s'." % source_asset_id)
		return ""

	var resolved := NexusSceneUtils.resolve_packed_scene_path(base_gltf_path)
	if resolved.is_empty():
		push_error("Nexus MultiMesh: Source file not found for ID %s." % source_asset_id)
	return resolved

func _collect_lod_layers(source_scene_path: String) -> Dictionary:
	if not ResourceLoader.exists(source_scene_path):
		return {"layers": [], "error": "Source Load Failed"}

	var packed_scene: Resource = ResourceLoader.load(
		source_scene_path, "", ResourceLoader.CACHE_MODE_IGNORE
	)
	if not packed_scene is PackedScene:
		return {"layers": [], "error": "Source Load Failed"}

	var temp_instance = (packed_scene as PackedScene).instantiate()
	var mesh_nodes: Array[MeshInstance3D] = []
	_collect_mesh_instances_recursive(temp_instance, mesh_nodes)
	if mesh_nodes.is_empty():
		temp_instance.free()
		return {"layers": [], "error": "No Mesh in Source"}

	for mesh_node in mesh_nodes:
		if mesh_node.mesh:
			var clean_mesh := NexusMeshSanitize.sanitize_mesh(
				mesh_node.mesh,
				source_scene_path.get_file()
			)
			if clean_mesh == null:
				continue
			# Bake instance overrides onto a mesh copy for MultiMesh (MMI has no per-surface overrides).
			var bake_mesh: Mesh = clean_mesh.duplicate(true)
			_apply_active_materials_to_mesh(mesh_node, bake_mesh)
			mesh_node.mesh = bake_mesh

	var anchor := _find_lod0_anchor(mesh_nodes)
	if anchor == null:
		temp_instance.free()
		return {"layers": [], "error": "No Mesh in Source"}

	var anchor_kind := NexusSceneUtils.classify_lod_mesh_node(anchor)
	var base_name: String = anchor_kind["base_name"]
	var layers: Array = []
	for mesh_node in mesh_nodes:
		var kind := NexusSceneUtils.classify_lod_mesh_node(mesh_node)
		if kind["base_name"] != base_name:
			continue
		layers.append(
			{
				"mesh": mesh_node.mesh,
				"source_mesh_instance": mesh_node,
				"visibility_range": NexusVisibilityRange.read_range_from_mesh_node(mesh_node),
				"lod_level": kind["lod_level"],
				"is_shadow": kind["is_shadow"],
				"resource_suffix": kind["resource_suffix"],
				"node_suffix": kind["node_suffix"],
			}
		)

	if layers.is_empty():
		temp_instance.free()
		return {"layers": [], "error": "No Mesh in Source"}

	layers.sort_custom(_compare_lod_layers)
	return {"layers": layers, "temp_instance": temp_instance}


func _apply_active_materials_to_mesh(mi: MeshInstance3D, mesh: Mesh) -> void:
	if mi == null or mesh == null:
		return
	for i in mesh.get_surface_count():
		var mat: Material = mi.get_active_material(i)
		if mat == null:
			mat = mesh.surface_get_material(i)
		if mat != null:
			mesh.surface_set_material(i, mat)

func _collect_mesh_instances_recursive(node: Node, mesh_nodes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh:
		mesh_nodes.append(node)
	for child in node.get_children():
		_collect_mesh_instances_recursive(child, mesh_nodes)

func _find_lod0_anchor(mesh_nodes: Array[MeshInstance3D]) -> MeshInstance3D:
	for mesh_node in mesh_nodes:
		var kind := NexusSceneUtils.classify_lod_mesh_node(mesh_node)
		if kind["lod_level"] == 0 and not kind["is_shadow"]:
			return mesh_node
	return mesh_nodes[0]

func _compare_lod_layers(a: Dictionary, b: Dictionary) -> bool:
	if a.get("is_shadow", false) != b.get("is_shadow", false):
		return not a.get("is_shadow", false)
	if a.get("lod_level", 0) != b.get("lod_level", 0):
		return a.get("lod_level", 0) < b.get("lod_level", 0)
	return false

func _apply_visibility_range_from_source(target: GeometryInstance3D, range_data: Dictionary) -> void:
	if target is MultiMeshInstance3D:
		var mmi := target as MultiMeshInstance3D
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			return
	NexusVisibilityRange.apply_multimesh_lod_from_dict(target, range_data)

func _build_multimesh_resource(
	gltf_path: String,
	source_name: String,
	source_mesh: Mesh,
	transforms: Array,
	colors: Variant,
	resource_suffix: String
) -> Dictionary:
	var res_stem := gltf_path.get_file().get_basename()
	if not source_name.is_empty():
		res_stem += "_%s" % source_name
	var res_filename = res_stem + ".multimesh%s.res" % resource_suffix
	var res_path = gltf_path.get_base_dir().path_join(res_filename)
	var has_colors = colors != null and colors.size() == transforms.size()

	var multimesh_res := MultiMesh.new()
	multimesh_res.transform_format = MultiMesh.TRANSFORM_3D
	multimesh_res.use_custom_data = false
	var clean_mesh := NexusMeshSanitize.sanitize_mesh(source_mesh, source_name)
	multimesh_res.mesh = clean_mesh.duplicate() if clean_mesh else null
	if multimesh_res.mesh == null:
		push_error("Nexus MultiMesh: Source mesh is missing for '%s'." % source_name)
		return {}

	var valid_transforms: Array[Transform3D] = []
	var valid_colors: Array[Color] = []
	for i in range(transforms.size()):
		var instance_transform := _manifest_transform_to_transform3d(transforms[i], i)
		if instance_transform == null:
			continue
		valid_transforms.append(instance_transform)
		if has_colors:
			valid_colors.append(_manifest_color_at(colors, i))

	if valid_transforms.is_empty():
		push_error("Nexus MultiMesh: No valid instance transforms for '%s'." % source_name)
		return {}

	multimesh_res.use_colors = has_colors
	multimesh_res.instance_count = valid_transforms.size()
	for i in range(valid_transforms.size()):
		multimesh_res.set_instance_transform(i, valid_transforms[i])
		if has_colors:
			multimesh_res.set_instance_color(i, valid_colors[i])

	# Embed a path-less copy in the imported scene; persist a separate duplicate as sidecar.
	var embedded := multimesh_res.duplicate(true)
	embedded.resource_path = ""
	var sidecar := multimesh_res.duplicate(true)

	var res_dir := res_path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(res_dir))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_error("Nexus MultiMesh: Could not create folder for '%s'." % res_filename)
		return {}

	if FileAccess.file_exists(res_path):
		var remove_err := DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))
		if remove_err != OK:
			push_error("Nexus MultiMesh: Could not replace existing '%s'." % res_filename)
			return {}

	var save_err := ResourceSaver.save(sidecar, res_path)
	if save_err != OK:
		push_error(
			"Nexus MultiMesh: Failed to save '%s': %s"
			% [res_filename, error_string(save_err)]
		)
		return {}

	return {"path": res_path, "resource": embedded}

func _manifest_transform_to_transform3d(t_data: Variant, index: int) -> Variant:
	if not t_data is Dictionary:
		push_warning("Nexus MultiMesh: Transform entry %d is not a dictionary - skipped." % index)
		return null
	if not t_data.has("location") or not t_data.has("rotation") or not t_data.has("scale"):
		push_warning("Nexus MultiMesh: Transform entry %d missing location/rotation/scale - skipped." % index)
		return null
	var loc_arr = t_data["location"]
	var rot_arr = t_data["rotation"]
	var scale_arr = t_data["scale"]
	if loc_arr.size() < 3 or rot_arr.size() < 4 or scale_arr.size() < 3:
		push_warning("Nexus MultiMesh: Transform entry %d has invalid array sizes - skipped." % index)
		return null
	var loc := Vector3(loc_arr[0], loc_arr[1], loc_arr[2])
	if not loc.is_finite():
		push_warning("Nexus MultiMesh: Transform entry %d has non-finite location - skipped." % index)
		return null
	var rot := Quaternion(rot_arr[0], rot_arr[1], rot_arr[2], rot_arr[3])
	if not rot.is_finite() or rot.length_squared() < 0.0001:
		rot = Quaternion.IDENTITY
	else:
		rot = rot.normalized()
	var scale := Vector3(scale_arr[0], scale_arr[1], scale_arr[2])
	if not scale.is_finite():
		scale = Vector3.ONE
	for axis in range(3):
		if absf(scale[axis]) < 0.0001:
			scale[axis] = 0.0001
	var basis := Basis(rot).scaled(scale)
	if absf(basis.determinant()) < NexusLightSanitize.MIN_BASIS_DETERMINANT:
		push_warning(
			"Nexus MultiMesh: Transform entry %d has degenerate basis - skipped." % index
		)
		return null
	return Transform3D(basis, loc)

func _manifest_color_at(colors: Variant, index: int) -> Color:
	if colors == null or index < 0 or index >= colors.size():
		push_warning("Nexus MultiMesh: Color entry %d is missing - using white." % index)
		return Color.WHITE
	var c = colors[index]
	if c is Color:
		return c
	if not (c is Array or c is PackedFloat32Array or c is PackedFloat64Array):
		push_warning("Nexus MultiMesh: Color entry %d has invalid type - using white." % index)
		return Color.WHITE
	if c.size() < 3:
		push_warning("Nexus MultiMesh: Color entry %d has fewer than 3 channels - using white." % index)
		return Color.WHITE
	var alpha := 1.0
	if c.size() > 3:
		alpha = float(c[3])
	return Color(float(c[0]), float(c[1]), float(c[2]), alpha)

func _create_multimesh_instance(
	source_name: String,
	multimesh_res: MultiMesh,
	res_path: String,
	node_suffix: String
) -> MultiMeshInstance3D:
	var mmi_node = MultiMeshInstance3D.new()
	mmi_node.name = source_name + node_suffix
	mmi_node.multimesh = multimesh_res
	if not res_path.is_empty():
		mmi_node.set_meta("nexus_multimesh_res_path", res_path)
	return mmi_node

func _attach_collision_script(
	mmi_node: MultiMeshInstance3D,
	source_instance: Node,
	generate_col: bool,
	source_scene_path: String,
	collision_layer: int = 1,
	collision_mask: int = 1
) -> void:
	if not generate_col:
		return
	print_verbose("Nexus MultiMesh: Searching for collision shapes in '%s'..." % source_scene_path)
	var found_shapes: Array[Shape3D] = []
	var found_transforms: Array[Transform3D] = []

	var collect_shapes_recursive = func(node: Node, acc_transform: Transform3D, self_func):
		var current_transform = acc_transform
		if node is Node3D:
			current_transform = acc_transform * node.transform
		if node is CollisionShape3D and node.shape:
			found_shapes.append(node.shape)
			found_transforms.append(current_transform)
		for child in node.get_children():
			self_func.call(child, current_transform, self_func)

	collect_shapes_recursive.call(source_instance, Transform3D.IDENTITY, collect_shapes_recursive)
	if found_shapes.is_empty():
		return

	var script_path = "res://addons/nexus_importer/runtime/multimesh_collider.gd"
	if not ResourceLoader.exists(script_path):
		return
	mmi_node.set_script(load(script_path))
	mmi_node.set("collision_shapes", found_shapes)
	mmi_node.set("shape_transforms", found_transforms)
	mmi_node.set("collision_layer", collision_layer)
	mmi_node.set("collision_mask", collision_mask)
	print_verbose(" -> SUCCESS: Attached runtime script with %d shapes." % found_shapes.size())

func _free_temp_instance(layer_result: Dictionary) -> void:
	var temp_instance = layer_result.get("temp_instance")
	if temp_instance:
		temp_instance.free()

func _count_multimesh_instances_recursive(node: Node) -> int:
	var count := 0
	if node is MultiMeshInstance3D:
		count += 1
	for child in node.get_children():
		count += _count_multimesh_instances_recursive(child)
	return count

func _assign_import_owner_recursive(node: Node, owner_root: Node) -> void:
	for child in node.get_children():
		child.owner = owner_root
		_assign_import_owner_recursive(child, owner_root)

func _remove_stale_multimesh_sidecars(gltf_path: String) -> void:
	for res_path in NexusMultiMeshUtils.multimesh_expected_res_paths(gltf_path):
		if FileAccess.file_exists(res_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))

	var stem := gltf_path.get_file().get_basename()
	var dir := DirAccess.open(gltf_path.get_base_dir())
	if dir == null:
		return
	var prefix := stem + "_"
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if name.begins_with(prefix) and ".multimesh" in name and name.ends_with(".res"):
			var full := gltf_path.get_base_dir().path_join(name)
			if FileAccess.file_exists(full):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
		name = dir.get_next()
	dir.list_dir_end()

# Stamp the Nexus identity meta on the composite (or error composite) that
# replaces the glTF's imported scene, so the inherited-scene builder recognizes
# it as the expected edit root (_is_expected_inherited_edit_root checks
# _nexus_gltf_path / _nexus_export_type). Without this the builder times out
# opening the glTF and the re-queue loop spins forever.
func _stamp_nexus_meta(root: Node, gltf_path: String) -> Node:
	root.set_meta("_nexus_gltf_path", gltf_path)
	root.set_meta("_nexus_export_type", "MULTIMESH_MANIFEST")
	return root

func _create_error_node(reason: String) -> Node3D:
	var root = Node3D.new()
	root.name = "MULTIMESH_ERROR"

	var mesh_inst = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1, 1, 1)
	mesh_inst.mesh = box

	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0, 0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	var label = Label3D.new()
	label.text = "ERROR: " + reason
	label.pixel_size = 0.01
	label.position = Vector3(0, 1.2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	root.add_child(label)

	return root
