# file: addons/nexus_importer/processors/node_processor.gd
@tool
extends Object

# This function applies general node properties like visibility and shadow casting.
func process(node: Node, meta: Dictionary) -> void:
	_process_visibility(node, meta)
	
	# FIX: Only GeometryInstance3D (Meshes, Sprites, Particles) has 'cast_shadow'.
	# Nodes like Camera3D, Light3D, or Node3D do not.
	if node is GeometryInstance3D:
		_process_shadow_casting(node, meta)

# Sets the node's visibility based on the 'visible' metadata key.
func _process_visibility(node: Node3D, meta: Dictionary):
	if meta.has("visible"):
		node.visible = meta["visible"]

# Sets the shadow casting mode for GeometryInstance3D nodes.
# Assumes node IS A GeometryInstance3D (checked in process).
func _process_shadow_casting(node: GeometryInstance3D, meta: Dictionary):
	if meta.has("cast_shadow"):
		var shadow_mode = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if meta["cast_shadow"] == "OFF":
			shadow_mode = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
		node.cast_shadow = shadow_mode
