class_name NexusTransformSanitize
extends RefCounted

## Shared guard against degenerate / non-finite Node transforms before they reach
## Godot subsystems (physics planes, light culler, affine_inverse) that warn or
## fail on NaN/Inf or singular bases.

const MIN_BASIS_DETERMINANT := 0.000001
const MIN_AXIS_SCALE := 0.000001


static func sanitize(transform: Transform3D, label: String = "") -> Transform3D:
	var origin := transform.origin
	var basis := transform.basis
	var origin_ok := origin.is_finite()
	var basis_ok := _basis_is_usable(basis)
	if origin_ok and basis_ok:
		return transform
	if not label.is_empty():
		push_warning("Nexus Importer: Degenerate transform on '%s'; using fallback." % label)
	var safe_origin := origin if origin_ok else Vector3.ZERO
	var safe_basis := basis if basis_ok else Basis.IDENTITY
	return Transform3D(safe_basis, safe_origin)


# Walk the imported scene once and neutralize any Node3D transform that would
# feed NaN/Inf or a singular basis into Godot's rendering/physics math
# (light culler, physics planes, affine_inverse). Valid finite non-singular
# transforms pass through unchanged on the fast path inside sanitize().
static func sanitize_scene_transforms(root: Node) -> int:
	return _sanitize_transforms_recursive(root)


static func sanitize_animation_tracks(anim: Animation) -> int:
	if anim == null:
		return 0
	var fixed := 0
	for i in range(anim.get_track_count()):
		var type := anim.track_get_type(i)
		for k in range(anim.track_get_key_count(i)):
			var value = anim.track_get_key_value(i, k)
			var sanitized = _sanitize_track_key(type, value)
			if sanitized != value:
				anim.track_set_key_value(i, k, sanitized)
				fixed += 1
	return fixed


# Godot 4.7 returns IDENTITY for off-tree global_transform; compose the local chain.
static func composed_global_transform(node_3d: Node3D) -> Transform3D:
	if node_3d == null:
		return Transform3D.IDENTITY
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


## Node transform in root's local space (root.transform not applied).
static func transform_relative_to(root: Node, node: Node) -> Transform3D:
	if node == null or root == null or node == root:
		return Transform3D.IDENTITY
	if not node is Node3D:
		return Transform3D.IDENTITY
	if root is Node3D and node.is_inside_tree() and (root as Node3D).is_inside_tree():
		return (root as Node3D).global_transform.affine_inverse() * (node as Node3D).global_transform

	var t := (node as Node3D).transform
	var p: Node = node.get_parent()
	while p and p != root:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


## Accumulated transform from root down to node (includes root.transform).
static func accumulated_transform(node: Node, root: Node) -> Transform3D:
	if node == null:
		return Transform3D.IDENTITY
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
	var t := Transform3D.IDENTITY
	for nd in path:
		if nd is Node3D:
			t = t * (nd as Node3D).transform
	return t


static func _sanitize_transforms_recursive(node: Node) -> int:
	var fixed := 0
	if node is Node3D:
		var node3d := node as Node3D
		var before := node3d.transform
		var after := sanitize(before, str(node3d.name))
		if after != before:
			node3d.transform = after
			fixed += 1
	for child in node.get_children():
		fixed += _sanitize_transforms_recursive(child)
	return fixed


static func _basis_is_usable(basis: Basis) -> bool:
	if not _basis_is_finite(basis):
		return false
	if absf(basis.determinant()) >= MIN_BASIS_DETERMINANT:
		return true
	var scale := basis.get_scale()
	if not scale.is_finite():
		return false
	return scale.x >= MIN_AXIS_SCALE and scale.y >= MIN_AXIS_SCALE and scale.z >= MIN_AXIS_SCALE


static func _basis_is_finite(basis: Basis) -> bool:
	for col in [basis.x, basis.y, basis.z]:
		if not col.is_finite():
			return false
	return true


static func _sanitize_track_key(type: int, value: Variant) -> Variant:
	if type == Animation.TYPE_POSITION_3D:
		if value is Vector3 and not (value as Vector3).is_finite():
			return Vector3.ZERO
	elif type == Animation.TYPE_ROTATION_3D:
		if value is Quaternion and not (value as Quaternion).is_finite():
			return Quaternion.IDENTITY
	elif type == Animation.TYPE_SCALE_3D:
		if value is Vector3 and not (value as Vector3).is_finite():
			return Vector3.ONE
	return value
