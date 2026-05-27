extends Node

## Legacy fallback for glTF imports created before visibility ranges were baked at import time.
## New imports set GeometryInstance3D.visibility_range_* directly and do not add this node.

const FADE_MODE = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


func _ready() -> void:
	call_deferred("_apply_and_remove")


func _apply_and_remove() -> void:
	var root = get_parent()
	if not root:
		queue_free()
		return
	_apply_recursive(root)
	queue_free()


func _apply_recursive(node: Node) -> void:
	if node == self:
		return
	if node is GeometryInstance3D and node.has_meta("nexus_visibility_range"):
		var range_data = node.get_meta("nexus_visibility_range")
		if range_data is Dictionary:
			node.visibility_range_begin = range_data.get("begin", 0.0)
			node.visibility_range_begin_margin = range_data.get("begin_margin", 0.0)
			node.visibility_range_end = range_data.get("end", 0.0)
			node.visibility_range_end_margin = range_data.get("end_margin", 0.0)
			node.visibility_range_fade_mode = FADE_MODE
			node.remove_meta("nexus_visibility_range")
	for child in node.get_children():
		_apply_recursive(child)
