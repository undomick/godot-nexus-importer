@tool
extends Object

## Creates ModifierBoneTarget3D and reparents the node to attach it to a skeleton bone (enables future physics modifiers).
func process(node: Node3D, meta: Dictionary, root: Node) -> bool:
	# Resolve meta: importer may pass NEXUS_NODE_METADATA inner dict; also support meta being full extras or from node
	if not meta.has("nexus_bone_attachment"):
		if node.has_meta("extras"):
			var ex = node.get_meta("extras")
			if ex is Dictionary:
				if ex.has("nexus_bone_attachment"):
					meta = ex
				elif ex.has("NEXUS_NODE_METADATA"):
					var inner = ex["NEXUS_NODE_METADATA"]
					if inner is Dictionary and inner.has("nexus_bone_attachment"):
						meta = inner
		if not meta.has("nexus_bone_attachment"):
			return false

	var bone_name = meta["nexus_bone_attachment"].get("bone_name")
	if not bone_name:
		push_warning("Nexus Attacher: Bone attachment metadata found on '%s', but 'bone_name' is missing." % node.name)
		return false
	
	var skeleton = _find_skeleton_in_scene(root)
	if not skeleton:
		push_warning("Nexus Attacher: Could not find a Skeleton3D node in the scene for node '%s'. Cannot create attachment." % node.name)
		return false

	# Never attach the skeleton/armature node to a bone – would create a cyclic dependency (Armature -> Attachment -> Armature).
	if node == skeleton or node.is_ancestor_of(skeleton):
		return false

	# Godot's glTF importer converts ":" to "_" in bone names (e.g. mixamorig:RightHand -> mixamorig_RightHand)
	var godot_bone_name = bone_name.replace(":", "_")
	
	var bone_idx = skeleton.find_bone(godot_bone_name)
	if bone_idx < 0:
		push_warning("Nexus Attacher: Bone '%s' not found in skeleton for node '%s'." % [godot_bone_name, node.name])
		return false
	
	var attachment_data = meta["nexus_bone_attachment"]
	var offset = Transform3D.IDENTITY
	var skel_scale = _get_armature_scale(root, skeleton)

	var use_blender_offset = attachment_data.has("offset_translation")
	var ot = attachment_data.get("offset_translation", [])
	var offset_is_zero = use_blender_offset and ot.size() >= 3 and abs(ot[0]) < 0.0001 and abs(ot[1]) < 0.0001 and abs(ot[2]) < 0.0001

	var use_blender_scale = attachment_data.has("offset_scale") and attachment_data["offset_scale"].size() >= 3
	var scale_for_basis := Vector3.ONE
	if use_blender_scale:
		var os = attachment_data["offset_scale"]
		scale_for_basis = Vector3(os[0], os[1], os[2])
	elif skel_scale.x > 0.0001 and skel_scale.y > 0.0001 and skel_scale.z > 0.0001:
		scale_for_basis = Vector3(1.0 / skel_scale.x, 1.0 / skel_scale.y, 1.0 / skel_scale.z)

	if use_blender_offset and not offset_is_zero:
		# Blender pre-computed offset – use directly, preserve user transform (translation, rotation, scale)
		offset.origin = Vector3(
			attachment_data["offset_translation"][0],
			attachment_data["offset_translation"][1],
			attachment_data["offset_translation"][2]
		)
		var basis_rot = Basis.IDENTITY
		if attachment_data.has("offset_rotation"):
			var r = attachment_data["offset_rotation"]
			basis_rot = Basis(Quaternion(r[0], r[1], r[2], r[3]))
		offset.basis = basis_rot * Basis.from_scale(scale_for_basis)
		if skel_scale.x > 0.0001 and skel_scale.y > 0.0001 and skel_scale.z > 0.0001:
			offset.origin *= Vector3(1.0 / skel_scale.x, 1.0 / skel_scale.y, 1.0 / skel_scale.z)
	else:
		# Fallback: offset_translation missing or (0,0,0) – read world transform from glTF (now correct after Blender fix)
		var empty_world: Transform3D
		var gltf_path = root.get_meta("_nexus_gltf_path", "")
		var world_xform = _get_node_world_transform_from_gltf(gltf_path, node.name, meta, true)
		if world_xform != null:
			empty_world = world_xform
		else:
			# Last resort: use node transform (may be wrong). During _post_import nodes may not be in tree.
			if node.is_inside_tree():
				skeleton.force_update_bone_child_transform(bone_idx)
				empty_world = node.global_transform
			else:
				empty_world = _get_accumulated_transform(node, root)
		var skel_world = skeleton.global_transform if skeleton.is_inside_tree() else _get_accumulated_transform(skeleton, root)
		var bone_world = skel_world * skeleton.get_bone_global_rest(bone_idx)
		offset = _compute_bone_relative_offset(bone_world, empty_world, skel_scale)
	
	var parent = node.get_parent()
	if not parent:
		push_error("Nexus Attacher: Placeholder node '%s' has no parent." % node.name)
		return false

	# Reuse existing ModifierBoneTarget3D if we already created one; otherwise create new (replacing any BoneAttachment3D from glTF).
	var bone_attachment: ModifierBoneTarget3D
	if parent is ModifierBoneTarget3D and _is_skeleton_child(parent, skeleton):
		bone_attachment = parent
		bone_attachment.name = node.name + "_Attachment"
		bone_attachment.set_bone_name(godot_bone_name)
		bone_attachment.transform = Transform3D.IDENTITY
		bone_attachment.owner = root
	else:
		bone_attachment = ModifierBoneTarget3D.new()
		bone_attachment.name = node.name + "_Attachment"
		bone_attachment.set_bone_name(godot_bone_name)
		bone_attachment.transform = Transform3D.IDENTITY
		skeleton.add_child(bone_attachment)
		bone_attachment.owner = root
		parent.remove_child(node)
		node.owner = null
		bone_attachment.add_child(node)
	node.owner = root
	node.transform = offset

	# When using Blender offset_scale, do not overwrite node.scale (it is already in node.transform). Otherwise compensate skeleton scale for world scale 1.0.
	var did_set_scale = false
	if skel_scale.x > 0.0001 and skel_scale.y > 0.0001 and skel_scale.z > 0.0001 and not use_blender_scale:
		var inv_skel = Vector3(1.0 / skel_scale.x, 1.0 / skel_scale.y, 1.0 / skel_scale.z)
		node.scale = inv_skel
		did_set_scale = true

	if OS.is_debug_build():
		print("Nexus Processor: ModifierBoneTarget '%s' -> bone '%s' | pos=%s scale=%s" % [node.name, godot_bone_name, node.position, node.scale])
	return true


## Reads glTF JSON and returns the world transform of the node with nexus_bone_attachment.
## Returns null if file cannot be read or node not found.
## When ignore_scale is true, the target node's scale is treated as 1 (position+rotation only).
## This avoids Blender's display scale (e.g. 100) from affecting the bone attachment offset.
func _get_node_world_transform_from_gltf(gltf_path: String, node_name: String, meta: Dictionary, ignore_scale: bool = false):
	if gltf_path.is_empty():
		return null
	if not FileAccess.file_exists(gltf_path):
		return null
	var json_text: String = NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return null
	var json = JSON.new()
	var err = json.parse(json_text)
	if err != OK:
		return null
	var gltf = json.get_data()
	if gltf == null:
		return null
	var nodes = gltf.get("nodes", [])
	if nodes.is_empty():
		return null
	# Find node: prioritize nexus_bone_attachment (name match first), then name (ensures correct node in sibling/child structures)
	var target_idx = -1
	var fallback_bone_attachment_idx = -1
	for i in range(nodes.size()):
		var n = nodes[i]
		var extras = n.get("extras", {})
		var node_meta = extras.get("NEXUS_NODE_METADATA", {})
		if node_meta.has("nexus_bone_attachment"):
			if fallback_bone_attachment_idx < 0:
				fallback_bone_attachment_idx = i
			if n.get("name", "") == node_name:
				target_idx = i
				break
	if target_idx < 0:
		target_idx = fallback_bone_attachment_idx
	if target_idx < 0:
		for i in range(nodes.size()):
			if nodes[i].get("name", "") == node_name:
				target_idx = i
				break
	if target_idx < 0:
		return null
	# Build parent map: parent[child_idx] = parent_idx (use int - JSON may parse numbers as float)
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
		var children = pnode.get("children", [])
		for ci in children:
			parent_map[int(ci)] = pi
			stack.append(int(ci))
	# Walk up from target to root, collect transform chain (idx as int for parent_map lookup)
	var chain: Array = []
	var idx = int(target_idx)
	while idx >= 0:
		var n = nodes[idx] if idx < nodes.size() else {}
		var use_scale_one = ignore_scale and (idx == target_idx)
		var t = _parse_gltf_node_transform(n, use_scale_one)
		chain.append(t)
		idx = parent_map.get(idx, -1)
	# chain is [child, ..., parent] (target first, root last). World = parent * child.
	# Reverse for [parent, child]; then chain[i]*world (i descending) gives parent * child.
	chain.reverse()
	var world = Transform3D.IDENTITY
	for i in range(chain.size() - 1, -1, -1):
		world = chain[i] * world
	return world


func _parse_gltf_node_transform(n: Dictionary, use_scale_one: bool = false) -> Transform3D:
	var t_arr = n.get("translation", [0.0, 0.0, 0.0])
	var r_arr = n.get("rotation", [0.0, 0.0, 0.0, 1.0])
	var s_arr = [1.0, 1.0, 1.0] if use_scale_one else n.get("scale", [1.0, 1.0, 1.0])
	var origin = Vector3(
		_get_float(t_arr, 0), _get_float(t_arr, 1), _get_float(t_arr, 2)
	)
	var q = Quaternion(_get_float(r_arr, 0), _get_float(r_arr, 1), _get_float(r_arr, 2), _get_float(r_arr, 3))
	var scale = Vector3(_get_float(s_arr, 0), _get_float(s_arr, 1), _get_float(s_arr, 2))
	return Transform3D(Basis(q) * Basis.from_scale(scale), origin)


## Computes bone-relative offset with scale correction. Used by fallback path; testable.
func _compute_bone_relative_offset(bone_world: Transform3D, empty_world: Transform3D, skel_scale: Vector3) -> Transform3D:
	var offset = bone_world.affine_inverse() * empty_world
	if skel_scale.x > 0.0001 and skel_scale.y > 0.0001 and skel_scale.z > 0.0001:
		offset.basis = offset.basis * Basis.from_scale(Vector3(1.0 / skel_scale.x, 1.0 / skel_scale.y, 1.0 / skel_scale.z))
	return offset


func _get_float(arr: Array, i: int) -> float:
	if i >= arr.size():
		return 0.0 if i < 3 else 1.0
	var v = arr[i]
	if v is float:
		return v
	if v is int:
		return float(v)
	return 0.0


## Returns the scale from the Armature (or first ancestor with scale != 1).
## Uses local transform hierarchy when nodes are not in tree (during _post_import).
func _get_armature_scale(root: Node, skeleton: Skeleton3D) -> Vector3:
	var armature = _find_node_by_name(root, "Armature")
	if armature:
		var scale_acc = _get_accumulated_scale(armature, root)
		if scale_acc.x < 0.9 or scale_acc.y < 0.9 or scale_acc.z < 0.9:
			return scale_acc
	var scale_acc = _get_accumulated_scale(skeleton, root)
	if scale_acc.x < 0.9 or scale_acc.y < 0.9 or scale_acc.z < 0.9:
		return scale_acc
	return Vector3(1.0, 1.0, 1.0)

## Accumulated world transform from root to node (works when not in tree). Uses local transform only.
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

## Accumulated scale from root to node (works when not in tree). Uses local transform only.
func _get_accumulated_scale(node: Node, root: Node) -> Vector3:
	var path: Array[Node] = []
	var n: Node = node
	while is_instance_valid(n):
		path.append(n)
		if n == root:
			break
		n = n.get_parent()
	if path.is_empty():
		return Vector3(1.0, 1.0, 1.0)
	path.reverse()
	var s = Vector3(1.0, 1.0, 1.0)
	for nd in path:
		if nd is Node3D:
			s = s * nd.transform.basis.get_scale()
	return s


func _find_node_by_name(n: Node, name: String) -> Node:
	if n.name == name:
		return n
	for c in n.get_children():
		var found = _find_node_by_name(c, name)
		if found:
			return found
	return null


## Returns true if node is a direct child of skeleton.
func _is_skeleton_child(node: Node, skeleton: Skeleton3D) -> bool:
	return node.get_parent() == skeleton


# Helper to find the first available Skeleton3D node in the scene tree.
func _find_skeleton_in_scene(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
		
	for child in root.get_children():
		var found = _find_skeleton_in_scene(child)
		if is_instance_valid(found):
			return found
			
	return null
