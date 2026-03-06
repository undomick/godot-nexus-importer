@tool
extends Object

## Creates ResonanceStaticGeometry or ResonanceDynamicGeometry from nexus_mesh_collision_shape
## when Nexus Resonance addon is active. Fallback: Node3D + warning if Resonance not available.

func process(node: Node, node_meta: Dictionary, scene_meta: Dictionary, root: Node, stats: Dictionary) -> bool:
	var shape_type = node_meta.get("nexus_mesh_collision_shape", "")
	if shape_type not in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
		return false

	if not node is MeshInstance3D or not node.mesh:
		return false

	var parent = node.get_parent()
	if not parent:
		return false

	# Check if Nexus Resonance is available
	if not ClassDB.class_exists("ResonanceStaticGeometry"):
		# Fallback: create Node3D placeholder and warn
		var fallback_node = Node3D.new()
		fallback_node.transform = node.transform
		var discard_mesh_fb = node_meta.get("discard_mesh", false)
		if discard_mesh_fb:
			fallback_node.name = node.name
			parent.remove_child(node)
			parent.add_child(fallback_node)
			fallback_node.owner = root
			node.free()
		else:
			fallback_node.name = node.name + "_ResonancePlaceholder"
			root.add_child(fallback_node)
			fallback_node.owner = root
		push_warning("Nexus Resonance not active. Please enable Nexus Resonance and reimport. '%s' was created as a Node3D placeholder." % node.name)
		if stats.has("resonance"):
			stats.resonance += 1
		return true

	# Load ResonanceMaterial
	var material_path: String = node_meta.get("nexus_resonance_material_path", "")
	var material = _load_resonance_material(material_path)

	# Create ResonanceGeometry node
	var resonance_node: Node3D
	if shape_type == "RESONANCE_STATIC":
		resonance_node = ClassDB.instantiate("ResonanceStaticGeometry")
	else:
		resonance_node = ClassDB.instantiate("ResonanceDynamicGeometry")

	var mesh_ref = node.mesh  # Capture before potential node.free()
	resonance_node.transform = node.transform
	if resonance_node.has_method("set_material"):
		resonance_node.set_material(material)
	else:
		resonance_node.set("material", material)
	if resonance_node.has_method("set_geometry_override"):
		resonance_node.set_geometry_override(mesh_ref)
	else:
		resonance_node.set("geometry_override", mesh_ref)

	var discard_mesh = node_meta.get("discard_mesh", false)
	if discard_mesh:
		# Replace MeshInstance3D with ResonanceGeometry (same position in hierarchy)
		resonance_node.name = node.name
		parent.remove_child(node)
		parent.add_child(resonance_node)
		resonance_node.owner = root
		node.free()
	else:
		# Keep MeshInstance3D, add ResonanceGeometry as child of root
		resonance_node.name = node.name + "_Resonance"
		root.add_child(resonance_node)
		resonance_node.owner = root

	if stats.has("resonance"):
		stats.resonance += 1

	return true


func _load_resonance_material(path: String) -> Resource:
	if path.is_empty():
		return _create_default_resonance_material()

	if ResourceLoader.exists(path):
		var res = load(path)
		if res and res.get_class() == "ResonanceMaterial":
			return res

	# Path invalid or resource not ResonanceMaterial - use default
	return _create_default_resonance_material()


func _create_default_resonance_material() -> Resource:
	if not ClassDB.class_exists("ResonanceMaterial"):
		return null
	var mat = ClassDB.instantiate("ResonanceMaterial")
	# C++ defaults: absorption 0.1/0.2/0.3, scattering 0.05, transmission 0.01
	return mat
