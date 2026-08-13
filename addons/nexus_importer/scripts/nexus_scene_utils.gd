class_name NexusSceneUtils
extends RefCounted

## Tree walks and filesystem helpers shared by import processors and editor tools.

const NEXUS_NODE_META := "NEXUS_NODE_METADATA"
const NEXUS_MATERIAL_ID_KEY := "nexus_material_id"


static func get_node_nexus_meta(node: Node) -> Dictionary:
	if node == null or not node.has_meta("extras"):
		return {}
	return nexus_meta_from_extras(node.get_meta("extras"))


static func nexus_meta_from_extras(extras) -> Dictionary:
	if not extras is Dictionary:
		return {}
	var node_meta = extras.get(NEXUS_NODE_META, {})
	if not node_meta is Dictionary:
		return {}
	return node_meta


static func marker_uuid_from_node(node: Node) -> String:
	return str(get_node_nexus_meta(node).get("uuid", "")).strip_edges()


static func marker_asset_id_from_node(node: Node) -> String:
	return str(get_node_nexus_meta(node).get("nexus_asset_id", "")).strip_edges()


static var _lod_name_regex: RegEx


static func _get_lod_name_regex() -> RegEx:
	if _lod_name_regex == null:
		_lod_name_regex = RegEx.new()
		_lod_name_regex.compile("^(.*)_LOD(\\d+)$")
	return _lod_name_regex


## Classify LOD / shadow mesh naming. Keys: base_name, lod_level, is_shadow, node_suffix, resource_suffix.
static func classify_lod_mesh_node(node: Node) -> Dictionary:
	var is_shadow_meta := get_node_nexus_meta(node).get("nexus_is_shadow_proxy", false)
	return classify_lod_node_name(str(node.name), is_shadow_meta)


static func classify_lod_node_name(node_name: String, is_shadow_proxy: bool = false) -> Dictionary:
	var is_shadow := false
	var lod_level := 0
	var node_suffix := ""
	var resource_suffix := ""
	var base_name := node_name

	if is_shadow_proxy or node_name.ends_with("_Shadow"):
		is_shadow = true
		node_suffix = "_Shadow"
		resource_suffix = "_shadow"
		base_name = node_name.trim_suffix("_Shadow").trim_suffix("_LOD0")
	else:
		var lod_match := _get_lod_name_regex().search(node_name)
		if lod_match:
			base_name = lod_match.get_string(1)
			lod_level = int(lod_match.get_string(2))
			if lod_level > 0:
				node_suffix = "_LOD%d" % lod_level
				resource_suffix = "_lod%d" % lod_level
		elif node_name.ends_with("_LOD0"):
			base_name = node_name.trim_suffix("_LOD0")
			lod_level = 0

	return {
		"base_name": base_name,
		"lod_level": lod_level,
		"is_shadow": is_shadow,
		"node_suffix": node_suffix,
		"resource_suffix": resource_suffix,
	}


static func reroll_duplicate_uuid_markers(root: Node) -> void:
	if root == null:
		return
	var seen: Dictionary = {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		_reroll_marker_uuid_if_duplicate(node, seen)


static func _reroll_marker_uuid_if_duplicate(node: Node, seen: Dictionary) -> void:
	var uuid_val := marker_uuid_from_node(node)
	if uuid_val.is_empty():
		return
	if not seen.has(uuid_val):
		seen[uuid_val] = node
		return

	var keeper: Node = seen[uuid_val]
	var node_asset := marker_asset_id_from_node(node)
	var keeper_asset := marker_asset_id_from_node(keeper)

	# The marker carrying the nexus_asset_id is the authoritative keeper. If the
	# previously seen node lacks an asset_id but the current one has it, swap:
	# keep the current node's uuid and reroll the previously seen node instead.
	# This makes the outcome independent of tree traversal order.
	if not node_asset.is_empty() and keeper_asset.is_empty():
		seen[uuid_val] = node
		_set_marker_asset_id_on_node(keeper, node_asset)
		var swapped_uuid := _generate_unique_marker_uuid(seen)
		_set_marker_uuid_on_node(keeper, swapped_uuid)
		seen[swapped_uuid] = keeper
		return

	if node_asset.is_empty() and not keeper_asset.is_empty():
		_set_marker_asset_id_on_node(node, keeper_asset)

	var new_uuid := _generate_unique_marker_uuid(seen)
	_set_marker_uuid_on_node(node, new_uuid)
	seen[new_uuid] = node


static func _generate_unique_marker_uuid(taken: Dictionary) -> String:
	var candidate := ""
	while candidate.is_empty() or taken.has(candidate):
		candidate = "obj_%d_%d" % [Time.get_ticks_usec(), randi()]
	return candidate


static func _set_marker_uuid_on_node(node: Node, new_uuid: String) -> void:
	if not node.has_meta("extras"):
		return
	var extras = node.get_meta("extras")
	if not extras is Dictionary:
		return
	var node_meta = extras.get(NEXUS_NODE_META, {})
	if not node_meta is Dictionary:
		node_meta = {}
	else:
		node_meta = node_meta.duplicate(true)
	node_meta["uuid"] = new_uuid
	extras[NEXUS_NODE_META] = node_meta
	node.set_meta("extras", extras)


static func _set_marker_asset_id_on_node(node: Node, asset_id: String) -> void:
	if asset_id.is_empty() or not node.has_meta("extras"):
		return
	var extras = node.get_meta("extras")
	if not extras is Dictionary:
		return
	var node_meta = extras.get(NEXUS_NODE_META, {})
	if not node_meta is Dictionary:
		node_meta = {}
	else:
		node_meta = node_meta.duplicate(true)
	node_meta["nexus_asset_id"] = asset_id
	extras[NEXUS_NODE_META] = node_meta
	node.set_meta("extras", extras)


static func instantiate_scene_reference(scene_path: String) -> Node:
	## Instantiate a PackedScene while preserving the external scene link (not a baked copy).
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return null
	var packed_scene = load(scene_path)
	if not packed_scene is PackedScene:
		return null
	var instance: Node = packed_scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	if instance == null:
		return null
	instance.scene_file_path = scene_path
	return instance


static func find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root
	for child in root.get_children():
		var found = find_animation_player(child)
		if found:
			return found
	return null


static func find_first_node_of_type(root: Node, class_type: StringName) -> Node:
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.is_class(class_type):
			return current
		for child in current.get_children():
			queue.push_back(child)
	return null


static func collect_files_with_extensions(folder_path: String, extensions: Array) -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(folder_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = folder_path.path_join(name)
		if dir.current_is_dir():
			result.append_array(collect_files_with_extensions(full, extensions))
		else:
			var ext = name.get_extension().to_lower()
			if ext in extensions:
				result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result


static func collect_gltfs_recursive(folder_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(folder_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = folder_path.path_join(name)
		if dir.current_is_dir():
			result.append_array(collect_gltfs_recursive(full))
		elif NexusUtils.is_gltf_container_path(full):
			result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result


static func nexus_root_type_to_class_name(nexus_type: String) -> String:
	# VehicleBody3D is not supported by the glTF importer; post-import replaces RigidBody3D.
	if nexus_type == "VEHICLE":
		return "RigidBody3D"
	var map := {
		"NODE_3D": "Node3D",
		"STATIC": "StaticBody3D",
		"RIGID": "RigidBody3D",
		"AREA": "Area3D",
		"CHARACTER_BODY": "CharacterBody3D",
		"NAVMESH": "NavigationRegion3D",
		"ANIMATABLE": "AnimatableBody3D",
	}
	return map.get(nexus_type, "Node3D")


static func create_node_for_nexus_root_type(nexus_type: String) -> Node:
	return ClassDB.instantiate(nexus_root_type_to_class_name(nexus_type))


static func should_create_packed_scene(gltf_path: String) -> bool:
	if gltf_path.is_empty():
		return false
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false
	var export_type: String = str(meta.get("export_type", ""))
	var root_type: String = str(meta.get("root_type", ""))
	if export_type in ["ANIMATION_LIB"]:
		return false
	if export_type == "NAVMESH" or root_type == "NAVMESH":
		return false
	if preferred_scene_style_for_gltf(gltf_path) == NexusPaths.SCENE_STYLE_DISABLED:
		return false
	return true


const MAX_GLTF_NODES_FOR_INSTANCE_PASS := 50000
const MAX_INSTANCE_MARKERS_FOR_INSTANCE_PASS := 8000


static func can_run_instance_pass_for_level(gltf_path: String) -> Dictionary:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return {"ok": false, "reason": "glTF file missing"}

	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return {"ok": false, "reason": "glTF JSON unreadable"}

	var json := JSON.new()
	if json.parse(json_text) != OK:
		return {"ok": false, "reason": "glTF JSON invalid"}

	var gltf = json.get_data()
	if gltf == null or not gltf is Dictionary:
		return {"ok": false, "reason": "glTF root is not an object"}

	var nodes = gltf.get("nodes", [])
	if nodes is Array and nodes.size() > MAX_GLTF_NODES_FOR_INSTANCE_PASS:
		return {
			"ok": false,
			"reason": "glTF node count %d exceeds limit %d"
			% [nodes.size(), MAX_GLTF_NODES_FOR_INSTANCE_PASS],
		}

	var markers := _count_instance_markers_in_gltf(gltf)
	if markers > MAX_INSTANCE_MARKERS_FOR_INSTANCE_PASS:
		return {
			"ok": false,
			"reason": "instance marker count %d exceeds limit %d"
			% [markers, MAX_INSTANCE_MARKERS_FOR_INSTANCE_PASS],
		}

	return {"ok": true, "reason": ""}


static func _count_instance_markers_in_gltf(gltf: Dictionary) -> int:
	var count := 0
	var nodes = gltf.get("nodes", [])
	if not nodes is Array:
		return 0
	for node in nodes:
		if not node is Dictionary:
			continue
		var extras = node.get("extras", {})
		if not extras is Dictionary:
			continue
		var node_meta := nexus_meta_from_extras(extras)
		if node_meta.is_empty():
			continue
		if not str(node_meta.get("nexus_asset_id", "")).is_empty():
			count += 1
		elif not str(node_meta.get("nexus_placeholder_path", "")).is_empty():
			count += 1
	return count


static func resolve_packed_scene_path(candidate: String) -> String:
	if candidate.is_empty():
		return ""

	var normalized := candidate.replace("\\", "/").strip_edges()
	if normalized.is_empty():
		return ""

	var paths_to_try: Array[String] = []
	paths_to_try.append(normalized)
	paths_to_try.append_array(_scene_path_fallbacks(normalized))

	var seen: Dictionary = {}
	for path in paths_to_try:
		if path.is_empty() or seen.has(path):
			continue
		seen[path] = true
		if ResourceLoader.exists(path):
			return path
	return ""


# Per-gltf scene style declared in NEXUS_ASSET_METADATA.scene_style (exported
# from Blender). Legacy glTFs without scene_style default to wrapper.
static func preferred_scene_style_for_gltf(gltf_path: String) -> String:
	var declared := ""
	if NexusUtils.is_gltf_container_path(gltf_path):
		var meta := NexusUtils.get_nexus_metadata(gltf_path)
		if not meta.is_empty():
			declared = str(meta.get("scene_style", ""))
	if declared == NexusPaths.SCENE_STYLE_WRAPPER or declared == NexusPaths.SCENE_STYLE_INHERITED:
		return declared
	if declared == NexusPaths.SCENE_STYLE_DISABLED:
		return declared
	return NexusPaths.SCENE_STYLE_WRAPPER


# Resolve the Godot scene to instance for a dependency glTF. Unlike
# resolve_packed_scene_path (which tries the glTF first and is used for raw
# source/ready checks), this prefers the dependency's derived Godot scene so
# user edits in the wrapper/inherited scene propagate into compositions and
# levels. Order: per-gltf declared scene_style scene (NEXUS_ASSET_METADATA),
# other style scene, *_editable.tscn, *.tscn, finally the glTF as fallback.
static func resolve_instanced_scene_path(gltf_path: String) -> String:
	if gltf_path.is_empty():
		return ""
	var normalized := gltf_path.replace("\\", "/").strip_edges()
	if normalized.is_empty():
		return ""
	if not NexusUtils.is_gltf_container_path(normalized):
		return resolve_packed_scene_path(normalized)

	var preferred_style := preferred_scene_style_for_gltf(normalized)
	var base_no_ext := normalized.get_basename()
	var paths_to_try: Array[String] = []
	if preferred_style == NexusPaths.SCENE_STYLE_DISABLED:
		paths_to_try.append(base_no_ext + "_editable.tscn")
		paths_to_try.append(base_no_ext + ".tscn")
		paths_to_try.append(normalized)
	else:
		var alternate_style: String = (
			NexusPaths.SCENE_STYLE_INHERITED
			if preferred_style == NexusPaths.SCENE_STYLE_WRAPPER
			else NexusPaths.SCENE_STYLE_WRAPPER
		)
		paths_to_try.append(NexusPaths.scene_path_for(normalized, preferred_style))
		paths_to_try.append(NexusPaths.scene_path_for(normalized, alternate_style))
		paths_to_try.append(base_no_ext + "_editable.tscn")
		paths_to_try.append(base_no_ext + ".tscn")
		paths_to_try.append(normalized)

	var seen: Dictionary = {}
	for path in paths_to_try:
		if path.is_empty() or seen.has(path):
			continue
		seen[path] = true
		if ResourceLoader.exists(path):
			return path
	return ""


static func _scene_path_fallbacks(path: String) -> Array[String]:
	var result: Array[String] = []
	var gltf_base := ""

	if NexusUtils.is_gltf_container_path(path):
		gltf_base = path
	else:
		var ext := path.get_extension().to_lower()
		if ext == "tscn":
			var dir := path.get_base_dir()
			var stem := path.get_file().get_basename()
			stem = _strip_scene_style_suffix(stem)
			var gltf_candidate := dir.path_join(stem + ".gltf")
			if ResourceLoader.exists(gltf_candidate) or FileAccess.file_exists(gltf_candidate):
				gltf_base = gltf_candidate
			else:
				var glb_candidate := dir.path_join(stem + ".glb")
				if ResourceLoader.exists(glb_candidate) or FileAccess.file_exists(glb_candidate):
					gltf_base = glb_candidate

	if gltf_base.is_empty():
		return result

	var preferred_style := preferred_scene_style_for_gltf(gltf_base)
	var alternate_style := (
		NexusPaths.SCENE_STYLE_WRAPPER
		if preferred_style == NexusPaths.SCENE_STYLE_INHERITED
		else NexusPaths.SCENE_STYLE_INHERITED
	)
	result.append(NexusPaths.scene_path_for(gltf_base, preferred_style))
	result.append(NexusPaths.scene_path_for(gltf_base, alternate_style))
	var base_no_ext := gltf_base.get_basename()
	result.append(base_no_ext + "_editable.tscn")
	result.append(base_no_ext + ".tscn")
	result.append(gltf_base)
	return result


static func _strip_scene_style_suffix(stem: String) -> String:
	if stem.ends_with("_wrapper"):
		return stem.trim_suffix("_wrapper")
	if stem.ends_with("_inherited"):
		return stem.trim_suffix("_inherited")
	if stem.ends_with("_editable"):
		return stem.trim_suffix("_editable")
	return stem


# Canonical key (dir + stem without scene-style suffix, no extension) so a glTF and
# its derived *_inherited.tscn / *_wrapper.tscn resolve to the same identity.
# Slash-normalized and case-folded; do not use as a FileAccess path.
static func gltf_identity_key(path: String) -> String:
	if path.is_empty():
		return ""
	var canonical := NexusUtils.canonical_res_path(path)
	var stem := _strip_scene_style_suffix(canonical.get_file().get_basename())
	return canonical.get_base_dir().path_join(stem).to_lower()


static func is_self_reference(requested_path: String, own_gltf_path: String) -> bool:
	if requested_path.is_empty() or own_gltf_path.is_empty():
		return false
	return gltf_identity_key(requested_path) == gltf_identity_key(own_gltf_path)


static func collect_asset_ids_from_gltf(gltf_path: String) -> Array[String]:
	var result: Array[String] = []
	if gltf_path.is_empty() or not NexusUtils.is_gltf_container_path(gltf_path):
		return result
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return result
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return result
	var gltf = json.get_data()
	if gltf == null or not gltf is Dictionary:
		return result
	var nodes = gltf.get("nodes", [])
	if not nodes is Array:
		return result
	var seen: Dictionary = {}
	for node in nodes:
		if not node is Dictionary:
			continue
		var extras = node.get("extras", {})
		if not extras is Dictionary:
			continue
		var node_meta := nexus_meta_from_extras(extras)
		if node_meta.is_empty():
			continue
		var asset_id := str(node_meta.get("nexus_asset_id", "")).strip_edges()
		if asset_id.is_empty() or seen.has(asset_id):
			continue
		seen[asset_id] = true
		result.append(asset_id)
	return result


static func resolve_dependency_gltf_paths(asset_ids: Array) -> Array[String]:
	var result: Array[String] = []
	if asset_ids.is_empty():
		return result
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return result
	var seen: Dictionary = {}
	for asset_id in asset_ids:
		var id_str := str(asset_id).strip_edges()
		if id_str.is_empty() or seen.has(id_str):
			continue
		if not asset_index.has(id_str):
			continue
		var entry = asset_index[id_str]
		if not entry is Dictionary:
			continue
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or seen.has(gltf_path):
			continue
		seen[gltf_path] = true
		result.append(gltf_path)
	return result


static func are_dependency_scenes_ready(gltf_paths: Array) -> bool:
	for gltf_path in gltf_paths:
		if gltf_path is String and not dependency_scene_ready(gltf_path):
			return false
	return true


static func dependency_scene_ready(gltf_path: String) -> bool:
	if gltf_path.is_empty():
		return true
	if not NexusUtils.is_gltf_container_path(gltf_path):
		return FileAccess.file_exists(gltf_path) or ResourceLoader.exists(gltf_path)
	if not FileAccess.file_exists(gltf_path) and not ResourceLoader.exists(gltf_path):
		return false
	var import_path := gltf_path + ".import"
	if not FileAccess.file_exists(import_path):
		return false
	return FileAccess.get_modified_time(gltf_path) <= FileAccess.get_modified_time(import_path)


static func collect_composition_dependency_asset_ids(gltf_path: String) -> Array[String]:
	var asset_ids := collect_asset_ids_from_gltf(gltf_path)
	var seen: Dictionary = {}
	var result: Array[String] = []
	# Exclude the composition's own asset_id: a self-referential marker (caused by a
	# duplicate asset_id in Blender) must not become a dependency on itself, otherwise
	# Wave 2 waits forever and the importer recurses into its own scene.
	var own_asset_id := ""
	var root_meta := NexusUtils.get_nexus_metadata(gltf_path)
	if not root_meta.is_empty():
		own_asset_id = str(root_meta.get("asset_id", "")).strip_edges()
		var source_id := str(root_meta.get("source_asset_id", "")).strip_edges()
		if not source_id.is_empty() and not source_id == own_asset_id and not seen.has(source_id):
			seen[source_id] = true
			result.append(source_id)
		if str(root_meta.get("export_type", "")) == "MULTIMESH_MANIFEST":
			var sources = root_meta.get("sources", [])
			if sources is Array:
				for source_entry in sources:
					if not source_entry is Dictionary:
						continue
					var manifest_source_id := str(source_entry.get("source_asset_id", "")).strip_edges()
					if manifest_source_id.is_empty() or seen.has(manifest_source_id):
						continue
					seen[manifest_source_id] = true
					result.append(manifest_source_id)
	for asset_id in asset_ids:
		var id_str := str(asset_id).strip_edges()
		if id_str.is_empty() or seen.has(id_str):
			continue
		if not own_asset_id.is_empty() and id_str == own_asset_id:
			continue
		seen[id_str] = true
		result.append(id_str)
	return result


static func composition_dependencies_ready(gltf_path: String) -> bool:
	var asset_ids := collect_composition_dependency_asset_ids(gltf_path)
	if asset_ids.is_empty():
		return true
	var dep_gltfs := resolve_dependency_gltf_paths(asset_ids)
	# Drop any dependency that resolves back to this composition (defensive: the
	# own-asset_id exclusion above should already handle it, but a stale index entry
	# could still point a different id at the same glTF).
	var own_key := gltf_identity_key(gltf_path)
	var filtered: Array[String] = []
	for dep in dep_gltfs:
		if not dep is String:
			continue
		if not own_key.is_empty() and gltf_identity_key(dep) == own_key:
			continue
		filtered.append(dep)
	if filtered.is_empty():
		return true
	return are_dependency_scenes_ready(filtered)


const NEXUS_NODE_EXTRA_MERGE_KEYS := [
	"nexus_visibility_range",
	"nexus_bone_attachment",
]

const NEXUS_NODE_METADATA_MERGE_KEYS := [
	"nexus_light",
	"nexus_camera",
	"nexus_asset_id",
	"nexus_placeholder_path",
	"nexus_is_anim_anchor",
	"nexus_is_lod",
	"nexus_nested_collection",
	"nexus_nested_collection_name",
	"nexus_nested_root_type",
	"nexus_nested_collision_layer",
	"nexus_nested_collision_mask",
	"nexus_nested_physics_material_path",
	"nexus_nested_rigid_body_settings",
	"nexus_nested_vehicle_body_settings",
	"nexus_nested_animatable_sync_to_physics",
	"nexus_curve",
	"nexus_collision_dims",
	"nexus_mesh_collision_shape",
	"nexus_resonance_material_path",
	"nexus_metadata",
	"nexus_uv_layers",
	"discard_mesh",
	"visible",
	"cast_shadow",
]


static func is_composition_gltf(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false
	return NexusExportOrder.is_composition_export_type(str(meta.get("export_type", "")))


static func composition_scene_is_complete(root: Node, _scene_meta: Dictionary) -> bool:
	if root == null:
		return false
	if root.get_child_count() <= 0:
		return false
	return instancing_scene_is_complete(root, _scene_meta)


static func instancing_scene_is_complete(root: Node, _scene_meta: Dictionary) -> bool:
	if root == null:
		return false
	return not _root_has_unresolved_placeholders(root)


static func _root_has_unresolved_placeholders(root: Node) -> bool:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not node.scene_file_path.is_empty():
			for child in node.get_children():
				stack.append(child)
			continue
		var node_meta := get_node_nexus_meta(node)
		if not node_meta.is_empty():
			if node_meta.has("nexus_asset_id") or node_meta.has("nexus_placeholder_path"):
				return true
		for child in node.get_children():
			stack.append(child)
	return false


static func is_animation_lib_gltf(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false
	return str(meta.get("export_type", "")) == "ANIMATION_LIB"


static func is_level_gltf(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false
	return str(meta.get("export_type", "")) == "LEVEL"


static func is_deferred_wave_gltf(gltf_path: String) -> bool:
	if is_composition_gltf(gltf_path):
		return true
	if is_animation_lib_gltf(gltf_path):
		return true
	return NexusMultiMeshUtils.is_multimesh_manifest(gltf_path)


static func split_gltf_paths_for_phased_reimport(gltf_paths: Array) -> Dictionary:
	var wave1: Array[String] = []
	var deferred_composition: Array[String] = []
	var deferred_multimesh: Array[String] = []
	for path in gltf_paths:
		if not path is String:
			continue
		var gltf_path := str(path)
		if gltf_path.is_empty():
			continue
		if NexusMultiMeshUtils.is_multimesh_manifest(gltf_path):
			deferred_multimesh.append(gltf_path)
		elif is_composition_gltf(gltf_path) or is_animation_lib_gltf(gltf_path):
			deferred_composition.append(gltf_path)
		elif is_deferred_wave_gltf(gltf_path):
			deferred_composition.append(gltf_path)
		else:
			wave1.append(gltf_path)
	return {
		"wave1": wave1,
		"deferred": deferred_composition + deferred_multimesh,
		"deferred_composition": deferred_composition,
		"deferred_multimesh": deferred_multimesh,
	}


static func gltf_should_defer_within_priority(gltf_path: String) -> bool:
	## True when a composition still has unresolved instance targets - sort last
	## within the same export-type priority group.
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	if not is_composition_gltf(gltf_path):
		return false
	return not composition_dependencies_ready(gltf_path)


static func sort_gltf_paths_with_placeholder_defer(paths: Array) -> Array[String]:
	var sorted: Array[String] = []
	for path in paths:
		if path is String and not path.is_empty():
			sorted.append(path)
	sorted.sort_custom(func(a: String, b: String) -> bool:
		var pri_a := NexusExportOrder.export_type_priority_for_gltf(a)
		var pri_b := NexusExportOrder.export_type_priority_for_gltf(b)
		if pri_a != pri_b:
			return pri_a < pri_b
		var defer_a := 1 if gltf_should_defer_within_priority(a) else 0
		var defer_b := 1 if gltf_should_defer_within_priority(b) else 0
		if defer_a != defer_b:
			return defer_a < defer_b
		return a < b
	)
	return sorted


static func gltf_needs_reimport(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	if nexus_import_config_needs_fix(gltf_path):
		return true
	var import_path := gltf_path + ".import"
	if not FileAccess.file_exists(import_path):
		return true
	return FileAccess.get_modified_time(gltf_path) > FileAccess.get_modified_time(import_path)


static func is_gltf_stale_for_catchup(
	gltf_path: String, index_entry: Dictionary = {}
) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var import_path := gltf_path + ".import"
	if not FileAccess.file_exists(import_path):
		return true
	var gltf_mtime := FileAccess.get_modified_time(gltf_path)
	var import_mtime := FileAccess.get_modified_time(import_path)
	if gltf_mtime > import_mtime:
		return true
	var index_hash := str(index_entry.get("content_hash", "")).strip_edges()
	if not index_hash.is_empty():
		if NexusImportState.is_unchanged_since_import(gltf_path, index_hash):
			return false
		if NexusImportState.has_entry(gltf_path):
			return true
		if gltf_mtime <= import_mtime:
			NexusImportState.mark_imported(gltf_path, index_hash)
			return false
		return true
	if NexusImportState.is_unchanged_since_import(gltf_path, ""):
		return false
	if gltf_mtime <= import_mtime:
		NexusImportState.mark_imported(gltf_path, "")
		return false
	return true


static func find_indexed_dependents_for_changed_gltfs(changed_paths: Array) -> Array[String]:
	var result: Array[String] = []
	if changed_paths.is_empty():
		return result
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return result

	var gltf_to_asset_id: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			continue
		gltf_to_asset_id[gltf_path] = str(asset_id)

	var changed_asset_ids: Dictionary = {}
	var changed_path_set: Dictionary = {}
	for path in changed_paths:
		if not path is String or path.is_empty():
			continue
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			canonical = path
		changed_path_set[canonical] = true
		if gltf_to_asset_id.has(canonical):
			changed_asset_ids[gltf_to_asset_id[canonical]] = true

	if changed_asset_ids.is_empty():
		return result

	var seen: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		if changed_path_set.has(gltf_path):
			continue
		var meta := NexusUtils.get_nexus_metadata(gltf_path)
		var export_type := str(meta.get("export_type", ""))
		if not NexusExportOrder.is_index_dependent_export_type(export_type):
			continue
		var dep_ids := collect_composition_dependency_asset_ids(gltf_path)
		for dep_id in dep_ids:
			if changed_asset_ids.has(str(dep_id)):
				if not seen.has(gltf_path):
					seen[gltf_path] = true
					result.append(gltf_path)
				break
	return result


static func nexus_import_config_needs_fix(gltf_path: String) -> bool:
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false
	var import_path := gltf_path + ".import"
	if not FileAccess.file_exists(import_path):
		return true
	var loaded := NexusUtils.load_text_config(import_path)
	if not loaded.ok:
		return true
	return import_config_has_drift(gltf_path, loaded.config, meta)


static func import_config_has_drift(
	gltf_path: String, import_config: ConfigFile, meta: Dictionary
) -> bool:
	return _sync_import_config_params(gltf_path, import_config, meta, false)


static func apply_desired_import_config_params(
	gltf_path: String, import_config: ConfigFile, meta: Dictionary
) -> bool:
	return _sync_import_config_params(gltf_path, import_config, meta, true)


static func _sync_import_config_params(
	gltf_path: String, import_config: ConfigFile, meta: Dictionary, do_write: bool
) -> bool:
	var drifted := false
	if import_config.get_value("params", "import_script/path", "") != NexusPaths.IMPORT_POST_PROCESSOR:
		drifted = true
		if do_write:
			import_config.set_value("params", "import_script/path", NexusPaths.IMPORT_POST_PROCESSOR)
	if meta.has("root_type"):
		var desired_root := nexus_root_type_to_class_name(str(meta.get("root_type", "")))
		if import_config.get_value("params", "nodes/root_type", "") != desired_root:
			drifted = true
			if do_write:
				import_config.set_value("params", "nodes/root_type", desired_root)
	if gltf_has_custom_lods(gltf_path):
		if import_config.get_value("params", "meshes/generate_lods", true):
			drifted = true
			if do_write:
				import_config.set_value("params", "meshes/generate_lods", false)
	var light_mode = meta.get("nexus_light_bake_mode", -1)
	if light_mode != -1:
		var desired_light := 2 if light_mode == 1 else 0
		if import_config.get_value("params", "meshes/light_baking", 0) != desired_light:
			drifted = true
			if do_write:
				import_config.set_value("params", "meshes/light_baking", desired_light)
	if gltf_has_tangent_attributes(gltf_path):
		if import_config.get_value("params", "meshes/ensure_tangents", true):
			drifted = true
			if do_write:
				import_config.set_value("params", "meshes/ensure_tangents", false)
	return drifted


static func gltf_has_custom_lods(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	return not json_text.is_empty() and "nexus_is_lod" in json_text


static func gltf_has_tangent_attributes(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	return not json_text.is_empty() and "\"TANGENT\"" in json_text


static func discover_unindexed_composition_gltfs(asset_index: Dictionary) -> Array[String]:
	var indexed_paths: Dictionary = {}
	for entry in asset_index.values():
		if not entry is Dictionary:
			continue
		var indexed_path := NexusUtils.validate_index_path(str(entry.get("relative_path", "")))
		if not indexed_path.is_empty():
			indexed_paths[NexusUtils.path_identity_key(indexed_path)] = true

	var discovered: Array[String] = []
	var game_root := ProjectSettings.globalize_path("res://")
	if game_root.is_empty():
		return discovered

	for gltf_path in collect_gltfs_recursive(game_root):
		var res_path := NexusUtils.to_res_gltf_path(gltf_path)
		if res_path.is_empty():
			continue
		if indexed_paths.has(NexusUtils.path_identity_key(res_path)):
			continue
		if not is_deferred_wave_gltf(res_path):
			continue
		if NexusUtils.get_nexus_metadata(res_path).is_empty():
			continue
		discovered.append(res_path)

	discovered.sort()
	return discovered


static func is_thin_composition_gltf(gltf_path: String) -> bool:
	if not is_composition_gltf(gltf_path):
		return true
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return false
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return false
	var gltf = json.get_data()
	if gltf == null or not gltf is Dictionary:
		return false
	var nodes = gltf.get("nodes", [])
	if not nodes is Array:
		return false

	for index in range(nodes.size()):
		var node = nodes[index]
		if not node is Dictionary:
			continue
		if not _node_is_instance_marker(node):
			continue
		if _composition_marker_has_mesh_descendants(gltf, index):
			return false

	var meshes = gltf.get("meshes", [])
	var buffer_views = gltf.get("bufferViews", [])
	if meshes is Array and meshes.is_empty() and buffer_views is Array and not buffer_views.is_empty():
		return false

	var scene_roots := _composition_scene_root_indices(gltf)
	if scene_roots.is_empty():
		return true

	var node_budget := maxi(16, scene_roots.size() * 2)
	if nodes.size() > node_budget:
		return false

	for root_index in scene_roots:
		if root_index < 0 or root_index >= nodes.size():
			continue
		var root_node = nodes[root_index]
		if not root_node is Dictionary or not _node_is_instance_marker(root_node):
			continue
		var child_indices = root_node.get("children", [])
		if child_indices is Array and not child_indices.is_empty():
			return false

	return true


static func _composition_scene_root_indices(gltf: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var scenes = gltf.get("scenes", [])
	if not scenes is Array or scenes.is_empty():
		return result
	var scene_index: int = int(gltf.get("scene", 0))
	if scene_index < 0 or scene_index >= scenes.size():
		scene_index = 0
	var scene = scenes[scene_index]
	if not scene is Dictionary:
		return result
	var roots = scene.get("nodes", [])
	if not roots is Array:
		return result
	for root_index in roots:
		if root_index is int:
			result.append(root_index)
	return result


static func _node_is_instance_marker(node: Dictionary) -> bool:
	var extras = node.get("extras", {})
	if not extras is Dictionary:
		return false
	var meta = extras.get(NEXUS_NODE_META, {})
	if not meta is Dictionary:
		return false
	if not str(meta.get("nexus_asset_id", "")).is_empty():
		return true
	return not str(meta.get("nexus_placeholder_path", "")).is_empty()


static func _composition_marker_has_mesh_descendants(gltf: Dictionary, marker_index: int) -> bool:
	var nodes = gltf.get("nodes", [])
	if not nodes is Array or marker_index < 0 or marker_index >= nodes.size():
		return false
	var marker = nodes[marker_index]
	if not marker is Dictionary:
		return false
	var descendants: Array[int] = []
	for child_index in marker.get("children", []):
		if child_index is int:
			_collect_gltf_node_descendants(gltf, child_index, descendants)
	for descendant_index in descendants:
		var node = nodes[descendant_index]
		if node is Dictionary and node.has("mesh"):
			return true
	return false


static func _collect_gltf_node_descendants(gltf: Dictionary, root_index: int, into: Array[int]) -> void:
	var nodes = gltf.get("nodes", [])
	if not nodes is Array or root_index < 0 or root_index >= nodes.size():
		return
	if root_index in into:
		return
	into.append(root_index)
	var node = nodes[root_index]
	if not node is Dictionary:
		return
	for child_index in node.get("children", []):
		if child_index is int:
			_collect_gltf_node_descendants(gltf, child_index, into)


static func inject_nexus_node_extras_from_gltf(root: Node, gltf_path: String) -> void:
	if gltf_path.is_empty() or not NexusUtils.is_gltf_container_path(gltf_path):
		return
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return
	var gltf = json.get_data()
	if gltf == null or not gltf is Dictionary:
		return
	var nodes = gltf.get("nodes", [])
	var name_to_extras: Dictionary = {}
	var duplicate_names: Dictionary = {}
	for n in nodes:
		if not n is Dictionary:
			continue
		var extras = n.get("extras", {})
		if not extras is Dictionary or extras.is_empty():
			continue
		var nm = n.get("name", "")
		if nm.is_empty():
			continue
		if not (extras.has(NEXUS_NODE_META) or extras.has("nexus_visibility_range")):
			continue
		if name_to_extras.has(nm) or duplicate_names.has(nm):
			# Name-keyed matching cannot disambiguate; skip rather than inject wrong extras.
			if not duplicate_names.has(nm):
				push_warning(
					"Nexus: duplicate glTF node name '%s' in %s; skipping node extras inject for that name"
					% [nm, gltf_path]
				)
			duplicate_names[nm] = true
			name_to_extras.erase(nm)
			continue
		name_to_extras[nm] = extras
	if name_to_extras.is_empty():
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd.name in name_to_extras:
			var from_gltf: Dictionary = name_to_extras[nd.name]
			var existing: Dictionary = nd.get_meta("extras", {}) if nd.has_meta("extras") else {}
			if not existing is Dictionary:
				existing = {}
			var merged := existing.duplicate(true)
			if from_gltf.has(NEXUS_NODE_META):
				var from_node_meta: Dictionary = from_gltf[NEXUS_NODE_META]
				if from_node_meta is Dictionary:
					if merged.has(NEXUS_NODE_META) and merged[NEXUS_NODE_META] is Dictionary:
						merged[NEXUS_NODE_META] = _merge_nexus_node_metadata(
							merged[NEXUS_NODE_META], from_node_meta
						)
					elif not merged.has(NEXUS_NODE_META):
						merged[NEXUS_NODE_META] = from_node_meta.duplicate(true)
			for key in NEXUS_NODE_EXTRA_MERGE_KEYS:
				if from_gltf.has(key):
					merged[key] = from_gltf[key]
			nd.set_meta("extras", merged)
		for i in range(nd.get_child_count() - 1, -1, -1):
			stack.append(nd.get_child(i))


## Mirrors inject_nexus_node_extras_from_gltf for materials. Godot does not
## reliably surface glTF material `extras` (notably for embedded .glb) as
## Material metadata, so material_processor's index lookup would silently skip
## the surface. Restore nexus_material_id by matching the glTF material `name`,
## which Godot keeps on the imported Material as resource_name.
static func inject_nexus_material_extras_from_gltf(root: Node, gltf_path: String) -> void:
	if gltf_path.is_empty() or not NexusUtils.is_gltf_container_path(gltf_path):
		return
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return
	var gltf = json.get_data()
	if gltf == null or not gltf is Dictionary:
		return
	var materials = gltf.get("materials", [])
	if not materials is Array or materials.is_empty():
		return
	var name_to_id: Dictionary = {}
	for m in materials:
		if not m is Dictionary:
			continue
		var extras = m.get("extras", {})
		if not extras is Dictionary or not extras.has(NEXUS_MATERIAL_ID_KEY):
			continue
		var mname := str(m.get("name", "")).strip_edges()
		if mname.is_empty():
			continue
		name_to_id[mname] = str(extras[NEXUS_MATERIAL_ID_KEY])
	if name_to_id.is_empty():
		return
	var visited: Dictionary = {}
	var stack: Array = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D and is_instance_valid(nd.mesh):
			for i in range(nd.mesh.get_surface_count()):
				var mat: Material = nd.mesh.surface_get_material(i)
				if not is_instance_valid(mat):
					continue
				var iid := mat.get_instance_id()
				if visited.has(iid):
					continue
				visited[iid] = true
				var existing = mat.get_meta("extras", {}) if mat.has_meta("extras") else {}
				if existing is Dictionary and existing.has(NEXUS_MATERIAL_ID_KEY):
					continue
				var mat_name := str(mat.resource_name).strip_edges()
				if not name_to_id.has(mat_name):
					continue
				var merged: Dictionary = existing.duplicate(true) if existing is Dictionary else {}
				merged[NEXUS_MATERIAL_ID_KEY] = name_to_id[mat_name]
				mat.set_meta("extras", merged)
		for i in range(nd.get_child_count() - 1, -1, -1):
			stack.append(nd.get_child(i))


static func _merge_nexus_node_metadata(existing: Dictionary, from_gltf: Dictionary) -> Dictionary:
	var merged := existing.duplicate(true)
	for key in NEXUS_NODE_METADATA_MERGE_KEYS:
		if from_gltf.has(key) and not merged.has(key):
			merged[key] = from_gltf[key]
	return merged
