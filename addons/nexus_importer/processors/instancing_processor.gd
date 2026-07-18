@tool
extends Object

## Replaces placeholder nodes with instanced scenes from asset_index or nexus_placeholder_path.

const PENDING_INSTANCES_META := "_nexus_pending_instances"
const INSTANCES_RESOLVED_META := "_nexus_instances_resolved"

const MAX_INSTANCING_ATTEMPTS_PER_IMPORT := 2048
const MAX_PENDING_INSTANCES := 4096

const NexusImportContext = preload("res://addons/nexus_importer/scripts/nexus_import_context.gd")
const NexusTransformSanitize = preload("res://addons/nexus_importer/scripts/nexus_transform_sanitize.gd")

var _asset_index_cache: Dictionary = {}
var _asset_index_mtime: int = -1
var _warned_missing_paths: Dictionary = {}
var _instancing_attempts_this_import: int = 0
var _import_budget_exhausted: bool = false
var _budget_warning_emitted: bool = false
var _pending_cap_warning_emitted: bool = false
var _degenerate_transform_warning_emitted: bool = false


func reset_import_budget() -> void:
	_instancing_attempts_this_import = 0
	_import_budget_exhausted = false
	_budget_warning_emitted = false
	_pending_cap_warning_emitted = false
	_degenerate_transform_warning_emitted = false


func _consume_instancing_budget(gltf_context: String) -> bool:
	if _import_budget_exhausted:
		return false
	_instancing_attempts_this_import += 1
	if _instancing_attempts_this_import <= MAX_INSTANCING_ATTEMPTS_PER_IMPORT:
		return true
	_import_budget_exhausted = true
	if not _budget_warning_emitted:
		_budget_warning_emitted = true
		push_warning(
			"Nexus Instancer: Instance resolve budget exceeded%s - keeping placeholders."
			% gltf_context
		)
	return false


func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	var gltf_context: String = (" (in glTF: %s)" % gltf_path) if not gltf_path.is_empty() else ""
	if not _consume_instancing_budget(gltf_context):
		return false

	if not node.scene_file_path.is_empty():
		return false

	var requested_path := ""

	if meta.has("nexus_placeholder_path"):
		var raw_placeholder := str(meta["nexus_placeholder_path"])
		requested_path = NexusUtils.validate_index_path(raw_placeholder)
		if requested_path.is_empty():
			push_warning(
				"Nexus Instancer: Rejected unsafe placeholder path '%s'.%s"
				% [raw_placeholder, gltf_context]
			)
			return false
	elif meta.has("nexus_asset_id"):
		requested_path = _resolve_scene_path_from_asset_id(meta["nexus_asset_id"], root, gltf_context)
		if requested_path.is_empty():
			return false

	if requested_path.is_empty():
		return false

	if NexusSceneUtils.is_self_reference(requested_path, gltf_path):
		push_error(
			"Nexus Instancer: Asset ID resolves to this composition's own glTF ('%s') - self-reference skipped.%s"
			% [requested_path, gltf_context]
		)
		return false

	var scene_path := NexusSceneUtils.resolve_instanced_scene_path(requested_path)
	if scene_path.is_empty():
		_mark_pending_instance(root, node, requested_path, meta, gltf_context)
		return false

	if NexusImportContext.should_defer_external_scene_loads():
		_mark_pending_instance(root, node, requested_path, meta, gltf_context, scene_path)
		if not gltf_path.is_empty():
			NexusImportContext.mark_level_needs_instance_pass(gltf_path)
		return false

	return _instantiate_scene(node, root, scene_path, gltf_context, meta)


func _instantiate_scene(
	node: Node,
	root: Node,
	scene_path: String,
	gltf_context: String,
	meta: Dictionary = {}
) -> bool:
	if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
		return false
	if not ResourceLoader.exists(scene_path):
		return false

	var instance = NexusSceneUtils.instantiate_scene_reference(scene_path)
	if instance == null:
		push_error(
			"Nexus Instancer: Resource at '%s' is not a PackedScene.%s" % [scene_path, gltf_context]
		)
		return false

	var parent = node.get_parent()
	if not parent:
		return false

	var base_name := NexusUtils.sanitize_node_name(node.name)
	# node is still a child of parent here; exclude it so the replacement keeps
	# the placeholder's name instead of being suffixed _001 next to it.
	instance.name = NexusUtils.unique_sibling_name(parent, base_name, node)
	instance.transform = _sanitize_instance_transform(node.transform, gltf_context)

	parent.remove_child(node)
	parent.add_child(instance)
	instance.owner = root
	node.free()

	print_verbose("Nexus Instancer: Replaced '%s' with instance of '%s'." % [instance.name, scene_path.get_file()])
	return true


func _sanitize_instance_transform(transform: Transform3D, gltf_context: String) -> Transform3D:
	var safe := NexusTransformSanitize.sanitize(transform, "instance marker")
	if safe == transform:
		return transform
	if not _degenerate_transform_warning_emitted:
		_degenerate_transform_warning_emitted = true
		push_warning(
			"Nexus Instancer: Marker transform is non-finite or degenerate; using sanitized transform.%s"
			% gltf_context
		)
	return safe


func _mark_pending_instance(
	root: Node,
	node: Node,
	requested_path: String,
	meta: Dictionary,
	gltf_context: String,
	resolved_scene_path: String = ""
) -> void:
	var pending = root.get_meta(PENDING_INSTANCES_META, [])
	if not pending is Array:
		pending = []
	if pending.size() >= MAX_PENDING_INSTANCES:
		if not _pending_cap_warning_emitted:
			_pending_cap_warning_emitted = true
			push_warning(
				"Nexus Instancer: Pending instance queue full (%d)%s - keeping placeholders."
				% [MAX_PENDING_INSTANCES, gltf_context]
			)
		return
	var node_path := ""
	if root != null and node != null and node.is_inside_tree() and root.is_ancestor_of(node):
		node_path = str(root.get_path_to(node))
	pending.append({
		"requested_path": requested_path,
		"scene_path": resolved_scene_path,
		"node_name": node.name,
		"node_path": node_path,
		"uuid": str(meta.get("uuid", "")),
		"asset_id": meta.get("nexus_asset_id", ""),
		"placeholder_path": meta.get("nexus_placeholder_path", ""),
	})
	root.set_meta(PENDING_INSTANCES_META, pending)

	if not resolved_scene_path.is_empty():
		return

	var asset_ref: String = (
		" Referenced by asset ID '%s'." % meta.get("nexus_asset_id", "")
		if meta.has("nexus_asset_id")
		else ""
	)
	if _warned_missing_paths.has(requested_path):
		return
	_warned_missing_paths[requested_path] = true
	push_warning(
		"Nexus Instancer: Target scene not found at '%s'.%s%s Placeholder kept; will retry on reimport."
		% [requested_path, asset_ref, gltf_context]
	)


func _load_asset_index() -> Dictionary:
	var asset_index_path = NexusPaths.asset_index_path()
	if not FileAccess.file_exists(asset_index_path):
		_asset_index_mtime = -1
		_asset_index_cache = {}
		return {}

	var mtime := FileAccess.get_modified_time(asset_index_path)
	if mtime == _asset_index_mtime and not _asset_index_cache.is_empty():
		return _asset_index_cache

	var load_result := NexusUtils.try_load_index_json(asset_index_path, "asset_index.json")
	if not load_result.ok:
		_asset_index_mtime = -1
		_asset_index_cache = {}
		return {}

	_asset_index_cache = load_result.entries
	_asset_index_mtime = mtime
	return _asset_index_cache


func _resolve_scene_path_from_asset_id(asset_id: String, root: Node, gltf_context: String) -> String:
	var asset_index = _load_asset_index()
	if not asset_index.has(asset_id):
		push_error("Nexus Instancer: Asset ID '%s' not found.%s" % [asset_id, gltf_context])
		return ""

	var entry = asset_index[asset_id]
	if not entry is Dictionary:
		push_error("Nexus Instancer: Invalid index entry for Asset ID '%s'.%s" % [asset_id, gltf_context])
		return ""

	var rel = entry.get("relative_path", "")
	var base_gltf_path = NexusUtils.validate_index_path(rel)
	if base_gltf_path.is_empty():
		push_error("Nexus Instancer: Invalid path in index for Asset ID '%s'.%s" % [asset_id, gltf_context])
		return ""

	return base_gltf_path


func retry_pending_instances(root: Node) -> int:
	if NexusImportContext.should_defer_external_scene_loads():
		return 0
	if _import_budget_exhausted:
		return 0

	var pending = root.get_meta(PENDING_INSTANCES_META, [])
	if not pending is Array or pending.is_empty():
		return 0

	var gltf_path: String = root.get_meta("_nexus_gltf_path", "")
	var gltf_context: String = (" (in glTF: %s)" % gltf_path) if not gltf_path.is_empty() else ""

	var resolved := 0
	var still_pending: Array = []
	for entry in pending:
		if not entry is Dictionary:
			continue
		# Drop entries that point back at this composition - they can never resolve
		# and would otherwise stay pending forever (placeholder is kept as-is).
		var entry_requested := str(entry.get("requested_path", ""))
		var entry_scene := str(entry.get("scene_path", ""))
		if NexusSceneUtils.is_self_reference(entry_requested, gltf_path) \
				or NexusSceneUtils.is_self_reference(entry_scene, gltf_path):
			continue
		if not _consume_instancing_budget(gltf_context):
			still_pending.append(entry)
			continue
		var node := _resolve_pending_node(root, entry)
		if node == null:
			still_pending.append(entry)
			continue
		if not node.scene_file_path.is_empty():
			continue

		var scene_path := str(entry.get("scene_path", ""))
		if scene_path.is_empty():
			var meta: Dictionary = {}
			var asset_id: String = str(entry.get("asset_id", ""))
			var placeholder_path: String = str(entry.get("placeholder_path", ""))
			var uuid: String = str(entry.get("uuid", ""))
			if not asset_id.is_empty():
				meta["nexus_asset_id"] = asset_id
			elif not placeholder_path.is_empty():
				meta["nexus_placeholder_path"] = placeholder_path
			else:
				meta["nexus_placeholder_path"] = str(entry.get("requested_path", ""))
			if not uuid.is_empty():
				meta["uuid"] = uuid
			if process(node, meta, root):
				resolved += 1
			else:
				still_pending.append(entry)
			continue

		# Re-resolve so a wrapper/inherited scene built after the defer is picked
		# up instead of the stale glTF-fallback scene_path stored at defer time.
		var resolved_scene := NexusSceneUtils.resolve_instanced_scene_path(entry_requested)
		if not resolved_scene.is_empty():
			scene_path = resolved_scene

		if _instantiate_scene(node, root, scene_path, gltf_context):
			resolved += 1
		else:
			still_pending.append(entry)

	if still_pending.is_empty():
		root.remove_meta(PENDING_INSTANCES_META)
	else:
		root.set_meta(PENDING_INSTANCES_META, still_pending)
	return resolved


func _resolve_pending_node(root: Node, entry: Dictionary) -> Node:
	var node_path := str(entry.get("node_path", ""))
	if not node_path.is_empty():
		var from_path = root.get_node_or_null(NodePath(node_path))
		if from_path != null:
			return from_path
	var uuid := str(entry.get("uuid", ""))
	if not uuid.is_empty():
		var from_uuid = _find_node_by_uuid(root, uuid)
		if from_uuid != null:
			return from_uuid
	var node_name: String = str(entry.get("node_name", ""))
	if node_name.is_empty():
		return null
	return _find_placeholder_by_name(root, node_name, uuid)


func _find_node_by_uuid(root: Node, uuid: String) -> Node:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.has_meta("extras"):
			var extras = node.get_meta("extras")
			if extras is Dictionary:
				var node_meta = extras.get("NEXUS_NODE_METADATA", {})
				if node_meta is Dictionary and str(node_meta.get("uuid", "")) == uuid:
					return node
		for child in node.get_children():
			stack.append(child)
	return null


func _find_placeholder_by_name(root: Node, node_name: String, uuid: String) -> Node:
	var matches: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node.name == node_name and node.scene_file_path.is_empty():
			matches.append(node)
		for child in node.get_children():
			stack.append(child)
	if matches.is_empty():
		return null
	if matches.size() == 1 or uuid.is_empty():
		return matches[0]
	for candidate in matches:
		if candidate.has_meta("extras"):
			var extras = candidate.get_meta("extras")
			if extras is Dictionary:
				var node_meta = extras.get("NEXUS_NODE_METADATA", {})
				if node_meta is Dictionary and str(node_meta.get("uuid", "")) == uuid:
					return candidate
	return matches[0]


static func has_unresolved_placeholders(root: Node) -> bool:
	if root == null:
		return false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if not node.scene_file_path.is_empty():
			for child in node.get_children():
				stack.append(child)
			continue
		if node.has_meta("extras"):
			var extras = node.get_meta("extras")
			if extras is Dictionary and "NEXUS_NODE_METADATA" in extras:
				var node_meta = extras["NEXUS_NODE_METADATA"]
				if node_meta is Dictionary:
					if node_meta.has("nexus_asset_id") or node_meta.has("nexus_placeholder_path"):
						return true
		for child in node.get_children():
			stack.append(child)
	return false
