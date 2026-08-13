class_name NexusSceneCompleteness
extends RefCounted

## Verification-driven completeness for wrapper/inherited .tscn files.
## SSOT for needs_scene_processing, mass-import flush skip, and post-build verify.

const VERIFIED_TTL_FRAMES := 300

# gltf_path -> {frame, ok, gltf_mtime}
static var _verified_cache: Dictionary = {}


static func invalidate(gltf_path: String) -> void:
	if gltf_path.is_empty():
		return
	var key := NexusUtils.dict_find_path_key(_verified_cache, gltf_path)
	if not key.is_empty():
		_verified_cache.erase(key)


static func is_verified_recently(gltf_path: String) -> bool:
	var key := NexusUtils.dict_find_path_key(_verified_cache, gltf_path)
	if key.is_empty():
		return false
	var entry: Dictionary = _verified_cache[key]
	if not bool(entry.get("ok", false)):
		return false
	var age := Engine.get_process_frames() - int(entry.get("frame", 0))
	if age < 0 or age > VERIFIED_TTL_FRAMES:
		return false
	if FileAccess.file_exists(gltf_path):
		var mtime := FileAccess.get_modified_time(gltf_path)
		if mtime != int(entry.get("gltf_mtime", -1)):
			return false
	return true


static func verify_and_mark(gltf_path: String, tscn_path: String) -> bool:
	var ok := scene_is_complete(gltf_path, tscn_path)
	var key := NexusUtils.dict_bind_path(_verified_cache, gltf_path)
	_verified_cache[key] = {
		"frame": Engine.get_process_frames(),
		"ok": ok,
		"gltf_mtime": (
			FileAccess.get_modified_time(gltf_path) if FileAccess.file_exists(gltf_path) else -1
		),
	}
	return ok


static func scene_is_complete(gltf_path: String, tscn_path: String) -> bool:
	if gltf_path.is_empty() or tscn_path.is_empty():
		return false
	if not FileAccess.file_exists(tscn_path) or not ResourceLoader.exists(tscn_path):
		return false

	var packed := ResourceLoader.load(tscn_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		return false
	var root: Node = packed.instantiate()
	if root == null:
		return false

	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	var scene_style := NexusSceneUtils.preferred_scene_style_for_gltf(gltf_path)
	var export_type := str(meta.get("export_type", ""))
	var ok := _root_structure_is_complete(root, gltf_path, meta, scene_style)
	if ok:
		ok = _type_specific_is_complete(root, gltf_path, meta, export_type)
	root.free()
	return ok


static func _root_structure_is_complete(
	root: Node, gltf_path: String, meta: Dictionary, scene_style: String
) -> bool:
	var asset_name := gltf_path.get_file().get_basename()
	var resonance_root: Node = root

	if scene_style == NexusPaths.SCENE_STYLE_WRAPPER:
		var gltf_child := root.get_node_or_null(NodePath(asset_name))
		if gltf_child == null:
			return false
		resonance_root = gltf_child

	var target_script_path := NexusUtils.validate_index_path(str(meta.get("script_path", "")))
	if not target_script_path.is_empty() and ResourceLoader.exists(target_script_path):
		var current_script: Script = root.get_script()
		var current_path := current_script.resource_path if current_script else ""
		if current_path != target_script_path:
			return false

	if scene_style != NexusPaths.SCENE_STYLE_WRAPPER:
		var expected := _expected_resonance_count(gltf_path)
		if expected > 0 and _count_resonance_geometry_children(resonance_root) < expected:
			return false

	return true


static func _type_specific_is_complete(
	root: Node, gltf_path: String, meta: Dictionary, export_type: String
) -> bool:
	if export_type == "MULTIMESH_MANIFEST":
		return NexusMultiMeshUtils.manifest_scene_is_complete(root, meta)
	if NexusExportOrder.is_composition_export_type(export_type):
		return NexusSceneUtils.composition_scene_is_complete(root, meta)
	return NexusSceneUtils.instancing_scene_is_complete(root, meta)


static func _expected_resonance_count(gltf_path: String) -> int:
	if gltf_path.is_empty():
		return 0
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return 0
	var json := JSON.new()
	if json.parse(json_text) != OK:
		return 0
	var gltf = json.get_data()
	if gltf == null:
		return 0
	var count := 0
	var nodes = gltf.get("nodes", [])
	for n in nodes:
		if not n is Dictionary:
			continue
		var extras = n.get("extras", {})
		var node_meta := NexusSceneUtils.nexus_meta_from_extras(extras)
		if node_meta.is_empty():
			continue
		var shape := str(node_meta.get("nexus_mesh_collision_shape", ""))
		if shape in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
			count += 1
	return count


static func _count_resonance_geometry_children(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		var cls := child.get_class()
		if cls == "ResonanceStaticGeometry" or cls == "ResonanceDynamicGeometry":
			count += 1
	return count
