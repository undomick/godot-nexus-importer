@tool
extends Object

## Method track path: AnimationPlayer (script receives on_nexus_event, get_nexus_markers()).
const NEXUS_ANIM_PLAYER_PATH = "AnimationPlayer"

## Processes ANIMATION_LIB scenes. Returns statistics for the summary.
func process(scene: Node, scene_meta: Dictionary) -> Dictionary:
	return {"added": 0, "removed": 0}

## Applies skeleton retargeting to AnimationPlayer (e.g. for wrapper scenes).
## Can be extended as needed.
func apply_scene_retargeting(scene_root: Node, anim_player: AnimationPlayer) -> void:
	pass

func extract_and_save_animations(scene_root: Node, gltf_path: String, scene_meta: Dictionary) -> Dictionary:
	var stats = {"extracted": 0, "path": ""}
	
	var internal_player = _find_animation_player(scene_root)
	if not internal_player: return stats
	
	var library = internal_player.get_animation_library("")
	if not library: return stats

	var save_path: String
	var target_instance_name: String
	
	# ANIMATION_LIB: Use target_animlib_path from manifest (saves to target asset folder)
	var target_animlib_path = scene_meta.get("target_animlib_path", "")
	if not target_animlib_path.is_empty():
		save_path = target_animlib_path
		target_instance_name = scene_meta.get("target_instance_name", "")
		if target_instance_name.is_empty():
			# Derive from path: "Character_animations.tres" -> "Character"
			var stem = target_animlib_path.get_file().get_basename()
			target_instance_name = stem.replace("_animations", "") if stem.ends_with("_animations") else stem
	else:
		# ASSET/SKELETAL_ASSET/LEVEL: Save next to glTF
		var base_dir = gltf_path.get_base_dir()
		var file_name = gltf_path.get_file().get_basename()
		save_path = base_dir.path_join(file_name + "_anims.res")
		target_instance_name = file_name

	# 1. Find the name of the node marked as anchor
	var anchor_node_name = _find_anchor_node_name(scene_root)
	if anchor_node_name != "":
		print_verbose("Nexus Animation: Detected Root Motion Anchor on node '%s'" % anchor_node_name)
	
	# Smart Merge Setup
	var existing_lib: AnimationLibrary = null
	if FileAccess.file_exists(save_path):
		existing_lib = ResourceLoader.load(save_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	
	var new_lib = AnimationLibrary.new()
	var loop_data = scene_meta.get("nexus_animation_loops", {})
	var marker_data = scene_meta.get("nexus_animation_markers", {})
	var root_motion_data = scene_meta.get("nexus_animation_root_motion", {})
	
	for anim_name in library.get_animation_list():
		var source_anim: Animation = library.get_animation(anim_name)
		var final_anim: Animation
		
		# Decision: Update or new
		if existing_lib and existing_lib.has_animation(anim_name):
			final_anim = existing_lib.get_animation(anim_name)
			_update_transform_tracks(final_anim, source_anim, target_instance_name, anchor_node_name)
			if marker_data.has(anim_name):
				add_marker_tracks(final_anim, marker_data[anim_name])
		else:
			final_anim = source_anim.duplicate()
			_repath_tracks(final_anim, target_instance_name, anchor_node_name)
		
		# Apply loop settings
		if loop_data.has(anim_name):
			match loop_data[anim_name]:
				"LOOP": final_anim.loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": final_anim.loop_mode = Animation.LOOP_PINGPONG
				"ONCE": final_anim.loop_mode = Animation.LOOP_NONE
		
		# Set root motion meta for Godot
		if root_motion_data.has(anim_name):
			final_anim.set_meta("nexus_root_motion", true)
		
		# Method call tracks (visible in editor) + metadata (get_nexus_markers())
		if marker_data.has(anim_name):
			add_marker_tracks(final_anim, marker_data[anim_name])

		new_lib.add_animation(anim_name, final_anim)
		stats.extracted += 1

	var err = ResourceSaver.save(new_lib, save_path)
	if err == OK:
		stats.path = save_path
		print_verbose("Nexus Animation: Extracted %d animations to '%s'" % [stats.extracted, save_path.get_file()])
	
	# Replace with empty placeholder to prevent "Node not found: AnimationPlayer" when toggling Editable Children
	var parent = internal_player.get_parent()
	var idx = internal_player.get_index()
	parent.remove_child(internal_player)
	internal_player.queue_free()
	var placeholder = AnimationPlayer.new()
	placeholder.name = "AnimationPlayer"
	parent.add_child(placeholder)
	parent.move_child(placeholder, idx)
	
	return stats

# --- HELPERS ---

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer: return node
	for child in node.get_children():
		var res = _find_animation_player(child)
		if res: return res
	return null

## Public: Adds method call tracks and nexus_markers metadata for animation events.
## track_path: when empty, uses NEXUS_ANIM_PLAYER_PATH ("AnimationPlayer").
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

## Removes legacy on_nexus_event method tracks (replaced by nexus_markers metadata).
func _remove_legacy_method_tracks(anim: Animation) -> void:
	for i in range(anim.get_track_count() - 1, -1, -1):
		if anim.track_get_type(i) == Animation.TYPE_METHOD:
			for k in range(anim.track_get_key_count(i)):
				var key_val = anim.track_get_key_value(i, k)
				if key_val is Dictionary and key_val.get("method", "") == "on_nexus_event":
					anim.remove_track(i)
					break

## Recursively searches for the node with "nexus_is_anim_anchor" metadata.
func _find_anchor_node_name(node: Node) -> String:
	# Check for Nexus meta in "extras" dictionary (GLTF standard)
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras.get("NEXUS_NODE_METADATA", {}).get("nexus_is_anim_anchor", false):
			return node.name
			
	for child in node.get_children():
		var found = _find_anchor_node_name(child)
		if found != "": return found
	return ""

## Path remapping logic for animation tracks.
## Uses "." (AnimationPlayer's parent = glTF root) so paths work for both Wrapper and Inherited.
## Paths resolve from AnimationPlayer's root_node (defaults to parent).
func _calculate_new_path(old_path: NodePath, instance_name: String, anchor_name: String) -> NodePath:
	var path_str = str(old_path)
	var node_target_name = old_path.get_name(0)  # First part of path (e.g. "Anchor" or "Bone")

	# If track points to "Anchor" or "." -> animate the glTF root (AnimationPlayer's parent).
	# Path becomes: ".:property" (parent is resolution base when root_node empty)
	if node_target_name == anchor_name and anchor_name != "":
		var property_path = old_path.get_concatenated_subnames()
		return NodePath(".:" + property_path)

	elif node_target_name == ".":
		var property_path = old_path.get_concatenated_subnames()
		return NodePath(".:" + property_path)

	# All other tracks (asset parts, bones) -> relative to glTF root.
	# Path becomes: "./OriginalPath" or "OriginalPath"
	else:
		return NodePath(path_str)

## For NEW animations.
func _repath_tracks(anim: Animation, instance_name: String, anchor_name: String) -> void:
	_remove_legacy_method_tracks(anim)
	for i in range(anim.get_track_count()):
		var old_path = anim.track_get_path(i)
		anim.track_set_path(i, _calculate_new_path(old_path, instance_name, anchor_name))

## For SMART UPDATE (existing animations).
func _update_transform_tracks(target: Animation, source: Animation, instance_name: String, anchor_name: String) -> void:
	_remove_legacy_method_tracks(target)
	# 1. Remove old transform tracks
	for i in range(target.get_track_count() - 1, -1, -1):
		var type = target.track_get_type(i)
		if type in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D, Animation.TYPE_BLEND_SHAPE]:
			target.remove_track(i)
			
	# 2. Copy new transforms and adjust paths
	for i in range(source.get_track_count()):
		var type = source.track_get_type(i)
		if type in [Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D, Animation.TYPE_BLEND_SHAPE]:
			var src_path = source.track_get_path(i)
			var new_path = _calculate_new_path(src_path, instance_name, anchor_name)
			
			var new_idx = target.add_track(type)
			target.track_set_path(new_idx, new_path)
			target.track_set_interpolation_type(new_idx, source.track_get_interpolation_type(i))
			
			for k in range(source.track_get_key_count(i)):
				target.track_insert_key(new_idx, source.track_get_key_time(i, k), source.track_get_key_value(i, k), source.track_get_key_transition(i, k))
