class_name NexusSceneUtils
extends RefCounted

## Tree walks and filesystem helpers shared by import processors and editor tools.


static func find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root
	for child in root.get_children():
		var found = find_animation_player(child)
		if found:
			return found
	return null


static func find_first_node_of_type(root: Node, class_type: StringName) -> Node:
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.is_class(class_type):
			return current
		for child in current.get_children():
			queue.push_back(child)
	return null


static func collect_files_with_extensions(folder_path: String, extensions: Array) -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(folder_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = folder_path.path_join(name)
		if dir.current_is_dir():
			result.append_array(collect_files_with_extensions(full, extensions))
		else:
			var ext = name.get_extension().to_lower()
			if ext in extensions:
				result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result


static func collect_gltfs_recursive(folder_path: String) -> Array[String]:
	var result: Array[String] = []
	var dir = DirAccess.open(folder_path)
	if not dir:
		return result
	dir.list_dir_begin()
	var name = dir.get_next()
	while not name.is_empty():
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = folder_path.path_join(name)
		if dir.current_is_dir():
			result.append_array(collect_gltfs_recursive(full))
		elif NexusUtils.is_gltf_container_path(full):
			result.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return result
