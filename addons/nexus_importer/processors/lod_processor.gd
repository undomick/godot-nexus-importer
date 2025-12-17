# file: addons/nexus_importer/processors/lod_processor.gd
@tool
extends Object

# ==============================================================================
# --- USER CONFIGURATION (TWEAK HERE) ------------------------------------------
# ==============================================================================

# Determines the center point of the switch relative to object size.
# Formula: Center_Distance = Object_Diameter * RATIO
const LOD_RATIOS = {
	1: 2.0,  # Transition LOD0 <-> LOD1 happens at 2x size
	2: 5.0,  # Transition LOD1 <-> LOD2 happens at 5x size
	3: 10.0, # Transition LOD2 <-> LOD3 happens at 10x size
	4: 25.0  # Cull happens at 25x size (fallback)
}

# The fade mode. 
# VISIBILITY_RANGE_FADE_SELF uses Alpha Dithering for smooth transitions.
const FADE_MODE = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

# The duration/length of the fade in meters.
# 1.0 means: The fade starts 1m before the center point and ends 1m after.
# With our logic, this creates a "Solid Overlap" to prevent transparency gaps.
const FADE_MARGIN = 1.0

# ==============================================================================

func process(scene_root: Node):
	print("Nexus LOD Processor: Analyzing scene for custom LOD groups...")
	_process_node_recursive(scene_root)

func _process_node_recursive(node: Node):
	# 1. Analyze children of current node to find siblings that belong together
	_group_and_process_children(node)
	
	# 2. Recurse deeper
	for child in node.get_children():
		_process_node_recursive(child)

func _group_and_process_children(parent: Node):
	# Dictionary to group nodes: { "BaseName": { 0: Node, 1: Node, ... } }
	var lod_groups = {}
	# Store Shadow Proxies separately: { "BaseName": Node }
	var shadow_proxies = {}
	
	var nodes_to_process = parent.get_children()
	
	# --- STEP A: IDENTIFY AND GROUP ---
	for child in nodes_to_process:
		if not child is GeometryInstance3D: continue
		
		# Check for Metadata first (More reliable than name parsing for properties)
		var meta = _get_nexus_node_meta(child)
		
		if meta.get("nexus_is_shadow_proxy", false):
			# Extract base name from "Base_Shadow"
			var base = child.name.trim_suffix("_Shadow")
			shadow_proxies[base] = child
			continue
			
		# Parse Name: "Chest_LOD1" -> Base: "Chest", Level: 1
		# Also handles "Chest" -> Base: "Chest", Level: 0
		var info = _parse_lod_name(child.name)
		var base_name = info.base
		var level = info.level
		
		if not lod_groups.has(base_name):
			lod_groups[base_name] = {}
		
		# Check for duplicates
		if lod_groups[base_name].has(level):
			push_warning("Nexus LOD: Duplicate LOD level %d found for '%s'. Skipping '%s'." % [level, base_name, child.name])
			continue
			
		lod_groups[base_name][level] = child

	# --- STEP B: CONFIGURE VISIBILITY & SETTINGS ---
	for base_name in lod_groups:
		var group = lod_groups[base_name]
		
		# We need at least the base object (LOD0) to proceed
		if not group.has(0): continue 
		
		var lod0_node: GeometryInstance3D = group[0]
		var lod0_meta = _get_nexus_node_meta(lod0_node)
		
		# 1. READ SETTINGS (BIAS & CULL)
		var bias = lod0_meta.get("nexus_lod_bias", 1.0)
		var cull_dist = lod0_meta.get("nexus_lod_cull_distance", 0.0)
		
		# --- UNIVERSAL BIAS ---
		# This controls Godot's internal Auto-LOD system (if active/no custom LODs).
		# If Custom LODs are used, this property is ignored by Godot's renderer, 
		# but we use the 'bias' variable below for our own calculation anyway.
		lod0_node.lod_bias = bias
		
		# 2. CHECK SHADOW PROXY
		var shadow_proxy: GeometryInstance3D = shadow_proxies.get(base_name)
		
		if shadow_proxy:
			# Proxy casts shadows, but is invisible to camera
			shadow_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			shadow_proxy.visible = true 
			
			# Optimization: Cull the shadow proxy too if a max distance is set
			if cull_dist > 0.0:
				shadow_proxy.visibility_range_end = cull_dist
				shadow_proxy.visibility_range_end_margin = FADE_MARGIN
			
			# Disable shadow casting for ALL visual meshes (LODs)
			# They will only receive shadows.
			for node in group.values():
				node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
		# 3. SINGLE OBJECT CASE (No Custom LODs)
		# If we only have LOD0, we just apply the Cull Distance.
		if group.size() < 2:
			if cull_dist > 0.0:
				lod0_node.visibility_range_end = cull_dist
				lod0_node.visibility_range_end_margin = FADE_MARGIN
			continue

		# 4. CUSTOM LOD CALCULATION LOOP
		var aabb = lod0_node.get_aabb()
		var size = aabb.get_longest_axis_size()
		
		var levels = group.keys()
		levels.sort()
		
		# Tracks the center point of the PREVIOUS transition
		var prev_transition_center = 0.0
		
		print(" -> Processing LODs for '%s' (Size: %.2fm, Bias: %.1f, ShadowProxy: %s)" % [base_name, size, bias, "Yes" if shadow_proxy else "No"])
		
		for i in range(levels.size()):
			var lvl = levels[i]
			var node: GeometryInstance3D = group[lvl]
			var next_lvl = -1
			if i + 1 < levels.size():
				next_lvl = levels[i+1]
			
			# --- Calculate BEGIN (Fade In) ---
			var begin = 0.0
			var begin_margin = 0.0
			
			if lvl > 0:
				# Rule: Begin = Center - Margin
				# Ensures fully opaque at the exact center point.
				begin = max(0.0, prev_transition_center - FADE_MARGIN)
				begin_margin = FADE_MARGIN
			
			# --- Calculate END (Fade Out) ---
			var end = 0.0
			var end_margin = 0.0
			var current_transition_center = 0.0
			
			if next_lvl != -1:
				# Calculate switch distance
				var multiplier = LOD_RATIOS.get(next_lvl, LOD_RATIOS.get(4) * (next_lvl * 0.5))
				
				# APPLY BIAS: Higher Bias = Switch later (larger distance)
				current_transition_center = (size * multiplier) * bias
				
				# Rule: End = Center + Margin
				end = current_transition_center + FADE_MARGIN
				end_margin = FADE_MARGIN
			else:
				# Last Level: Apply Cull Distance if set
				if cull_dist > 0.0:
					end = cull_dist
					end_margin = FADE_MARGIN
				else:
					end = 0.0 # Infinite

			# Apply to Node
			node.visibility_range_begin = begin
			node.visibility_range_begin_margin = begin_margin
			node.visibility_range_end = end
			node.visibility_range_end_margin = end_margin
			node.visibility_range_fade_mode = FADE_MODE
			
			# Store center for the next iteration
			prev_transition_center = current_transition_center

# --- HELPER: METADATA ACCESS ---
func _get_nexus_node_meta(node: Node) -> Dictionary:
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras.has("NEXUS_NODE_METADATA"):
			return extras["NEXUS_NODE_METADATA"]
	return {}

# --- HELPER: NAME PARSING ---
func _parse_lod_name(node_name: String) -> Dictionary:
	var regex = RegEx.new()
	regex.compile("^(.*)_LOD(\\d+)$")
	var result = regex.search(node_name)
	
	if result:
		return {
			"base": result.get_string(1),
			"level": int(result.get_string(2))
		}
	else:
		return {
			"base": node_name,
			"level": 0
		}
