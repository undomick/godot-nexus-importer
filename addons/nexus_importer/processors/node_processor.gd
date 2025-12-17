# file: addons/nexus_importer/processors/node_processor.gd
@tool
extends Object

# CHANGE: Added node_meta argument to signatures
func process(node: Node, node_meta: Dictionary, scene_meta: Dictionary) -> void:
	_process_visibility(node, node_meta)
	
	if node is GeometryInstance3D:
		_process_shadow_casting(node, node_meta)
		_process_gi_mode(node, node_meta, scene_meta)

func _process_visibility(node: Node3D, meta: Dictionary):
	if meta.has("visible"):
		node.visible = meta["visible"]

func _process_shadow_casting(node: GeometryInstance3D, meta: Dictionary):
	if meta.has("cast_shadow"):
		var shadow_mode = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if meta["cast_shadow"] == "OFF":
			shadow_mode = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.cast_shadow = shadow_mode

# NEW: Apply GI Mode with Filter Logic
func _process_gi_mode(node: GeometryInstance3D, node_meta: Dictionary, scene_meta: Dictionary):
	# 1. FILTER: Shadow Proxies never need Global Illumination
	if node_meta.get("nexus_is_shadow_proxy", false):
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		return

	# 2. FILTER: LODs > 0 usually don't need independent baking (they share or use LOD0's data implicitly)
	# However, setting them to DISABLED might cause them to look dark if they switch.
	# Godot recommendation: Keep them Static if the parent is Static.
	# So we only filter Shadow Proxies explicitly.

	# 3. Apply Global Scene Setting
	if scene_meta.has("nexus_light_bake_mode"):
		var mode = scene_meta["nexus_light_bake_mode"]
		# 1 = Static (Lightmaps), 0 = Dynamic/Disabled
		if mode == 1:
			node.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		else:
			node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
