@tool
extends Object

## Repathing tool for Nexus: Corrects animation track paths after a child node has been
## made the scene root (e.g. "Make Scene Root" on CharacterBody3D).
##
## Usage: Duplicate scene → Open duplicate → Right-click desired node →
## "Make Scene Root" → Project > Tools > Nexus: Repathing Tool
##
## Removes the "<RootName>/" prefix from all track paths (e.g. "Character/Armature/Skeleton3D"
## → "Armature/Skeleton3D").
##
## Important: External AnimationLibraries (.tres) are duplicated and embedded so the original
## scene is not modified. root_node is set to the scene root.


## Runs repathing on the currently opened scene.
## Returns a Dictionary with {"ok": bool, "message": String, "tracks_fixed": int}.
static func run(editor_interface: EditorInterface) -> Dictionary:
	var root = editor_interface.get_edited_scene_root()
	if not root:
		return {"ok": false, "message": "No scene open. Please open a scene in the editor first.", "tracks_fixed": 0}

	var scene_path = root.scene_file_path
	if scene_path.is_empty():
		return {"ok": false, "message": "Scene must be saved before repathing can run.", "tracks_fixed": 0}

	var prefix = root.name + "/"
	if prefix == "/":
		return {"ok": false, "message": "Root node has no name. Repathing skipped.", "tracks_fixed": 0}

	var tracks_fixed = 0

	var anim_players: Array[AnimationPlayer] = []
	var anim_trees: Array[AnimationTree] = []
	_collect_animation_nodes(root, anim_players, anim_trees)

	for anim_player in anim_players:
		for lib_name in anim_player.get_animation_library_list():
			var library: AnimationLibrary = anim_player.get_animation_library(lib_name)
			if not library:
				continue

			# External library: duplicate instead of overwriting original (avoids modifying original scene)
			var library_to_edit: AnimationLibrary = library
			var res_path = library.resource_path
			var is_external = not res_path.is_empty() and not res_path.begins_with("local://")
			if is_external:
				library_to_edit = library.duplicate(true)
				anim_player.remove_animation_library(lib_name)
				anim_player.add_animation_library(lib_name, library_to_edit)

			var lib_modified = false
			for anim_name in library_to_edit.get_animation_list():
				var anim: Animation = library_to_edit.get_animation(anim_name)
				if not anim:
					continue

				for i in range(anim.get_track_count()):
					var old_path: NodePath = anim.track_get_path(i)
					var path_str := str(old_path)
					if path_str.begins_with(prefix):
						var new_path_str = path_str.substr(prefix.length())
						anim.track_set_path(i, NodePath(new_path_str))
						tracks_fixed += 1
						lib_modified = true

	for player in anim_players:
		_update_mixer_root_and_cache(player, root)
	for tree in anim_trees:
		_update_mixer_root_and_cache(tree, root)

	var err = editor_interface.save_scene()
	if err != OK:
		return {
			"ok": false,
			"message": "Repathing done (%d tracks) but scene could not be saved: %s" % [tracks_fixed, error_string(err)],
			"tracks_fixed": tracks_fixed
		}

	if tracks_fixed > 0:
		return {
			"ok": true,
			"message": "Repathing complete: %d track(s) adjusted and saved in scene." % tracks_fixed,
			"tracks_fixed": tracks_fixed
		}
	else:
		return {
			"ok": true,
			"message": "No paths to adjust. All tracks already use correct paths relative to current root.",
			"tracks_fixed": 0
		}


static func _collect_animation_nodes(node: Node, out_players: Array[AnimationPlayer], out_trees: Array[AnimationTree]) -> void:
	if node is AnimationPlayer:
		if node not in out_players:
			out_players.append(node)
	elif node is AnimationTree:
		if node not in out_trees:
			out_trees.append(node)
		var player = node.anim_player
		if player and player not in out_players:
			out_players.append(player)

	for child in node.get_children():
		_collect_animation_nodes(child, out_players, out_trees)


static func _update_mixer_root_and_cache(mixer: Node, scene_root: Node) -> void:
	if not mixer.has_method("get") or not mixer.has_method("set"):
		return
	# Paths are resolved relative to root_node – point to scene root
	var path_to_root = mixer.get_path_to(scene_root)
	if path_to_root != mixer.get("root_node"):
		mixer.set("root_node", path_to_root)
	if mixer.has_method("clear_caches"):
		mixer.clear_caches()


## Exports the first AnimationPlayer's animation library to a .tres file.
## Useful after repathing: the exported library has adjusted paths and can be reused
## in other scenes with the same root structure.
## Saves next to the current scene as "<scenename>_animations.tres".
## Replaces the embedded library with the external reference.
static func export_animation_library(editor_interface: EditorInterface) -> Dictionary:
	var root = editor_interface.get_edited_scene_root()
	if not root:
		return {"ok": false, "message": "No scene open.", "path": ""}

	var scene_path = root.scene_file_path
	if scene_path.is_empty():
		return {"ok": false, "message": "Scene must be saved.", "path": ""}

	var anim_players: Array[AnimationPlayer] = []
	var anim_trees: Array[AnimationTree] = []
	_collect_animation_nodes(root, anim_players, anim_trees)

	var anim_player: AnimationPlayer = null
	if not anim_players.is_empty():
		anim_player = anim_players[0]
	if not anim_player:
		return {"ok": false, "message": "No AnimationPlayer found in scene.", "path": ""}

	var lib_names = anim_player.get_animation_library_list()
	if lib_names.is_empty():
		return {"ok": false, "message": "AnimationPlayer has no animation library.", "path": ""}

	var lib_name = lib_names[0]
	var library: AnimationLibrary = anim_player.get_animation_library(lib_name)
	if not library:
		return {"ok": false, "message": "Library could not be loaded.", "path": ""}

	var scene_base = scene_path.get_file().get_basename()
	var export_path = scene_path.get_base_dir().path_join(scene_base + "_animations.tres")

	var library_to_save: AnimationLibrary = library.duplicate(true)

	var err = ResourceSaver.save(library_to_save, export_path)
	if err != OK:
		return {"ok": false, "message": "Save failed: %s" % error_string(err), "path": ""}

	anim_player.remove_animation_library(lib_name)
	var loaded_lib = ResourceLoader.load(export_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	anim_player.add_animation_library(lib_name, loaded_lib)

	err = editor_interface.save_scene()
	if err != OK:
		return {"ok": false, "message": "Library exported but scene could not be saved.", "path": export_path}

	return {"ok": true, "message": "Animation library exported to: %s" % export_path, "path": export_path}
