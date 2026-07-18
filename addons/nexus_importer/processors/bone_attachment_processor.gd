@tool
extends Object

## Creates ModifierBoneTarget3D and reparents the node to attach it to a skeleton bone.

func process(node: Node3D, meta: Dictionary, root: Node) -> bool:
	meta = _resolve_attachment_meta(node, meta)
	if not meta.has("nexus_bone_attachment"):
		return false

	var bone_name = meta["nexus_bone_attachment"].get("bone_name")
	if not bone_name:
		push_warning(
			"Nexus Attacher: Bone attachment metadata found on '%s', but 'bone_name' is missing." % node.name
		)
		return false

	var skeleton = _find_skeleton_in_scene(root)
	if not skeleton:
		push_warning(
			"Nexus Attacher: Could not find a Skeleton3D node in the scene for node '%s'."
			% node.name
		)
		return false

	if node == skeleton or node.is_ancestor_of(skeleton):
		return false

	var godot_bone_name = bone_name.replace(":", "_")
	var bone_idx = skeleton.find_bone(godot_bone_name)
	if bone_idx < 0:
		push_warning(
			"Nexus Attacher: Bone '%s' not found in skeleton for node '%s'." % [godot_bone_name, node.name]
		)
		return false

	var offset := _resolve_bone_offset(node, root, skeleton, bone_idx, meta)
	var parent = node.get_parent()
	if not parent:
		push_error("Nexus Attacher: Placeholder node '%s' has no parent." % node.name)
		return false

	_ensure_bone_target(node, root, skeleton, godot_bone_name, parent)
	node.owner = root
	node.transform = offset

	if OS.is_debug_build():
		print(
			"Nexus Processor: ModifierBoneTarget '%s' -> bone '%s' | pos=%s scale=%s"
			% [node.name, godot_bone_name, node.position, node.scale]
		)
	return true


func _resolve_attachment_meta(node: Node3D, meta: Dictionary) -> Dictionary:
	if meta.has("nexus_bone_attachment"):
		return meta
	if not node.has_meta("extras"):
		return meta
	var ex = node.get_meta("extras")
	if not ex is Dictionary:
		return meta
	if ex.has("nexus_bone_attachment"):
		return ex
	if ex.has("NEXUS_NODE_METADATA"):
		var inner = ex["NEXUS_NODE_METADATA"]
		if inner is Dictionary and inner.has("nexus_bone_attachment"):
			return inner
	return meta


func _resolve_bone_offset(
	node: Node3D,
	root: Node,
	skeleton: Skeleton3D,
	bone_idx: int,
	meta: Dictionary
) -> Transform3D:
	# Reconstruct the bone-relative offset in skeleton-local space from the node's
	# actual world transform and the bone rest. This is frame-agnostic: the exporter
	# only provides the node's world TRS (via the glTF node) and the bone name, so no
	# B2G/conversion assumptions are baked in. node.world = skel_world @ bone_rest @ offset.
	var node_world := _get_node_world_transform(node, root, meta)
	var skel_world := (
		skeleton.global_transform
		if skeleton.is_inside_tree()
		else _get_accumulated_transform(skeleton, root)
	)
	var empty_skel := skel_world.affine_inverse() * node_world
	var bone_rest := skeleton.get_bone_global_rest(bone_idx)
	return bone_rest.affine_inverse() * empty_skel


func _get_node_world_transform(node: Node3D, root: Node, meta: Dictionary) -> Transform3D:
	if node.is_inside_tree():
		return node.global_transform
	var gltf_path = root.get_meta("_nexus_gltf_path", "")
	var world_xform = _get_node_world_transform_from_gltf(gltf_path, node.name, meta, false)
	if world_xform != null:
		return world_xform
	return _get_accumulated_transform(node, root)


func _ensure_bone_target(
	node: Node3D,
	root: Node,
	skeleton: Skeleton3D,
	godot_bone_name: String,
	parent: Node
) -> void:
	if parent is ModifierBoneTarget3D and _is_skeleton_child(parent, skeleton):
		parent.name = node.name + "_Attachment"
		parent.set_bone_name(godot_bone_name)
		parent.transform = Transform3D.IDENTITY
		parent.owner = root
		return

	var bone_attachment = ModifierBoneTarget3D.new()
	bone_attachment.name = node.name + "_Attachment"
	bone_attachment.set_bone_name(godot_bone_name)
	bone_attachment.transform = Transform3D.IDENTITY
	skeleton.add_child(bone_attachment)
	bone_attachment.owner = root
	parent.remove_child(node)
	node.owner = null
	bone_attachment.add_child(node)


func _get_node_world_transform_from_gltf(gltf_path: String, node_name: String, meta: Dictionary, ignore_scale: bool = false):
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return null
	var json_text: String = NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return null
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return null
	var gltf = json.get_data()
	if gltf == null:
		return null
	var nodes = gltf.get("nodes", [])
	if nodes.is_empty():
		return null

	var target_idx = -1
	for i in range(nodes.size()):
		var n = nodes[i]
		if n.get("name", "") != node_name:
			continue
		var extras = n.get("extras", {})
		var node_meta = extras.get("NEXUS_NODE_METADATA", {})
		if node_meta.has("nexus_bone_attachment"):
			target_idx = i
			break
	if target_idx < 0:
		for i in range(nodes.size()):
			if nodes[i].get("name", "") == node_name:
				target_idx = i
				break
	if target_idx < 0:
		return null

	var parent_map: Dictionary = {}
	var scenes = gltf.get("scenes", [])
	var scene = scenes[0] if scenes.size() > 0 else {}
	var root_indices = scene.get("nodes", [])
	var stack: Array = []
	for idx in root_indices:
		stack.append(int(idx))
	while not stack.is_empty():
		var pi = stack.pop_back()
		var pnode = nodes[pi] if pi < nodes.size() else {}
		for ci in pnode.get("children", []):
			parent_map[int(ci)] = pi
			stack.append(int(ci))

	var chain: Array = []
	var idx = int(target_idx)
	while idx >= 0:
		var n = nodes[idx] if idx < nodes.size() else {}
		var use_scale_one = ignore_scale and (idx == target_idx)
		chain.append(_parse_gltf_node_transform(n, use_scale_one))
		idx = parent_map.get(idx, -1)
	chain.reverse()
	var world = Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		world = chain[i] * world
	return world


func _parse_gltf_node_transform(n: Dictionary, use_scale_one: bool = false) -> Transform3D:
	var t_arr = n.get("translation", [0.0, 0.0, 0.0])
	var r_arr = n.get("rotation", [0.0, 0.0, 0.0, 1.0])
	var s_arr = [1.0, 1.0, 1.0] if use_scale_one else n.get("scale", [1.0, 1.0, 1.0])
	var origin = Vector3(_get_float(t_arr, 0), _get_float(t_arr, 1), _get_float(t_arr, 2))
	var q = Quaternion(_get_float(r_arr, 0), _get_float(r_arr, 1), _get_float(r_arr, 2), _get_float(r_arr, 3))
	var scale = Vector3(_get_float(s_arr, 0), _get_float(s_arr, 1), _get_float(s_arr, 2))
	return Transform3D(Basis(q) * Basis.from_scale(scale), origin)


func _get_float(arr: Array, i: int) -> float:
	if i >= arr.size():
		return 0.0 if i < 3 else 1.0
	var v = arr[i]
	if v is float:
		return v
	if v is int:
		return float(v)
	return 0.0


func _get_accumulated_transform(node: Node, root: Node) -> Transform3D:
	var path: Array[Node] = []
	var n: Node = node
	while is_instance_valid(n):
		path.append(n)
		if n == root:
			break
		n = n.get_parent()
	if path.is_empty():
		return Transform3D.IDENTITY
	path.reverse()
	var t = Transform3D.IDENTITY
	for nd in path:
		if nd is Node3D:
			t = t * nd.transform
	return t


func _is_skeleton_child(node: Node, skeleton: Skeleton3D) -> bool:
	return node.get_parent() == skeleton


func _find_skeleton_in_scene(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for child in root.get_children():
		var found = _find_skeleton_in_scene(child)
		if is_instance_valid(found):
			return found
	return null
