@tool
extends Object

## Applies LOD visibility ranges and shadow proxy linking from nexus metadata.

var _lod_regex: RegEx = RegEx.new()


func _init():
	_lod_regex.compile("^(.*)_LOD\\d+$")


func _is_lod_or_shadow_node(node_name: String) -> bool:
	return _lod_regex.search(node_name) != null or node_name.ends_with("_Shadow")


func process(scene_root: Node, stats: Dictionary) -> void:
	_process_node_recursive(scene_root, stats)


func _process_node_recursive(node: Node, stats: Dictionary) -> void:
	if node is GeometryInstance3D:
		_apply_lod_settings(node, stats)

	for child in node.get_children():
		_process_node_recursive(child, stats)

	_link_shadow_proxies(node)


func _apply_lod_settings(node: GeometryInstance3D, stats: Dictionary) -> void:
	var extras = node.get_meta("extras") if node.has_meta("extras") else {}
	if not extras is Dictionary:
		return

	if extras.has("nexus_visibility_range"):
		var range_data = extras["nexus_visibility_range"]
		if range_data is Dictionary:
			_apply_visibility_range(node, range_data)
			stats.lods += 1

	var nexus_meta = _get_nexus_node_meta(node)
	if nexus_meta.get("nexus_is_shadow_proxy", false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		node.visible = true


func _apply_visibility_range(node: GeometryInstance3D, range_data: Dictionary) -> void:
	node.visibility_range_begin = range_data.get("begin", 0.0)
	node.visibility_range_begin_margin = range_data.get("begin_margin", 0.0)
	node.visibility_range_end = range_data.get("end", 0.0)
	node.visibility_range_end_margin = range_data.get("end_margin", 0.0)
	node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


func _link_shadow_proxies(parent: Node) -> void:
	var children = parent.get_children()
	var shadow_proxies := _collect_shadow_proxies(children)
	if shadow_proxies.is_empty():
		return

	for mesh in children:
		if not mesh is GeometryInstance3D:
			continue
		var meta = _get_nexus_node_meta(mesh)
		if meta.get("nexus_is_shadow_proxy", false):
			continue

		var base_name = mesh.name
		var result = _lod_regex.search(mesh.name)
		if result:
			base_name = result.get_string(1)

		if not shadow_proxies.has(base_name):
			continue

		var proxy: GeometryInstance3D = shadow_proxies[base_name]
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		var mesh_end = _get_visibility_range_end(mesh)
		var proxy_end = _get_visibility_range_end(proxy)
		if mesh_end > proxy_end:
			_update_proxy_range_end(proxy, mesh)


func _collect_shadow_proxies(children: Array) -> Dictionary:
	var shadow_proxies: Dictionary = {}
	for child in children:
		if not child is GeometryInstance3D:
			continue
		var meta = _get_nexus_node_meta(child)
		if not meta.get("nexus_is_shadow_proxy", false):
			continue
		var base_name = child.name.trim_suffix("_Shadow").trim_suffix("_LOD0")
		shadow_proxies[base_name] = child
	return shadow_proxies


func _get_nexus_node_meta(node: Node) -> Dictionary:
	if node.has_meta("extras"):
		var extras = node.get_meta("extras")
		if extras is Dictionary and extras.has("NEXUS_NODE_METADATA"):
			return extras["NEXUS_NODE_METADATA"]
	return {}


func _get_visibility_range_end(node: GeometryInstance3D) -> float:
	return node.visibility_range_end


func _update_proxy_range_end(proxy: GeometryInstance3D, mesh: GeometryInstance3D) -> void:
	proxy.visibility_range_end = mesh.visibility_range_end
	proxy.visibility_range_end_margin = mesh.visibility_range_end_margin
