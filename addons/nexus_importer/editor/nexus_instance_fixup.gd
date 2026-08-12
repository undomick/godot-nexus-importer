class_name NexusInstanceFixup
extends RefCounted

## Resolves composition glTF placeholders in memory without a full glTF reimport.

const InstancingProcessor = preload("res://addons/nexus_importer/processors/instancing_processor.gd")

var _instancing_processor: InstancingProcessor


func _init() -> void:
	_instancing_processor = InstancingProcessor.new()


func resolve_composition_instances(gltf_path: String) -> Dictionary:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return _failure("glTF file missing")

	if not ResourceLoader.exists(gltf_path):
		return _failure("glTF not imported yet")

	var root: Node = NexusSceneUtils.instantiate_scene_reference(gltf_path)
	if root == null:
		return _failure("could not instantiate imported glTF")

	root.set_meta("_nexus_gltf_path", gltf_path)
	NexusSceneUtils.inject_nexus_node_extras_from_gltf(root, gltf_path)
	_instancing_processor.reset_import_budget()

	var resolved := _resolve_instances_in_tree(root)
	resolved += _instancing_processor.retry_pending_instances(root)

	return {
		"ok": true,
		"instances_resolved": resolved,
		"root": root,
		"error": "",
	}


func free_resolved_root(root: Node) -> void:
	if root != null and is_instance_valid(root):
		root.free()


func _failure(reason: String) -> Dictionary:
	return {"ok": false, "instances_resolved": 0, "root": null, "error": reason}


func _resolve_instances_in_tree(root: Node) -> int:
	var resolved := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for i in range(node.get_child_count() - 1, -1, -1):
			stack.append(node.get_child(i))

		var node_meta := NexusSceneUtils.get_node_nexus_meta(node)
		if node_meta.is_empty():
			continue
		if node_meta.get("nexus_is_lod", false):
			continue
		if not node_meta.has("nexus_asset_id") and not node_meta.has("nexus_placeholder_path"):
			continue

		if _instancing_processor.process(node, node_meta, root):
			resolved += 1
	return resolved
