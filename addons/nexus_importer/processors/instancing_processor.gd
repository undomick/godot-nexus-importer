# file: addons/nexus_importer/processors/instancing_processor.gd
@tool
extends Object

func process(node: Node, meta: Dictionary, root: Node) -> bool:
	var scene_path = ""

	# CASE A: Direct Placeholder Path (From Blender Empty)
	if meta.has("nexus_placeholder_path"):
		scene_path = meta["nexus_placeholder_path"]
		
	# CASE B: Nexus Collection Instance (From Blender Collection Instance)
	elif meta.has("nexus_asset_id"):
		var asset_id = meta["nexus_asset_id"]
		var file = FileAccess.open('res://asset_index.json', FileAccess.READ)
		if file:
			var json = JSON.new()
			if json.parse(file.get_as_text()) == OK:
				var asset_index = json.get_data()
				if asset_index.has(asset_id):
					var base_gltf_path = "res://" + asset_index[asset_id]["relative_path"]
					# Prefer editable scene if available
					var editable_scene_path = base_gltf_path.get_slice(".", 0) + "_editable.tscn"
					scene_path = editable_scene_path if ResourceLoader.exists(editable_scene_path) else base_gltf_path
				else:
					push_error("Nexus Instancer: Asset ID '%s' not found." % asset_id)
					return false
	
	# If no valid path found, exit
	if scene_path.is_empty():
		return false

	# --- INSTANTIATION LOGIC ---
	
	if not ResourceLoader.exists(scene_path):
		push_error("Nexus Instancer: Target scene not found at '%s'" % scene_path)
		return false

	var packed_scene = load(scene_path)
	if not packed_scene is PackedScene:
		# Fallback: If it's not a Scene (e.g. a Texture or Mesh resource), we can't instantiate it directly as a Node replacement easily.
		# For now, we strictly support .tscn / .glb / .scn
		push_error("Nexus Instancer: Resource at '%s' is not a PackedScene." % scene_path)
		return false
		
	var instance = packed_scene.instantiate()
	instance.name = node.name
	instance.transform = node.transform
	
	var parent = node.get_parent()
	if not parent: return false

	parent.remove_child(node)
	parent.add_child(instance)
	instance.owner = root
	
	node.free()
	
	print("Nexus Instancer: Replaced '%s' with instance of '%s'." % [instance.name, scene_path.get_file()])
	return true
