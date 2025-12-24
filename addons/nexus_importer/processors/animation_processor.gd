# file: addons/nexus_importer/processors/animation_processor.gd
@tool
extends Object

# This function processes an 'ANIMATION_LIB' export type.
# Returns a Dictionary with statistics { "added": int, "removed": int }
func process(scene: Node, scene_meta: Dictionary) -> Dictionary:	
	var stats = {"added": 0, "removed": 0}
	
	var anim_lib_path = scene_meta.get("target_animlib_path")
	if not anim_lib_path or not anim_lib_path.begins_with("res://"):
		push_error("Nexus Animation: GLTF metadata contains no valid 'target_animlib_path'.")
		return stats

	var anim_lib : AnimationLibrary
	if ResourceLoader.exists(anim_lib_path):
		anim_lib = ResourceLoader.load(anim_lib_path)
		if not anim_lib is AnimationLibrary:
			anim_lib = AnimationLibrary.new()
	else:
		anim_lib = AnimationLibrary.new()
	
	var anim_player = _find_node_of_type(scene, "AnimationPlayer")
	if not anim_player:
		push_warning("Nexus Animation: Could not find AnimationPlayer in imported scene.")
		return stats
		
	var anim_rename_map = scene_meta.get("animation_rename_map", {})
	
	# Keep track of valid names to identify orphans later
	var valid_library_names = []
	
	# --- 1. UPDATE / ADD PHASE ---
	for old_name in anim_rename_map.keys():
		var anim_info = anim_rename_map[old_name]
		var new_name = anim_info["new_name"]
		valid_library_names.append(new_name)
		
		if anim_player.has_animation(old_name):
			var anim_resource = anim_player.get_animation(old_name)
			
			var loop_mode = Animation.LOOP_NONE
			match anim_info.get("loop_type"):
				"LOOP": loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": loop_mode = Animation.LOOP_PINGPONG
			anim_resource.loop_mode = loop_mode
			
			anim_lib.add_animation(new_name, anim_resource)
			stats.added += 1
	
	# --- 2. CLEANUP PHASE ---
	var existing_names = anim_lib.get_animation_list()
	for existing_name in existing_names:
		if not existing_name in valid_library_names:
			anim_lib.remove_animation(existing_name)
			stats.removed += 1
	
	# --- 3. SAVE PHASE ---
	if stats.added > 0 or stats.removed > 0:
		var err = ResourceSaver.save(anim_lib, anim_lib_path)
		if err != OK:
			push_error("Nexus Animation: Error saving Library to '%s'." % anim_lib_path)
	
	return stats

func _find_node_of_type(root: Node, class_type: StringName) -> Node:
	var queue = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.get_class() == class_type:
			return current
		for child in current.get_children():
			queue.push_back(child)
	return null
