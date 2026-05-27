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


static func resolve_packed_scene_path(candidate: String) -> String:
	if candidate.is_empty():
		return ""

	var normalized := candidate.replace("\\", "/").strip_edges()
	if normalized.is_empty():
		return ""

	var paths_to_try: Array[String] = []
	paths_to_try.append(normalized)
	paths_to_try.append_array(_scene_path_fallbacks(normalized))

	var seen: Dictionary = {}
	for path in paths_to_try:
		if path.is_empty() or seen.has(path):
			continue
		seen[path] = true
		if ResourceLoader.exists(path):
			return path
	return ""


static func _scene_path_fallbacks(path: String) -> Array[String]:
	var result: Array[String] = []
	var gltf_base := ""

	if NexusUtils.is_gltf_container_path(path):
		gltf_base = path
	else:
		var ext := path.get_extension().to_lower()
		if ext == "tscn":
			var dir := path.get_base_dir()
			var stem := path.get_file().get_basename()
			stem = _strip_scene_style_suffix(stem)
			var gltf_candidate := dir.path_join(stem + ".gltf")
			if ResourceLoader.exists(gltf_candidate) or FileAccess.file_exists(gltf_candidate):
				gltf_base = gltf_candidate
			else:
				var glb_candidate := dir.path_join(stem + ".glb")
				if ResourceLoader.exists(glb_candidate) or FileAccess.file_exists(glb_candidate):
					gltf_base = glb_candidate

	if gltf_base.is_empty():
		return result

	result.append(NexusPaths.wrapper_path_for(gltf_base))
	result.append(NexusPaths.inherited_path_for(gltf_base))
	var base_no_ext := gltf_base.get_basename()
	result.append(base_no_ext + "_editable.tscn")
	result.append(base_no_ext + ".tscn")
	result.append(gltf_base)
	return result


static func _strip_scene_style_suffix(stem: String) -> String:
	if stem.ends_with("_wrapper"):
		return stem.trim_suffix("_wrapper")
	if stem.ends_with("_inherited"):
		return stem.trim_suffix("_inherited")
	if stem.ends_with("_editable"):
		return stem.trim_suffix("_editable")
	return stem
