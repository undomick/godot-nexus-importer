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
	
	# Iterate through the rename map from the glTF metadata.
	for old_name in anim_rename_map.keys():
		var anim_info = anim_rename_map[old_name]
		var new_name = anim_info["new_name"]
		
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
			anim_lib.add_animation(new_name, anim_resource)
			animations_added += 1
			print(" -> Added animation '%s' (from '%s') to library." % [new_name, old_name])
		else:
			push_warning("Nexus Animation: Source animation '%s' not found in AnimationPlayer." % old_name)

	if animations_added > 0:
		var err = ResourceSaver.save(anim_lib, anim_lib_path)
		if err == OK:
			print(" -> Successfully saved Animation Library to '%s'." % anim_lib_path)
		else:
			push_error("Nexus Animation: Error saving Animation Library to '%s'. Error Code: %d" % [anim_lib_path, err])


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
