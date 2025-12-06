# file: addons/nexus_importer/processors/instancing_processor.gd
@tool
extends Object

func process(node: Node, meta: Dictionary, root: Node) -> bool:
	if not meta.has("nexus_asset_id"): return false
	
	var asset_id = meta["nexus_asset_id"]
	var file = FileAccess.open('res://asset_index.json', FileAccess.READ)
	if not file:
		push_warning("Nexus Instancer: asset_index.json not found.")
		return false
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return false
	var asset_index = json.get_data()
	if not asset_index.has(asset_id):
		push_error("Nexus Instancer: Asset ID '%s' not found." % asset_id)
		return false
		
	var base_gltf_path = "res://" + asset_index[asset_id]["relative_path"]
	var editable_scene_path = base_gltf_path.get_slice(".", 0) + "_editable.tscn"
	var scene_to_instance_path = editable_scene_path if ResourceLoader.exists(editable_scene_path) else base_gltf_path

	var packed_scene = load(scene_to_instance_path)
	if not packed_scene is PackedScene:
		push_error("Nexus Instancer: Could not load scene at: " + scene_to_instance_path)
		return false
		
	var instance = packed_scene.instantiate()
	instance.name = node.name
	instance.transform = node.transform
	
	var parent = node.get_parent()
	if not parent: return false

	parent.remove_child(node)
	parent.add_child(instance)
	instance.owner = root
	
	# THE CRITICAL FIX: Use free() to prevent name clashes.
	node.free()
	
	return true
