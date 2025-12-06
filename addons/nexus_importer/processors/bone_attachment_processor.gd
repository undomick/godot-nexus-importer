# file: addons/nexus_importer/processors/bone_attachment_processor.gd
@tool
extends Object

# This function finds a placeholder, creates a BoneAttachment3D node,
# and reparents the original node to be a child of the new attachment.
# Returns 'true' if the node was reparented, 'false' otherwise.
func process(node: Node3D, meta: Dictionary, root: Node) -> bool:
	if not "nexus_bone_attachment" in meta:
		return false
	
	var bone_name = meta["nexus_bone_attachment"].get("bone_name")
	if not bone_name:
		push_warning("Nexus Attacher: Bone attachment metadata found on '%s', but 'bone_name' is missing." % node.name)
		return false
	
	var skeleton = _find_skeleton_in_scene(root)
	if not skeleton:
		push_warning("Nexus Attacher: Could not find a Skeleton3D node in the scene for node '%s'. Cannot create attachment." % node.name)
		return false
		
	var bone_attachment = BoneAttachment3D.new()
	bone_attachment.name = node.name + "_Attachment" # Give the attachment a distinct name
	bone_attachment.set_bone_name(bone_name)
	
	var parent = node.get_parent()
	if not parent:
		push_error("Nexus Attacher: Placeholder node '%s' has no parent." % node.name)
		return false
		
	# The transform of the attachment node itself should be relative to the skeleton,
	# so we set it to identity. The attached object retains its local transform.
	bone_attachment.transform = Transform3D.IDENTITY
	
	# Reparent the new attachment node
	parent.add_child(bone_attachment)
	bone_attachment.owner = root
	
	# CRITICAL: The original node is now moved to be a child of the BoneAttachment.
	# It keeps its original local transform relative to the new parent.
	parent.remove_child(node)
	bone_attachment.add_child(node)
	node.owner = root # Ensure the moved node is still part of the scene
	
	print("Nexus Processor: Created BoneAttachment for '%s' on bone '%s'." % [node.name, bone_name])
	return true


# Helper to find the first available Skeleton3D node in the scene tree.
func _find_skeleton_in_scene(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
		
	for child in root.get_children():
		var found = _find_skeleton_in_scene(child)
		if is_instance_valid(found):
			return found
			
	return null
