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
