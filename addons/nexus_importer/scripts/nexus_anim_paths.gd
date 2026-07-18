class_name NexusAnimPaths
extends RefCounted

## Animation track NodePath helpers: strip stale instance hops and resolve paths from AnimationPlayer.


static func split_track_path(path: NodePath) -> Dictionary:
	var path_str := str(path)
	var colon_idx := path_str.rfind(":")
	if colon_idx < 0:
		return {"node_path": path, "suffix": ""}
	return {
		"node_path": NodePath(path_str.substr(0, colon_idx)),
		"suffix": path_str.substr(colon_idx),
	}


static func join_track_path(node_path: NodePath, suffix: String) -> NodePath:
	if suffix.is_empty():
		return node_path
	return NodePath(str(node_path) + suffix)


static func strip_stale_hierarchy_prefixes(
	node_path: NodePath, anim_player: AnimationPlayer
) -> NodePath:
	if not is_instance_valid(anim_player):
		return node_path
	var parent := anim_player.get_parent()
	if parent == null:
		return node_path

	var asset_root_name := parent.name
	var names: PackedStringArray = []
	for i in range(node_path.get_name_count()):
		names.append(node_path.get_name(i))

	var idx := 0
	while idx < names.size() - 1 and names[idx] == "..":
		if names[idx + 1] == asset_root_name:
			idx += 2
			continue
		break

	if idx == 0:
		return node_path

	var rest: PackedStringArray = []
	for j in range(idx, names.size()):
		rest.append(names[j])
	return _names_to_node_path(rest)


static func resolve_track_path_for_player(
	old_path: NodePath,
	anim_player: AnimationPlayer,
	search_root: Node = null
) -> NodePath:
	if not is_instance_valid(anim_player) or old_path.is_empty():
		return old_path

	var split := split_track_path(old_path)
	var node_path: NodePath = split.node_path
	var suffix: String = split.suffix

	if node_path.get_name_count() == 1 and node_path.get_name(0) == ".":
		return old_path

	var resolved := _resolve_node(node_path, anim_player, search_root)
	if resolved == null:
		var stripped := strip_stale_hierarchy_prefixes(node_path, anim_player)
		if str(stripped) != str(node_path):
			resolved = _resolve_node(stripped, anim_player, search_root)
		if resolved == null and not str(stripped).begins_with(".."):
			resolved = _resolve_node(NodePath("../" + str(stripped)), anim_player, search_root)

	if resolved != null:
		return join_track_path(anim_player.get_path_to(resolved), suffix)

	var skeleton_fallback := _resolve_skeleton_track_fallback(suffix, anim_player)
	if not skeleton_fallback.is_empty():
		return skeleton_fallback

	return old_path


static func retarget_animation_for_player(
	anim: Animation, anim_player: AnimationPlayer, search_root: Node
) -> void:
	if anim == null or not is_instance_valid(anim_player):
		return
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) == Animation.TYPE_METHOD:
			continue
		var old_path = anim.track_get_path(i)
		var new_path = resolve_track_path_for_player(old_path, anim_player, search_root)
		if str(new_path) != str(old_path):
			anim.track_set_path(i, new_path)


static func retarget_player_libraries(
	anim_player: AnimationPlayer, search_root: Node
) -> void:
	if not is_instance_valid(anim_player):
		return
	for lib_name in anim_player.get_animation_library_list():
		var library = anim_player.get_animation_library(lib_name)
		if library == null:
			continue
		for anim_name in library.get_animation_list():
			var anim = library.get_animation(anim_name)
			if anim:
				retarget_animation_for_player(anim, anim_player, search_root)


static func anchor_relative_path(old_path: NodePath, anchor_name: String) -> NodePath:
	if anchor_name.is_empty():
		return old_path
	var node_target_name = old_path.get_name(0)
	if node_target_name == anchor_name:
		return NodePath(".:" + old_path.get_concatenated_subnames())
	if node_target_name == ".":
		return NodePath(".:" + old_path.get_concatenated_subnames())
	return old_path


static func skeleton_bone_alias_map(skeleton: Skeleton3D) -> Dictionary:
	var lookup: Dictionary = {}
	for i in range(skeleton.get_bone_count()):
		var canonical := skeleton.get_bone_name(i)
		lookup[canonical] = canonical
		var underscore := canonical.replace(":", "_")
		if underscore != canonical:
			lookup[underscore] = canonical
	return lookup


static func resolve_skeleton_bone_suffix(suffix: String, bone_aliases: Dictionary) -> String:
	if suffix.is_empty() or not suffix.begins_with(":"):
		return suffix
	if bone_aliases.is_empty():
		return suffix
	var bone_name := suffix.substr(1)
	if bone_aliases.has(bone_name):
		return ":" + str(bone_aliases[bone_name])
	return suffix


static func _resolve_skeleton_track_fallback(
	suffix: String, anim_player: AnimationPlayer
) -> NodePath:
	if suffix.is_empty() or not suffix.begins_with(":"):
		return NodePath()
	var parent := anim_player.get_parent()
	if parent == null:
		return NodePath()
	var skel := _find_first_skeleton(parent)
	if skel == null:
		return NodePath()
	return join_track_path(anim_player.get_path_to(skel), suffix)


static func _find_first_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_first_skeleton(child)
		if found:
			return found
	return null


static func _resolve_node(
	node_path: NodePath, anim_player: AnimationPlayer, search_root: Node
) -> Node:
	var n := anim_player.get_node_or_null(node_path)
	if n:
		return n
	var parent := anim_player.get_parent()
	if parent:
		n = parent.get_node_or_null(node_path)
		if n:
			return n
	if is_instance_valid(search_root):
		n = search_root.get_node_or_null(node_path)
		if n:
			return n
	return null


static func _names_to_node_path(names: PackedStringArray) -> NodePath:
	if names.is_empty():
		return NodePath(".")
	var parts: PackedStringArray = []
	for n in names:
		parts.append(str(n))
	return NodePath(String("/").join(parts))
