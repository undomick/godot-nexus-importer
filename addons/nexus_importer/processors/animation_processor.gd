@tool
extends Object

const NEXUS_ANIM_PLAYER_PATH = "AnimationPlayer"


func manifest_key_for_gltf_animation(anim_name: String, scene_meta: Dictionary) -> String:
	var loop_data = scene_meta.get("nexus_animation_loops", {})
	if loop_data.has(anim_name):
		return anim_name

	var rename_map = scene_meta.get("animation_rename_map", {})
	if rename_map is Dictionary:
		for action_name in rename_map.keys():
			var entry = rename_map[action_name]
			if entry is Dictionary and str(entry.get("new_name", "")) == anim_name:
				return str(action_name)

	return anim_name


func apply_scene_retargeting(_scene_root: Node, _anim_player: AnimationPlayer) -> void:
	pass


func extract_and_save_animations(
	scene_root: Node,
	gltf_path: String,
	scene_meta: Dictionary,
	scene_style: String = ""
) -> Dictionary:
	var stats = {"extracted": 0, "path": ""}

	var internal_player = NexusSceneUtils.find_animation_player(scene_root)
	if not internal_player:
		return stats

	if not internal_player.has_animation_library(""):
		return stats

	var library = internal_player.get_animation_library("")
	if not library:
		return stats

	var save_path: String
	var target_instance_name: String
	var raw_target_animlib := str(scene_meta.get("target_animlib_path", ""))
	var target_animlib_path := NexusUtils.validate_index_path(raw_target_animlib)
	if not raw_target_animlib.is_empty() and target_animlib_path.is_empty():
		push_warning(
			"Nexus Animation: Rejected unsafe target_animlib_path '%s'." % raw_target_animlib
		)
		target_animlib_path = ""
	if not target_animlib_path.is_empty():
		save_path = target_animlib_path
		target_instance_name = scene_meta.get("target_instance_name", "")
		if target_instance_name.is_empty():
			var stem = target_animlib_path.get_file().get_basename()
			target_instance_name = stem.replace("_animations", "") if stem.ends_with("_animations") else stem
	else:
		var base_dir = gltf_path.get_base_dir()
		var file_name = gltf_path.get_file().get_basename()
		save_path = base_dir.path_join(file_name + "_anims.res")
		target_instance_name = file_name

	var anchor_node_name = _find_anchor_node_name(scene_root)
	if anchor_node_name != "":
		print_verbose("Nexus Animation: Detected Root Motion Anchor on node '%s'" % anchor_node_name)

	var existing_lib: AnimationLibrary = null
	if FileAccess.file_exists(save_path):
		existing_lib = ResourceLoader.load(save_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)

	var target_skeleton_node_path := ""
	var target_bone_aliases: Dictionary = {}
	if not target_animlib_path.is_empty():
		var target_skeleton_gltf_path := _resolve_target_skeleton_gltf_path(
			scene_meta, target_animlib_path, target_instance_name
		)
		if not target_skeleton_gltf_path.is_empty():
			target_skeleton_node_path = _resolve_skeleton_node_path_from_gltf(target_skeleton_gltf_path)
			target_bone_aliases = _load_skeleton_bone_aliases_from_gltf(target_skeleton_gltf_path)
		if target_skeleton_node_path.is_empty():
			push_warning(
				"Nexus Animation: ANIMATION_LIB could not resolve target skeleton path "
				+ "(target_asset_path '%s', target_instance '%s'). Bone tracks may not play on the character."
				% [target_skeleton_gltf_path, target_instance_name]
			)

	var new_lib = _merge_animation_library(
		library,
		existing_lib,
		scene_meta,
		internal_player,
		scene_root,
		target_instance_name,
		anchor_node_name,
		target_skeleton_node_path,
		target_bone_aliases,
		stats
	)

	var err = ResourceSaver.save(new_lib, save_path)
	if err != OK:
		push_error(
			"Nexus Animation: Failed to save animation library '%s': %s"
			% [save_path.get_file(), error_string(err)]
		)
		stats.extracted = 0
		stats.path = ""
		return stats

	stats.path = save_path
	print_verbose("Nexus Animation: Extracted %d animations to '%s'" % [stats.extracted, save_path.get_file()])
	# Wrapper style owns its AnimationPlayer as a sibling of the subscene
	# instance (built by nexus_wrapper_builder), so the imported subscene must
	# not retain any player. Remove it outright; inherited/other styles keep the
	# empty placeholder so the native player slot stays present.
	if scene_style == NexusPaths.SCENE_STYLE_WRAPPER:
		_remove_player(internal_player)
	else:
		_replace_player_with_placeholder(internal_player, scene_root)
	return stats


func _merge_animation_library(
	source_library: AnimationLibrary,
	existing_lib: AnimationLibrary,
	scene_meta: Dictionary,
	anim_player: AnimationPlayer,
	search_root: Node,
	_target_instance_name: String,
	anchor_node_name: String,
	target_skeleton_node_path: String,
	target_bone_aliases: Dictionary,
	stats: Dictionary
) -> AnimationLibrary:
	var new_lib = AnimationLibrary.new()
	var loop_data = scene_meta.get("nexus_animation_loops", {})
	var marker_data = scene_meta.get("nexus_animation_markers", {})
	var root_motion_data = scene_meta.get("nexus_animation_root_motion", {})

	for anim_name in source_library.get_animation_list():
		var source_anim: Animation = source_library.get_animation(anim_name)
		var manifest_key = manifest_key_for_gltf_animation(anim_name, scene_meta)
		var final_anim: Animation
		if existing_lib and existing_lib.has_animation(anim_name):
			var existing_anim: Animation = existing_lib.get_animation(anim_name)
			if _animation_is_stale_single_key(existing_anim) and _source_has_multi_key_motion(source_anim):
				final_anim = source_anim.duplicate()
				_repath_tracks(final_anim, anim_player, search_root, anchor_node_name)
			else:
				final_anim = existing_anim
				_update_transform_tracks(
					final_anim, source_anim, anim_player, search_root, anchor_node_name
				)
		else:
			final_anim = source_anim.duplicate()
			_repath_tracks(final_anim, anim_player, search_root, anchor_node_name)

		if not target_skeleton_node_path.is_empty():
			_remap_animation_skeleton_paths(final_anim, target_skeleton_node_path, target_bone_aliases)

		if loop_data.has(manifest_key):
			match loop_data[manifest_key]:
				"LOOP": final_anim.loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": final_anim.loop_mode = Animation.LOOP_PINGPONG
				"ONCE": final_anim.loop_mode = Animation.LOOP_NONE

		if root_motion_data.has(manifest_key):
			final_anim.set_meta("nexus_root_motion", true)

		if marker_data.has(manifest_key):
			add_marker_tracks(final_anim, marker_data[manifest_key])

		NexusTransformSanitize.sanitize_animation_tracks(final_anim)
		new_lib.add_animation(anim_name, final_anim)
		stats.extracted += 1

	return new_lib


func _replace_player_with_placeholder(internal_player: AnimationPlayer, scene_root: Node) -> void:
	var parent = internal_player.get_parent()
	if not parent:
		return
	var idx = internal_player.get_index()
	parent.remove_child(internal_player)
	internal_player.queue_free()
	var placeholder = AnimationPlayer.new()
	placeholder.name = "AnimationPlayer"
	parent.add_child(placeholder)
	parent.move_child(placeholder, idx)
	placeholder.owner = scene_root.owner if scene_root.owner else scene_root


func _remove_player(internal_player: AnimationPlayer) -> void:
	var parent = internal_player.get_parent()
	if parent:
		parent.remove_child(internal_player)
	internal_player.queue_free()


func _find_first_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var s: Skeleton3D = _find_first_skeleton(c)
		if s:
			return s
	return null


func _resolve_target_skeleton_gltf_path(
	scene_meta: Dictionary, target_animlib_path: String, target_instance_name: String
) -> String:
	# Prefer the explicit skeletal glTF path written by the Blender exporter; the
	# .res no longer lives next to the skeletal glTF, so the same-dir lookup is only
	# a fallback for older exports that lack target_asset_path.
	var raw_asset_path := str(scene_meta.get("target_asset_path", ""))
	var asset_path := NexusUtils.validate_index_path(raw_asset_path)
	if not raw_asset_path.is_empty() and asset_path.is_empty():
		push_warning("Nexus Animation: Rejected unsafe target_asset_path '%s'." % raw_asset_path)
	if not asset_path.is_empty() and ResourceLoader.exists(asset_path):
		return asset_path

	if target_animlib_path.is_empty() or target_instance_name.is_empty():
		return ""
	var dir := target_animlib_path.get_base_dir()
	for ext in [".gltf", ".glb"]:
		var candidate := dir.path_join(target_instance_name + ext)
		if ResourceLoader.exists(candidate):
			return candidate
	return ""


func _resolve_skeleton_node_path_from_gltf(gltf_path: String) -> String:
	var packed: PackedScene = load(gltf_path) as PackedScene
	if packed == null:
		return ""
	var inst: Node = packed.instantiate()
	var skel: Skeleton3D = _find_first_skeleton(inst)
	if skel == null:
		inst.free()
		return ""
	var out := str(inst.get_path_to(skel))
	inst.free()
	return out


func _load_skeleton_bone_aliases_from_gltf(gltf_path: String) -> Dictionary:
	var packed: PackedScene = load(gltf_path) as PackedScene
	if packed == null:
		return {}
	var inst: Node = packed.instantiate()
	var skel: Skeleton3D = _find_first_skeleton(inst)
	if skel == null:
		inst.free()
		return {}
	var aliases := NexusAnimPaths.skeleton_bone_alias_map(skel)
	inst.free()
	return aliases


func _remap_animation_skeleton_paths(
	anim: Animation, target_skeleton_path: String, bone_aliases: Dictionary = {}
) -> void:
	if target_skeleton_path.is_empty():
		return
	for i in range(anim.get_track_count()):
		if anim.track_get_type(i) == Animation.TYPE_METHOD:
			continue
		var path_str := str(anim.track_get_path(i))
		var parts := path_str.split(":", true, 1)
		if parts.size() != 2:
			continue
		var node_part: String = parts[0]
		var bone_part: String = parts[1]
		if node_part != "Skeleton3D" and not node_part.ends_with("/Skeleton3D"):
			continue
		var suffix := ":" + bone_part
		suffix = NexusAnimPaths.resolve_skeleton_bone_suffix(suffix, bone_aliases)
		if suffix.begins_with(":"):
			bone_part = suffix.substr(1)
		var new_path_str := target_skeleton_path + ":" + bone_part
		if new_path_str != path_str:
			anim.track_set_path(i, NodePath(new_path_str))


func add_marker_tracks(anim: Animation, markers: Array, track_path: NodePath = NodePath()) -> void:
	_remove_legacy_method_tracks(anim)
	anim.set_meta("nexus_markers", markers)
	var track_idx = anim.add_track(Animation.TYPE_METHOD)
	var path_to_use = track_path if not track_path.is_empty() else NodePath(NEXUS_ANIM_PLAYER_PATH)
	anim.track_set_path(track_idx, path_to_use)
	for m in markers:
		var marker_name = m.get("name", "") if m is Dictionary else str(m)
		var marker_time = m.get("time", 0.0) if m is Dictionary else 0.0
		var key_data = {"method": "on_nexus_event", "args": [marker_name]}
		anim.track_insert_key(track_idx, marker_time, key_data)


func _remove_legacy_method_tracks(anim: Animation) -> void:
	for i in range(anim.get_track_count() - 1, -1, -1):
		if anim.track_get_type(i) == Animation.TYPE_METHOD:
			for k in range(anim.track_get_key_count(i)):
				var key_val = anim.track_get_key_value(i, k)
				if key_val is Dictionary and key_val.get("method", "") == "on_nexus_event":
					anim.remove_track(i)
					break


func _find_anchor_node_name(node: Node) -> String:
	if NexusSceneUtils.get_node_nexus_meta(node).get("nexus_is_anim_anchor", false):
		return node.name
	for child in node.get_children():
		var found = _find_anchor_node_name(child)
		if found != "":
			return found
	return ""


func _calculate_new_path(
	old_path: NodePath,
	_instance_name: String,
	anchor_name: String,
	anim_player: AnimationPlayer = null,
	search_root: Node = null
) -> NodePath:
	var anchored := NexusAnimPaths.anchor_relative_path(old_path, anchor_name)
	if str(anchored) != str(old_path):
		return anchored

	var node_target_name = old_path.get_name(0)
	if node_target_name == anchor_name and anchor_name != "":
		return NodePath(".:" + old_path.get_concatenated_subnames())
	if node_target_name == ".":
		return NodePath(".:" + old_path.get_concatenated_subnames())

	if _path_has_stale_hierarchy_prefix(old_path) and is_instance_valid(anim_player):
		return NexusAnimPaths.resolve_track_path_for_player(old_path, anim_player, search_root)

	return NodePath(str(old_path))


func _path_has_stale_hierarchy_prefix(path: NodePath) -> bool:
	return path.get_name_count() >= 2 and path.get_name(0) == ".."


func _repath_tracks(
	anim: Animation, anim_player: AnimationPlayer, search_root: Node, anchor_name: String
) -> void:
	_remove_legacy_method_tracks(anim)
	for i in range(anim.get_track_count()):
		anim.track_set_path(
			i,
			_calculate_new_path(
				anim.track_get_path(i), "", anchor_name, anim_player, search_root
			)
		)


func _update_transform_tracks(
	target: Animation,
	source: Animation,
	anim_player: AnimationPlayer,
	search_root: Node,
	anchor_name: String
) -> void:
	if not _source_has_transform_keys(source):
		return

	_remove_legacy_method_tracks(target)
	for i in range(target.get_track_count() - 1, -1, -1):
		var type = target.track_get_type(i)
		if type in [
			Animation.TYPE_POSITION_3D,
			Animation.TYPE_ROTATION_3D,
			Animation.TYPE_SCALE_3D,
			Animation.TYPE_BLEND_SHAPE,
		]:
			target.remove_track(i)

	for i in range(source.get_track_count()):
		var type = source.track_get_type(i)
		if type in [
			Animation.TYPE_POSITION_3D,
			Animation.TYPE_ROTATION_3D,
			Animation.TYPE_SCALE_3D,
			Animation.TYPE_BLEND_SHAPE,
		]:
			var new_idx = target.add_track(type)
			target.track_set_path(
				new_idx,
				_calculate_new_path(
					source.track_get_path(i), "", anchor_name, anim_player, search_root
				)
			)
			target.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(i))
			for k in range(source.track_get_key_count(i)):
				target.track_insert_key(
					new_idx,
					source.track_get_key_time(i, k),
					source.track_get_key_value(i, k),
					source.track_get_key_transition(i, k)
				)


func _source_has_transform_keys(source: Animation) -> bool:
	for i in range(source.get_track_count()):
		var type = source.track_get_type(i)
		if type in [
			Animation.TYPE_POSITION_3D,
			Animation.TYPE_ROTATION_3D,
			Animation.TYPE_SCALE_3D,
			Animation.TYPE_BLEND_SHAPE,
		] and source.track_get_key_count(i) > 0:
			return true
	return false


func _source_has_multi_key_motion(source: Animation) -> bool:
	for i in range(source.get_track_count()):
		var type = source.track_get_type(i)
		if type in [
			Animation.TYPE_POSITION_3D,
			Animation.TYPE_ROTATION_3D,
			Animation.TYPE_SCALE_3D,
			Animation.TYPE_BLEND_SHAPE,
		] and source.track_get_key_count(i) > 1:
			return true
	return false


func _animation_is_stale_single_key(anim: Animation) -> bool:
	var has_transform_track := false
	for i in range(anim.get_track_count()):
		var type = anim.track_get_type(i)
		if type in [
			Animation.TYPE_POSITION_3D,
			Animation.TYPE_ROTATION_3D,
			Animation.TYPE_SCALE_3D,
			Animation.TYPE_BLEND_SHAPE,
		]:
			has_transform_track = true
			if anim.track_get_key_count(i) > 1:
				return false
	return has_transform_track
