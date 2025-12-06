# file: addons/nexus_importer/processors/node_processor.gd
@tool
extends Object

# This function applies general node properties like visibility and shadow casting.
func process(node: Node, meta: Dictionary) -> void:
	_process_visibility(node, meta)
	_process_shadow_casting(node, meta)

# Sets the node's visibility based on the 'visible' metadata key.
func _process_visibility(node: Node3D, meta: Dictionary):
	if meta.has("visible"):
		node.visible = meta["visible"]

# Sets the shadow casting mode for GeometryInstance3D nodes.
func _process_shadow_casting(node: GeometryInstance3D, meta: Dictionary):
	if meta.has("cast_shadow"):
		var shadow_mode = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if meta["cast_shadow"] == "OFF":
			shadow_mode = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
		# Check if the node has the 'cast_shadow' property before setting it.
		if "cast_shadow" in node:
			node.cast_shadow = shadow_mode
