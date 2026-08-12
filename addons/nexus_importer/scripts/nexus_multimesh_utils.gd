class_name NexusMultiMeshUtils
extends RefCounted

## MultiMesh manifest readiness, pipeline stages, and sidecar probes.


static func is_multimesh_manifest(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	return str(meta.get("export_type", "")) == "MULTIMESH_MANIFEST"


static func collect_multimesh_manifest_source_asset_ids(gltf_path: String) -> Array[String]:
	return NexusSceneUtils.collect_composition_dependency_asset_ids(gltf_path)


static func multimesh_sources_ready(gltf_path: String) -> Dictionary:
	var result := {"ok": false, "reason": "", "missing_sources": PackedStringArray()}
	if not is_multimesh_manifest(gltf_path):
		result.reason = "Not a MultiMesh manifest"
		return result

	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	var sources = meta.get("sources", [])
	if not sources is Array or sources.is_empty():
		result.reason = "Manifest has no sources"
		return result

	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		result.reason = "asset_index.json missing or unreadable"
		return result

	var missing: PackedStringArray = []
	for source_entry in sources:
		if not source_entry is Dictionary:
			continue
		var source_asset_id := str(source_entry.get("source_asset_id", "")).strip_edges()
		var source_name := str(source_entry.get("source_name", source_asset_id))
		if source_asset_id.is_empty():
			missing.append(source_name if not source_name.is_empty() else "?")
			continue
		if not asset_index.has(source_asset_id):
			missing.append(source_name)
			continue
		var entry = asset_index[source_asset_id]
		if not entry is Dictionary:
			missing.append(source_name)
			continue
		var rel_path: String = entry.get("relative_path", "")
		var base_gltf_path := NexusUtils.validate_index_path(rel_path)
		if base_gltf_path.is_empty():
			missing.append(source_name)
			continue
		var source_scene_path := NexusSceneUtils.resolve_packed_scene_path(base_gltf_path)
		if source_scene_path.is_empty() or not ResourceLoader.exists(source_scene_path):
			missing.append(source_name)
			continue
		if not _source_scene_has_mesh_instances(source_scene_path):
			missing.append(source_name)
			continue
		if not _source_scene_materials_ready(source_scene_path, base_gltf_path):
			missing.append(source_name)

	if not missing.is_empty():
		result.missing_sources = missing
		result.reason = "Source assets not ready: %s" % ", ".join(missing)
		return result

	result.ok = true
	return result


static func multimesh_import_ready(gltf_path: String) -> Dictionary:
	var result := {"ok": false, "reason": "", "missing_sources": PackedStringArray()}
	if not is_multimesh_manifest(gltf_path):
		result.reason = "Not a MultiMesh manifest"
		return result
	if not FileAccess.file_exists(gltf_path):
		result.reason = "glTF file missing"
		return result
	if NexusSceneUtils.nexus_import_config_needs_fix(gltf_path):
		result.reason = "Import config needs fix"
		return result

	var sources_ready := multimesh_sources_ready(gltf_path)
	if not sources_ready.get("ok", false):
		result.reason = str(sources_ready.get("reason", "Sources not ready"))
		result.missing_sources = sources_ready.get("missing_sources", PackedStringArray())
		return result

	if multimesh_gltf_has_multimesh_instances(gltf_path):
		result.ok = true
		return result

	result.reason = "Imported glTF has no MultiMeshInstance3D nodes"
	return result


const MULTIMESH_STAGE_SOURCES := "SOURCES"
const MULTIMESH_STAGE_MANIFEST := "MANIFEST"
const MULTIMESH_STAGE_INHERITED := "INHERITED"
const MULTIMESH_STAGE_DONE := "DONE"

static var _pipeline_stage_cache: Dictionary = {}
static var _mmi_probe_cache: Dictionary = {}


static func invalidate_multimesh_pipeline_cache(gltf_path: String = "") -> void:
	if gltf_path.is_empty():
		_pipeline_stage_cache.clear()
		_mmi_probe_cache.clear()
	else:
		_pipeline_stage_cache.erase(gltf_path)
		_mmi_probe_cache.erase(gltf_path)


static func multimesh_pipeline_stage_throttled(gltf_path: String, throttle_ms: int = 1000) -> Dictionary:
	if NexusImportContext.is_multimesh_post_import_active():
		return {
			"stage": MULTIMESH_STAGE_MANIFEST,
			"reason": "MultiMesh post-import in progress",
		}
	var now := Time.get_ticks_msec()
	if _pipeline_stage_cache.has(gltf_path):
		var entry: Dictionary = _pipeline_stage_cache[gltf_path]
		if now - int(entry.get("at_ms", 0)) < throttle_ms:
			return entry.get("result", {"stage": "", "reason": ""})
	var result := multimesh_pipeline_stage(gltf_path)
	_pipeline_stage_cache[gltf_path] = {"at_ms": now, "result": result}
	return result


static func multimesh_pipeline_stage(gltf_path: String) -> Dictionary:
	var result := {"stage": "", "reason": ""}
	if not is_multimesh_manifest(gltf_path):
		result.stage = MULTIMESH_STAGE_SOURCES
		result.reason = "Not a MultiMesh manifest"
		return result
	if not FileAccess.file_exists(gltf_path):
		result.stage = MULTIMESH_STAGE_SOURCES
		result.reason = "glTF file missing"
		return result
	if NexusSceneUtils.nexus_import_config_needs_fix(gltf_path):
		result.stage = MULTIMESH_STAGE_MANIFEST
		result.reason = "Import config needs fix"
		return result

	var sources_ready := multimesh_sources_ready(gltf_path)
	if not sources_ready.get("ok", false):
		result.stage = MULTIMESH_STAGE_SOURCES
		result.reason = str(sources_ready.get("reason", "Sources not ready"))
		return result

	var cache_has_mmi := multimesh_gltf_has_multimesh_instances(gltf_path)
	var sidecars_ready := multimesh_sidecar_resources_ready(gltf_path)
	if not cache_has_mmi or not sidecars_ready:
		var parts: PackedStringArray = []
		if not cache_has_mmi:
			parts.append("import cache has no MultiMeshInstance3D nodes")
		if not sidecars_ready:
			parts.append("sidecar .multimesh.res files missing")
		result.stage = MULTIMESH_STAGE_MANIFEST
		result.reason = ", ".join(parts)
		return result

	var tscn_path := NexusPaths.scene_path_for(gltf_path, NexusSceneUtils.preferred_scene_style_for_gltf(gltf_path))
	if not FileAccess.file_exists(tscn_path):
		result.stage = MULTIMESH_STAGE_INHERITED
		result.reason = "Packed scene missing: %s" % tscn_path.get_file()
		return result

	result.stage = MULTIMESH_STAGE_DONE
	result.reason = "Pipeline complete"
	return result


static func multimesh_pipeline_log_status(gltf_path: String) -> void:
	var status := multimesh_pipeline_stage(gltf_path)
	print_rich(
		"[color=cyan]Nexus MultiMesh:[/color] %s stage=%s (%s)"
		% [gltf_path.get_file(), str(status.get("stage", "?")), str(status.get("reason", ""))]
	)


static func multimesh_manifest_import_complete(gltf_path: String) -> bool:
	if not multimesh_sources_ready(gltf_path).get("ok", false):
		return false
	return (
		multimesh_gltf_has_multimesh_instances(gltf_path)
		and multimesh_sidecar_resources_ready(gltf_path)
	)


static func multimesh_can_queue_inherited_scene(gltf_path: String) -> bool:
	var stage: String = str(multimesh_pipeline_stage(gltf_path).get("stage", ""))
	return stage == MULTIMESH_STAGE_INHERITED


static func multimesh_sidecar_resources_ready(gltf_path: String) -> bool:
	if not is_multimesh_manifest(gltf_path):
		return false

	var pending_count := _count_pending_multimesh_sidecars(gltf_path)
	if pending_count > 0:
		return false

	var expected := multimesh_expected_res_paths(gltf_path)
	if not expected.is_empty():
		for res_path in expected:
			if not FileAccess.file_exists(res_path):
				return false
		return true

	var stem := gltf_path.get_file().get_basename()
	var dir := DirAccess.open(gltf_path.get_base_dir())
	if dir == null:
		return false
	var prefix := stem + "_"
	var found := false
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if name.begins_with(prefix) and ".multimesh" in name and name.ends_with(".res"):
			if name.ends_with(".pending.res"):
				name = dir.get_next()
				continue
			found = true
			break
		name = dir.get_next()
	dir.list_dir_end()
	return found


static func _count_pending_multimesh_sidecars(gltf_path: String) -> int:
	var stem := gltf_path.get_file().get_basename()
	var dir := DirAccess.open(gltf_path.get_base_dir())
	if dir == null:
		return 0
	var prefix := stem + "_"
	var count := 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if name.begins_with(prefix) and ".multimesh" in name and name.ends_with(".pending.res"):
			count += 1
		name = dir.get_next()
	dir.list_dir_end()
	return count


static func multimesh_expected_res_paths(gltf_path: String) -> Array[String]:
	var paths: Array[String] = []
	if not is_multimesh_manifest(gltf_path):
		return paths

	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	var sources = meta.get("sources", [])
	if not sources is Array:
		return paths

	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	var res_stem_base := gltf_path.get_file().get_basename()
	var manifest_dir := gltf_path.get_base_dir()

	for source_entry in sources:
		if not source_entry is Dictionary:
			continue
		var source_asset_id := str(source_entry.get("source_asset_id", "")).strip_edges()
		var source_name := str(source_entry.get("source_name", source_asset_id))
		if source_asset_id.is_empty() or not asset_index.has(source_asset_id):
			continue
		var entry = asset_index[source_asset_id]
		if not entry is Dictionary:
			continue
		var base_gltf_path := NexusUtils.validate_index_path(str(entry.get("relative_path", "")))
		if base_gltf_path.is_empty():
			continue
		var source_scene_path := NexusSceneUtils.resolve_packed_scene_path(base_gltf_path)
		if source_scene_path.is_empty():
			continue
		var suffixes := _probe_source_lod_resource_suffixes(source_scene_path)
		var res_stem := res_stem_base
		if not source_name.is_empty():
			res_stem += "_%s" % source_name
		for suffix in suffixes:
			paths.append(manifest_dir.path_join(res_stem + ".multimesh%s.res" % suffix))
	return paths


static func _load_packed_scene(scene_path: String) -> PackedScene:
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return null
	var resource: Resource = ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource is PackedScene:
		return resource
	return null


static func _instantiate_packed_scene(scene_path: String) -> Node:
	var packed: PackedScene = _load_packed_scene(scene_path)
	if packed == null:
		return null
	return packed.instantiate()


static func multimesh_gltf_has_multimesh_instances(gltf_path: String) -> bool:
	if not ResourceLoader.exists(gltf_path):
		return false
	if NexusImportContext.is_multimesh_post_import_active():
		return multimesh_sidecar_resources_ready(gltf_path)
	var stamp := _gltf_import_timestamp(gltf_path)
	if _mmi_probe_cache.has(gltf_path):
		var cached: Dictionary = _mmi_probe_cache[gltf_path]
		if int(cached.get("stamp", -1)) == stamp:
			return bool(cached.get("found", false))
	var found := _probe_gltf_import_for_mmi(gltf_path)
	_mmi_probe_cache[gltf_path] = {"stamp": stamp, "found": found}
	return found


static func _gltf_import_timestamp(gltf_path: String) -> int:
	var import_path := gltf_path + ".import"
	if FileAccess.file_exists(import_path):
		return FileAccess.get_modified_time(import_path)
	return 0


static func _probe_gltf_import_for_mmi(gltf_path: String) -> bool:
	var inst: Node = _instantiate_packed_scene(gltf_path)
	if inst == null:
		return false
	var found := _find_multimesh_instance_recursive(inst) != null
	inst.free()
	return found


static func _find_multimesh_instance_recursive(node: Node) -> MultiMeshInstance3D:
	if node is MultiMeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_multimesh_instance_recursive(child)
		if found:
			return found
	return null


static func manifest_scene_is_complete(root: Node, _scene_meta: Dictionary) -> bool:
	if root == null:
		return false
	if str(root.name).begins_with("MULTIMESH_ERROR"):
		return false
	return _find_multimesh_instance_recursive(root) != null


static func _source_scene_has_mesh_instances(source_scene_path: String) -> bool:
	var inst: Node = _instantiate_packed_scene(source_scene_path)
	if inst == null:
		return false
	var found := _find_mesh_instance_with_mesh_recursive(inst) != null
	inst.free()
	return found


static func _source_scene_materials_ready(
	source_scene_path: String, source_gltf_path: String = ""
) -> bool:
	## True when surfaces have materials; Nexus pipeline requires external .tres/.material (swap done).
	var inst: Node = _instantiate_packed_scene(source_scene_path)
	if inst == null:
		return false
	var mesh_nodes: Array[MeshInstance3D] = []
	_collect_mesh_instances_for_probe(inst, mesh_nodes)
	if mesh_nodes.is_empty():
		inst.free()
		return false
	var meta_path := source_gltf_path if not source_gltf_path.is_empty() else source_scene_path
	var scene_meta := NexusUtils.get_nexus_metadata(meta_path)
	var require_external_tres := NexusUtils.should_swap_nexus_materials(scene_meta)
	for mi in mesh_nodes:
		if not _mesh_instance_materials_ready(mi, require_external_tres):
			inst.free()
			return false
	inst.free()
	return true


static func _mesh_instance_materials_ready(mi: MeshInstance3D, require_external_tres: bool) -> bool:
	if mi == null or mi.mesh == null:
		return false
	var surface_count := mi.mesh.get_surface_count()
	if surface_count <= 0:
		return false
	for i in surface_count:
		var mat: Material = mi.get_active_material(i)
		if mat == null:
			mat = mi.mesh.surface_get_material(i)
		if mat == null:
			return false
		var needs_tres := require_external_tres or _material_has_nexus_id(mat)
		if needs_tres and not _material_has_external_tres(mat):
			return false
	return true


static func _material_has_nexus_id(mat: Material) -> bool:
	if mat == null or not mat.has_meta("extras"):
		return false
	var extras = mat.get_meta("extras")
	if not extras is Dictionary:
		return false
	return not str(extras.get(NexusSceneUtils.NEXUS_MATERIAL_ID_KEY, "")).strip_edges().is_empty()


static func _material_has_external_tres(mat: Material) -> bool:
	if mat == null:
		return false
	var path := str(mat.resource_path).strip_edges()
	if path.is_empty():
		return false
	var ext := path.get_extension().to_lower()
	if ext != "tres" and ext != "material":
		return false
	return ResourceLoader.exists(path) or FileAccess.file_exists(path)


static func _find_mesh_instance_with_mesh_recursive(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and node.mesh:
		return node
	for child in node.get_children():
		var found := _find_mesh_instance_with_mesh_recursive(child)
		if found:
			return found
	return null


static func _probe_source_lod_resource_suffixes(source_scene_path: String) -> Array[String]:
	var suffixes: Array[String] = []
	var inst: Node = _instantiate_packed_scene(source_scene_path)
	if inst == null:
		return suffixes
	var mesh_nodes: Array[MeshInstance3D] = []
	_collect_mesh_instances_for_probe(inst, mesh_nodes)
	if mesh_nodes.is_empty():
		inst.free()
		return suffixes
	var anchor := _find_lod0_anchor_for_probe(mesh_nodes)
	if anchor == null:
		inst.free()
		return suffixes
	var anchor_kind := NexusSceneUtils.classify_lod_mesh_node(anchor)
	var base_name: String = anchor_kind["base_name"]
	var seen: Dictionary = {}
	for mesh_node in mesh_nodes:
		var kind := NexusSceneUtils.classify_lod_mesh_node(mesh_node)
		if kind["base_name"] != base_name:
			continue
		var suffix: String = kind["resource_suffix"]
		if seen.has(suffix):
			continue
		seen[suffix] = true
		suffixes.append(suffix)
	inst.free()
	suffixes.sort()
	return suffixes


static func _collect_mesh_instances_for_probe(node: Node, mesh_nodes: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh:
		mesh_nodes.append(node)
	for child in node.get_children():
		_collect_mesh_instances_for_probe(child, mesh_nodes)


static func _find_lod0_anchor_for_probe(mesh_nodes: Array[MeshInstance3D]) -> MeshInstance3D:
	for mesh_node in mesh_nodes:
		var kind := NexusSceneUtils.classify_lod_mesh_node(mesh_node)
		if kind["lod_level"] == 0 and not kind["is_shadow"]:
			return mesh_node
	return mesh_nodes[0] if not mesh_nodes.is_empty() else null
