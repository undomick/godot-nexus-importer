@tool
extends Object

## Applies LOD visibility ranges and shadow proxy linking from nexus metadata.

const FADE_MODE = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

var _lod_regex: RegEx = RegEx.new()

func _init():
	_lod_regex.compile("^(.*)_LOD\\d+$")


func _is_lod_or_shadow_node(node_name: String) -> bool:
	return _lod_regex.search(node_name) != null or node_name.ends_with("_Shadow")

# ==============================================================================

func process(scene_root: Node, stats: Dictionary) -> void:
	_process_node_recursive(scene_root, stats)

func _process_node_recursive(node: Node, stats: Dictionary) -> void:
	if node is GeometryInstance3D:
		_apply_lod_settings(node, stats)
	
	for child in node.get_children():
		_process_node_recursive(child, stats)
		
	_handle_shadow_proxies(node)

func _apply_lod_settings(node: GeometryInstance3D, stats: Dictionary) -> void:
	var extras = node.get_meta("extras") if node.has_meta("extras") else {}
	if not extras is Dictionary:
		return

	# Store in meta; applied deferred by nexus_lod_deferred.gd to avoid "data.tree is null"
	# when opening scenes at editor startup (GeometryInstance3D setters can call get_tree())
	# Only apply visibility_range for LOD meshes (_LOD0, _LOD1, ... or _Shadow)
	if extras.has("nexus_visibility_range") and _is_lod_or_shadow_node(node.name):
		var range_data = extras["nexus_visibility_range"]
		if not range_data is Dictionary:
			range_data = {}
		node.set_meta("nexus_visibility_range", {
			"begin": range_data.get("begin", 0.0),
			"begin_margin": range_data.get("begin_margin", 0.0),
			"end": range_data.get("end", 0.0),
			"end_margin": range_data.get("end_margin", 0.0)
		})
		stats.lods += 1

	var nexus_meta = _get_nexus_node_meta(node)
	if nexus_meta.get("nexus_is_shadow_proxy", false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.visible = true 

func _handle_shadow_proxies(parent: Node) -> void:
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

			var mesh_end = _get_visibility_range_end(mesh)
			var proxy_end = _get_visibility_range_end(proxy)
			if mesh_end > proxy_end:
				_update_proxy_range_meta(proxy, mesh)

func _get_nexus_node_meta(node: Node) -> Dictionary:
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras is Dictionary and extras.has("NEXUS_NODE_METADATA"):
			return extras["NEXUS_NODE_METADATA"]
	return {}


func _get_visibility_range_end(node: GeometryInstance3D) -> float:
	if node.has_meta("nexus_visibility_range"):
		var d = node.get_meta("nexus_visibility_range")
		if d is Dictionary:
			return d.get("end", 0.0)
	return node.visibility_range_end


func _update_proxy_range_meta(proxy: GeometryInstance3D, mesh: GeometryInstance3D) -> void:
	var mesh_meta = mesh.get_meta("nexus_visibility_range", {}) if mesh.has_meta("nexus_visibility_range") else {}
	var mesh_end = mesh_meta.get("end", mesh.visibility_range_end) if mesh_meta is Dictionary else mesh.visibility_range_end
	var mesh_margin = mesh_meta.get("end_margin", mesh.visibility_range_end_margin) if mesh_meta is Dictionary else mesh.visibility_range_end_margin

	var d: Dictionary
	if proxy.has_meta("nexus_visibility_range"):
		d = proxy.get_meta("nexus_visibility_range")
		if not d is Dictionary:
			d = {}
	else:
		d = {"begin": 0.0, "begin_margin": 0.0, "end": 0.0, "end_margin": 0.0}
	d["end"] = mesh_end
	d["end_margin"] = mesh_margin
	proxy.set_meta("nexus_visibility_range", d)
