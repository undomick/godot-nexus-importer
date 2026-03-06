extends Node3D

## Attachment Follower: Attaches this asset to a Node3D within a sibling scene.
## E.g. place a weapon in the wrapper scene, set target_node_path to "Character/hand_R_Attachment".
## Path is relative to the common parent (wrapper root).

@export var target_node_path: NodePath = NodePath()

func _ready() -> void:
	if target_node_path.is_empty():
		push_warning("AttachmentFollower: target_node_path is empty.")
		return

	var parent = get_parent()
	if not parent:
		push_warning("AttachmentFollower: No parent found.")
		return

	var target = parent.get_node_or_null(target_node_path)
	if not target:
		var path_str = str(target_node_path)
		if path_str.begins_with("../"):
			var fallback_path = path_str.substr(3)
			target = parent.get_node_or_null(fallback_path)
	if not target:
		push_warning("AttachmentFollower: Target '%s' not found." % str(target_node_path))
		return

	if not target is Node3D:
		push_warning("AttachmentFollower: Target '%s' is not a Node3D." % str(target_node_path))
		return

	# Capture local offset relative to target AT THE SAME MOMENT (same frame).
	# Otherwise animation may change target pose between _ready and deferred reparent.
	var target_global := (target as Node3D).global_transform
	var local_offset := target_global.affine_inverse() * global_transform
	call_deferred("_call_deferred_reparent", parent, target, local_offset)


func _call_deferred_reparent(old_parent: Node, target_node: Node3D, local_offset: Transform3D) -> void:
	if not is_instance_valid(self) or not is_instance_valid(old_parent) or not is_instance_valid(target_node):
		return
	if get_parent():
		get_parent().remove_child(self)
	target_node.add_child(self)
	transform = local_offset
