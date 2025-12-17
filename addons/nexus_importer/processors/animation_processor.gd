# file: addons/nexus_importer/processors/animation_processor.gd
@tool
extends Object

# This function processes an 'ANIMATION_LIB' export type.
# It extracts animations, renames them, sets their properties, and saves them
# into a shared AnimationLibrary resource.
func process(scene: Node, scene_meta: Dictionary):
	print("Nexus Processor: Processing as Animation Library...")
	
	var anim_lib_path = scene_meta.get("target_animlib_path")
	if not anim_lib_path or not anim_lib_path.begins_with("res://"):
		push_error("Nexus Animation: GLTF metadata contains no valid 'target_animlib_path'.")
		return

	var anim_lib : AnimationLibrary
	if ResourceLoader.exists(anim_lib_path):
		anim_lib = ResourceLoader.load(anim_lib_path)
		if not anim_lib is AnimationLibrary:
			push_warning("Nexus Animation: Resource at '%s' is not an AnimationLibrary. Creating a new one." % anim_lib_path)
			anim_lib = AnimationLibrary.new()
	else:
		anim_lib = AnimationLibrary.new()

	var anim_player = _find_node_of_type(scene, "AnimationPlayer")
	if not anim_player:
		push_warning("Nexus Animation: Could not find AnimationPlayer in the imported scene. Cannot process animations.")
		return
		
	var anim_rename_map = scene_meta.get("animation_rename_map", {})
	var animations_added = 0
	var animations_removed = 0
	
	# Keep track of valid names to identify orphans later
	var valid_library_names = []
	
	# --- 1. UPDATE / ADD PHASE ---
	for old_name in anim_rename_map.keys():
		var anim_info = anim_rename_map[old_name]
		var new_name = anim_info["new_name"]
		valid_library_names.append(new_name)
		
		# Check if the animation with the old name exists in the player.
		if anim_player.has_animation(old_name):
			var anim_resource = anim_player.get_animation(old_name)
			
			# Set the loop mode.
			var loop_mode = Animation.LOOP_NONE
			match anim_info.get("loop_type"):
				"LOOP": loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": loop_mode = Animation.LOOP_PINGPONG
			anim_resource.loop_mode = loop_mode
			
			# Add the animation with the NEW name to the library.
			# This overwrites existing animations with the same name automatically.
			anim_lib.add_animation(new_name, anim_resource)
			animations_added += 1
			print(" -> Updated animation '%s' (Source: '%s')." % [new_name, old_name])
		else:
			push_warning("Nexus Animation: Source animation '%s' not found in AnimationPlayer." % old_name)

	# --- 2. CLEANUP PHASE ---
	# Remove animations from the library that are no longer in the Blender export.
	var existing_names = anim_lib.get_animation_list()
	for existing_name in existing_names:
		if not existing_name in valid_library_names:
			anim_lib.remove_animation(existing_name)
			animations_removed += 1
			print(" -> Removed obsolete animation '%s' from library." % existing_name)

	# --- 3. SAVE PHASE ---
	if animations_added > 0 or animations_removed > 0:
		var err = ResourceSaver.save(anim_lib, anim_lib_path)
		if err == OK:
			print(" -> Successfully saved Animation Library to '%s' (+%d / -%d)." % [anim_lib_path, animations_added, animations_removed])
		else:
			push_error("Nexus Animation: Error saving Animation Library to '%s'. Error Code: %d" % [anim_lib_path, err])
	else:
		print(" -> No changes detected in Animation Library.")


# Helper to find the first node of a specific class type in a scene tree.
func _find_node_of_type(root: Node, class_type: StringName) -> Node:
	var queue = [root]
	while not queue.is_empty():
		var current = queue.pop_front()
		if current.get_class() == class_type:
			return current
		for child in current.get_children():
			queue.push_back(child)
	return null
