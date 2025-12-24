# file: addons/nexus_importer/processors/lod_processor.gd
@tool
extends Object

# ==============================================================================
# --- CONFIGURATION ------------------------------------------------------------
# ==============================================================================

# Default Fade Mode (Alpha Dithering for smooth transitions)
const FADE_MODE = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

# ==============================================================================

func process(scene_root: Node, stats: Dictionary):
	_process_node_recursive(scene_root, stats)

func _process_node_recursive(node: Node, stats: Dictionary):
	# 1. Apply LOD settings if it's a Mesh
	if node is GeometryInstance3D:
		_apply_lod_settings(node, stats)
	
	# 2. Recurse into children
	for child in node.get_children():
		_process_node_recursive(child, stats)
		
	# 3. Post-Process: Link Shadow Proxies to their siblings
	# We run this on the parent to find siblings (Shadow + Visual Mesh)
	_handle_shadow_proxies(node)


func _apply_lod_settings(node: GeometryInstance3D, stats: Dictionary):
	# Check for Direct Visibility Range Data (From Blender "Distance Based" logic)
	# This data sits in the GLTF Node "extras"
	
	var extras = node.get_meta("extras") if node.has_meta("extras") else {}
	
	if extras.has("nexus_visibility_range"):
		var range_data = extras["nexus_visibility_range"]
		
		# Apply values directly from Blender (Meters)
		node.visibility_range_begin = range_data.get("begin", 0.0)
		node.visibility_range_begin_margin = range_data.get("begin_margin", 0.0)
		node.visibility_range_end = range_data.get("end", 0.0)
		node.visibility_range_end_margin = range_data.get("end_margin", 0.0)
		node.visibility_range_fade_mode = FADE_MODE
		
		stats.lods += 1
		
	# Check for Shadow Proxy Tag
	var nexus_meta = _get_nexus_node_meta(node)
	
	if nexus_meta.get("nexus_is_shadow_proxy", false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.visible = true 
		# Culling distance is handled in _handle_shadow_proxies


func _handle_shadow_proxies(parent: Node):
	# Scans children to link Shadow Proxies with their Base Meshes
	
	var children = parent.get_children()
	var shadow_proxies = {}
	var potential_bases = []
	
	# A. Collect
	for child in children:
		if not child is GeometryInstance3D: continue
		var meta = _get_nexus_node_meta(child)
		
		if meta.get("nexus_is_shadow_proxy", false):
			var base_name = child.name.trim_suffix("_Shadow")
			# Fix: Handle names like "Chair_LOD0_Shadow" -> "Chair"
			base_name = base_name.trim_suffix("_LOD0") 
			shadow_proxies[base_name] = child
		else:
			potential_bases.append(child)
			
	if shadow_proxies.is_empty(): return
	
	# B. Link & Configure
	for mesh in potential_bases:
		var mesh_name = mesh.name
		var base_name = mesh_name
		
		# Extract base name (matches Blender's LOD logic)
		var regex = RegEx.new()
		regex.compile("^(.*)_LOD\\d+$")
		var result = regex.search(mesh_name)
		if result:
			base_name = result.get_string(1)
		
		if shadow_proxies.has(base_name):
			var proxy = shadow_proxies[base_name]
			
			# 1. Disable shadow on visual mesh (Proxy handles it)
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			
			# 2. Transfer Cull Distance to Shadow Proxy
			# The Shadow Proxy should disappear when the LAST LOD disappears.
			if mesh.visibility_range_end > proxy.visibility_range_end:
				proxy.visibility_range_end = mesh.visibility_range_end
				proxy.visibility_range_end_margin = mesh.visibility_range_end_margin
				proxy.visibility_range_fade_mode = FADE_MODE


# --- HELPER: METADATA ACCESS ---
func _get_nexus_node_meta(node: Node) -> Dictionary:
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras.has("NEXUS_NODE_METADATA"):
			return extras["NEXUS_NODE_METADATA"]
	return {}
