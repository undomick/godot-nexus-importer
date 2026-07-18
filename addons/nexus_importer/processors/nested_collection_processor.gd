@tool
extends Object

## Wraps inline nested collection subtrees with their configured Godot root types.

const NEXUS_NODE_META := "NEXUS_NODE_METADATA"

const RootProcessor = preload("res://addons/nexus_importer/processors/root_processor.gd")

var _processed_nested_names: Dictionary = {}
var _root_processor = RootProcessor.new()


func process_scene(scene: Node, stats: Dictionary) -> void:
	_processed_nested_names.clear()
	var boundaries := _find_nested_boundaries(scene)
	for boundary in boundaries:
		_wrap_nested_group(scene, boundary, stats)


func _find_nested_boundaries(root: Node) -> Array[Node]:
	var result: Array[Node] = []
	_collect_nested_boundaries(root, result)
	return result


func _collect_nested_boundaries(node: Node, result: Array[Node]) -> void:
	var meta := _node_nexus_meta(node)
	if meta.get("nexus_nested_collection", false):
		var nested_name: String = str(meta.get("nexus_nested_collection_name", ""))
		if not nested_name.is_empty() and not _processed_nested_names.has(nested_name):
			result.append(node)
	for child in node.get_children():
		_collect_nested_boundaries(child, result)


func _wrap_nested_group(scene: Node, boundary: Node, stats: Dictionary) -> void:
	var meta := _node_nexus_meta(boundary)
	var nested_name: String = str(meta.get("nexus_nested_collection_name", boundary.name))
	if nested_name.is_empty() or _processed_nested_names.has(nested_name):
		return
	_processed_nested_names[nested_name] = true

	var members := _collect_members_for_nested_name(scene, nested_name)
	if members.is_empty():
		members = [boundary]

	var wrapper := NexusSceneUtils.create_node_for_nexus_root_type(
		str(meta.get("nexus_nested_root_type", "NODE_3D"))
	)
	wrapper.name = nested_name

	var parent := boundary.get_parent()
	if parent == null:
		return

	var insert_index := boundary.get_index()
	parent.add_child(wrapper)
	parent.move_child(wrapper, insert_index)
	wrapper.owner = scene.owner if scene.owner else scene
	# Wrapper is a physics/type container only; member glTF transforms stay on children.
	if wrapper is Node3D:
		(wrapper as Node3D).transform = Transform3D.IDENTITY

	var wrapper_meta := {
		"root_type": str(meta.get("nexus_nested_root_type", "NODE_3D")),
		"collision_layer": meta.get("nexus_nested_collision_layer", 1),
		"collision_mask": meta.get("nexus_nested_collision_mask", 1),
	}
	if meta.has("nexus_nested_physics_material_path"):
		wrapper_meta["physics_material_path"] = meta.get("nexus_nested_physics_material_path")
	if meta.has("nexus_nested_rigid_body_settings"):
		wrapper_meta["rigid_body_settings"] = meta.get("nexus_nested_rigid_body_settings")
	if meta.has("nexus_nested_vehicle_body_settings"):
		wrapper_meta["vehicle_body_settings"] = meta.get("nexus_nested_vehicle_body_settings")
	if meta.has("nexus_nested_animatable_sync_to_physics"):
		wrapper_meta["animatable_sync_to_physics"] = meta.get("nexus_nested_animatable_sync_to_physics")

	for member in _top_level_members(members):
		if member == wrapper or not is_instance_valid(member):
			continue
		var member_parent := member.get_parent()
		if member_parent == null:
			continue
		if not member is Node3D:
			continue
		_reparent_member_under_wrapper(scene, wrapper, member as Node3D)

	if wrapper_meta.get("root_type", "") == "VEHICLE":
		wrapper = _root_processor.ensure_vehicle_body_root(wrapper, wrapper_meta)

	if wrapper is CollisionObject3D:
		_root_processor.set_collision_layers(wrapper, wrapper_meta, stats)

	stats["nested"] = int(stats.get("nested", 0)) + 1


func _reparent_member_under_wrapper(scene: Node, wrapper: Node, member_3d: Node3D) -> void:
	var member_parent := member_3d.get_parent()
	if member_parent == null:
		return
	var member_global := _composed_global_transform(member_3d)
	member_parent.remove_child(member_3d)
	member_3d.owner = null
	wrapper.add_child(member_3d)
	if wrapper is Node3D:
		var wrapper_3d := wrapper as Node3D
		var wrapper_global := _composed_global_transform(wrapper_3d)
		member_3d.transform = wrapper_global.affine_inverse() * member_global
	member_3d.owner = scene.owner if scene.owner else scene


func _composed_global_transform(node_3d: Node3D) -> Transform3D:
	if node_3d.is_inside_tree():
		return node_3d.global_transform

	var chain: Array[Node3D] = []
	var current: Node = node_3d
	while current is Node3D:
		chain.push_front(current as Node3D)
		current = current.get_parent()

	var result := Transform3D.IDENTITY
	for node in chain:
		result = result * node.transform
	return result


func _collect_members_for_nested_name(root: Node, nested_name: String) -> Array[Node]:
	var members: Array[Node] = []
	_collect_members_visit(root, nested_name, members)
	return members


func _top_level_members(members: Array[Node]) -> Array[Node]:
	## Reparent only roots of the nested subtree; descendants move with their member parent.
	var member_ids: Dictionary = {}
	for member in members:
		if is_instance_valid(member):
			member_ids[member.get_instance_id()] = true

	var roots: Array[Node] = []
	for member in members:
		if not is_instance_valid(member):
			continue
		var parent := member.get_parent()
		var nested_under_member := false
		while parent != null:
			if member_ids.has(parent.get_instance_id()):
				nested_under_member = true
				break
			parent = parent.get_parent()
		if not nested_under_member:
			roots.append(member)
	return roots


func _collect_members_visit(node: Node, nested_name: String, members: Array[Node]) -> void:
	var meta := _node_nexus_meta(node)
	if str(meta.get("nexus_nested_collection_name", "")) == nested_name:
		members.append(node)
	for child in node.get_children():
		_collect_members_visit(child, nested_name, members)


func _node_nexus_meta(node: Node) -> Dictionary:
	var extras = node.get_meta("extras", {})
	if extras is Dictionary and extras.has(NEXUS_NODE_META):
		var node_meta = extras[NEXUS_NODE_META]
		if node_meta is Dictionary:
			return node_meta
	return {}
