@tool
extends Object

# ==============================================================================
# --- CONFIGURATION ------------------------------------------------------------
# ==============================================================================

const FADE_MODE = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

var _lod_regex: RegEx = RegEx.new()

func _init():
	_lod_regex.compile("^(.*)_LOD\\d+$")

# ==============================================================================

func process(scene_root: Node, stats: Dictionary):
	_process_node_recursive(scene_root, stats)

func _process_node_recursive(node: Node, stats: Dictionary):
	if node is GeometryInstance3D:
		_apply_lod_settings(node, stats)
	
	for child in node.get_children():
		_process_node_recursive(child, stats)
		
	_handle_shadow_proxies(node)

func _apply_lod_settings(node: GeometryInstance3D, stats: Dictionary):
	var extras = node.get_meta("extras") if node.has_meta("extras") else {}
	
	if extras.has("nexus_visibility_range"):
		var range_data = extras["nexus_visibility_range"]
		node.visibility_range_begin = range_data.get("begin", 0.0)
		node.visibility_range_begin_margin = range_data.get("begin_margin", 0.0)
		node.visibility_range_end = range_data.get("end", 0.0)
		node.visibility_range_end_margin = range_data.get("end_margin", 0.0)
		node.visibility_range_fade_mode = FADE_MODE
		stats.lods += 1
		
	var nexus_meta = _get_nexus_node_meta(node)
	if nexus_meta.get("nexus_is_shadow_proxy", false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.visible = true 

func _handle_shadow_proxies(parent: Node):
	var children = parent.get_children()
	var shadow_proxies = {}
	var potential_bases = []
	
	# A. Collect
	for child in children:
		if not child is GeometryInstance3D: continue
		var meta = _get_nexus_node_meta(child)
		
		if meta.get("nexus_is_shadow_proxy", false):
			var base_name = child.name.trim_suffix("_Shadow")
			base_name = base_name.trim_suffix("_LOD0") 
			shadow_proxies[base_name] = child
		else:
			potential_bases.append(child)
			
	if shadow_proxies.is_empty(): return
	
	# B. Link & Configure using Precompiled Regex
	for mesh in potential_bases:
		var mesh_name = mesh.name
		var base_name = mesh_name
		
		var result = _lod_regex.search(mesh_name)
		if result:
			base_name = result.get_string(1)
		
		if shadow_proxies.has(base_name):
			var proxy = shadow_proxies[base_name]
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			
			if mesh.visibility_range_end > proxy.visibility_range_end:
				proxy.visibility_range_end = mesh.visibility_range_end
				proxy.visibility_range_end_margin = mesh.visibility_range_end_margin
				proxy.visibility_range_fade_mode = FADE_MODE

func _get_nexus_node_meta(node: Node) -> Dictionary:
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras.has("NEXUS_NODE_METADATA"):
			return extras["NEXUS_NODE_METADATA"]
	return {}
