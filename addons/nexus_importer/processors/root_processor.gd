# file: addons/nexus_importer/processors/root_processor.gd
@tool
extends Object


func apply_script(node: Node, meta: Dictionary) -> bool:
	var script_path = meta.get("script_path", "")
	if not script_path.is_empty() and script_path.begins_with("res://"):
		var script_resource = load(script_path)
		if script_resource is Script:
			node.set_script(script_resource)
			return true # Melde Erfolg!
		else:
			push_warning("Nexus Importer: Could not load script at path: " + script_path)
			return false # Melde Fehlschlag
	return false # Kein Skriptpfad vorhanden

# Sets the physics collision layer and mask if the root is a PhysicsBody.
func set_collision_layers(node: Node, meta: Dictionary):
	if node is PhysicsBody3D and meta.has("collision_layer"):
		node.collision_layer = meta.get("collision_layer")
		node.collision_mask = meta.get("collision_mask")
