class_name NexusWrapperBuilder
extends RefCounted

## Wrapper and inherited scene creation from imported glTF assets.

const SCENE_LOAD_WAIT_FRAMES = 3

var _plugin: EditorPlugin
var _queue: Dictionary = {}
var _inherited_creation_in_progress: bool = false
var scan_when_idle: bool = false


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func is_busy() -> bool:
	return _inherited_creation_in_progress


func has_pending() -> bool:
	return not _queue.is_empty()


func queue_scene(gltf_path: String, scene_type: String = "") -> void:
	if gltf_path.is_empty() or _queue.has(gltf_path):
		return
	if scene_type.is_empty():
		scene_type = NexusPaths.scene_style()
	if scene_type != NexusPaths.SCENE_STYLE_WRAPPER and scene_type != NexusPaths.SCENE_STYLE_INHERITED:
		return
	_queue[gltf_path] = scene_type


func queue_scenes_in_folder(folder_path: String, scene_type: String) -> int:
	if folder_path.is_empty() or scene_type.is_empty():
		return 0
	if scene_type != NexusPaths.SCENE_STYLE_WRAPPER and scene_type != NexusPaths.SCENE_STYLE_INHERITED:
		return 0
	if not DirAccess.dir_exists_absolute(folder_path):
		push_warning("Nexus: Folder not found: %s" % folder_path)
		return 0
	var gltf_paths = NexusSceneUtils.collect_gltfs_recursive(folder_path)
	var queued := 0
	for gltf_path in gltf_paths:
		var meta = NexusUtils.get_nexus_metadata(gltf_path)
		if meta.is_empty():
			continue
		var export_type = meta.get("export_type", "")
		var root_type = meta.get("root_type", "")
		if export_type in ["MULTIMESH_MANIFEST", "ANIMATION_LIB"] or root_type == "NAVMESH":
			continue
		queue_scene(gltf_path, scene_type)
		queued += 1
	if queued > 0:
		print_rich(
			"[color=cyan]Nexus Folder:[/color] Queued %d glTF(s) for %s scene creation."
			% [queued, scene_type]
		)
	return queued


func tick_scene_creation(reimport_manager: NexusReimportManager) -> bool:
	if _queue.is_empty():
		return false
	if reimport_manager.is_reimport_active() or _inherited_creation_in_progress:
		return false

	var file_to_process = _queue.keys()[0]
	var scene_type: String = _queue[file_to_process]
	_queue.erase(file_to_process)
	if scene_type == NexusPaths.SCENE_STYLE_INHERITED:
		_inherited_creation_in_progress = true
		build_inherited_scene_async(file_to_process)
	else:
		build_wrapper_scene(file_to_process)
		if _queue.is_empty():
			scan_when_idle = true
	return true


func needs_scene_processing(gltf_path: String) -> bool:
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false

	var export_type = meta.get("export_type", "")
	var root_type = meta.get("root_type", "")
	if export_type in ["MULTIMESH_MANIFEST", "ANIMATION_LIB"] or root_type == "NAVMESH":
		return false

	var scene_style = NexusPaths.scene_style()
	var tscn_path = NexusPaths.scene_path_for(gltf_path, scene_style)

	if not FileAccess.file_exists(tscn_path):
		return true
	return _saved_scene_needs_update(gltf_path, meta, tscn_path, scene_style)


func _saved_scene_needs_update(
	gltf_path: String, meta: Dictionary, tscn_path: String, scene_style: String
) -> bool:
	var packed = load(tscn_path) as PackedScene
	if packed == null:
		return true
	var inst = packed.instantiate()
	if inst == null:
		return true

	var asset_name = gltf_path.get_file().get_basename()
	var script_root: Node = inst
	var resonance_root: Node = inst
	if scene_style == NexusPaths.SCENE_STYLE_WRAPPER:
		var gltf_child = inst.get_node_or_null(NodePath(asset_name))
		if gltf_child == null:
			inst.free()
			return true
		resonance_root = gltf_child

	var target_script_path = meta.get("script_path", "")
	if not target_script_path.is_empty():
		var current_script: Script = script_root.get_script()
		var current_path := current_script.resource_path if current_script else ""
		if current_path != target_script_path:
			inst.free()
			return true

	if _has_resonance_nodes(gltf_path):
		var expected_count := _expected_resonance_count(gltf_path)
		var actual_count := _count_resonance_geometry_children(resonance_root)
		if expected_count > 0 and actual_count < expected_count:
			inst.free()
			return true

	inst.free()
	return false


func _expected_resonance_count(gltf_path: String) -> int:
	var gltf_resource = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		return 0
	var temp = gltf_resource.instantiate()
	if not temp:
		return 0
	var nodes: Array = temp.get_meta("nexus_resonance_nodes", [])
	var count := nodes.size()
	temp.free()
	return count


func _count_resonance_geometry_children(node: Node) -> int:
	var count := 0
	for child in node.get_children():
		var cls = child.get_class()
		if cls == "ResonanceStaticGeometry" or cls == "ResonanceDynamicGeometry":
			count += 1
	return count


func build_wrapper_scene(gltf_path: String) -> void:
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var tscn_path = NexusPaths.wrapper_path_for(gltf_path)
	var target_script_path = meta.get("script_path", "")

	var gltf_resource = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		push_error("Nexus Wrapper: Could not load GLTF: %s" % gltf_path)
		return

	var temp_instance = gltf_resource.instantiate()
	if not temp_instance:
		push_error("Nexus Wrapper: Could not instantiate GLTF: %s" % gltf_path)
		return
	var anim_lib_path = temp_instance.get_meta("nexus_anim_lib_path", "")
	var resonance_nodes: Array = temp_instance.get_meta("nexus_resonance_nodes", [])
	temp_instance.free()

	var packed_scene = PackedScene.new()
	var root_node = Node3D.new()
	root_node.name = gltf_path.get_file().get_basename()

	var gltf_instance = gltf_resource.instantiate()
	var asset_name = gltf_path.get_file().get_basename()
	gltf_instance.name = asset_name

	root_node.add_child(gltf_instance)
	gltf_instance.owner = root_node

	attach_resonance_nodes(gltf_instance, resonance_nodes)

	var export_type = meta.get("export_type", "")
	setup_animation_player(root_node, gltf_instance, anim_lib_path, export_type)
	assign_wrapper_script(root_node, target_script_path)

	if packed_scene.pack(root_node) == OK:
		var err = ResourceSaver.save(packed_scene, tscn_path)
		if err == OK:
			print_rich(
				"[color=cyan]Nexus Wrapper:[/color] Updated '%s' (Container Mode)."
				% tscn_path.get_file()
			)
		else:
			push_error(
				"Nexus Wrapper: Failed to save %s: %s" % [tscn_path.get_file(), error_string(err)]
			)

	root_node.free()


func build_inherited_scene_async(gltf_path: String) -> void:
	var ei = _plugin.get_editor_interface()
	var tscn_path = NexusPaths.inherited_path_for(gltf_path)
	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	var target_script_path = meta.get("script_path", "")
	var export_type = meta.get("export_type", "")

	var previous_scene_path := ""
	var current_root = ei.get_edited_scene_root()
	if current_root and current_root.scene_file_path:
		previous_scene_path = current_root.scene_file_path

	ei.open_scene_from_path(gltf_path, true)

	for i in SCENE_LOAD_WAIT_FRAMES:
		await _plugin.get_tree().process_frame

	var root = ei.get_edited_scene_root()
	if not root:
		push_error("Nexus Inherited: Could not get edited scene root after opening %s" % gltf_path)
		_inherited_creation_in_progress = false
		if _queue.is_empty():
			scan_when_idle = true
		return

	var anim_lib_path: String = root.get_meta("nexus_anim_lib_path", "")
	var resonance_nodes: Array = root.get_meta("nexus_resonance_nodes", [])

	attach_resonance_nodes(root, resonance_nodes)
	setup_animation_player(root, root, anim_lib_path, export_type)
	assign_wrapper_script(root, target_script_path)

	ei.save_scene_as(tscn_path)
	print_rich("[color=cyan]Nexus Inherited:[/color] Created '%s'." % tscn_path.get_file())

	var close_err = ei.close_scene()
	if close_err != OK and close_err != ERR_DOES_NOT_EXIST:
		push_warning("Nexus Inherited: close_scene returned %s" % error_string(close_err))

	if not previous_scene_path.is_empty() and FileAccess.file_exists(previous_scene_path):
		ei.open_scene_from_path(previous_scene_path, false)

	_inherited_creation_in_progress = false
	if _queue.is_empty():
		scan_when_idle = true


func setup_animation_player(
	root_node: Node3D,
	gltf_instance: Node,
	anim_lib_path: String,
	export_type: String
) -> void:
	var is_skeletal = export_type == "SKELETAL_ASSET"
	var needs_anim_player = is_skeletal or (
		not anim_lib_path.is_empty() and ResourceLoader.exists(anim_lib_path)
	)
	if not needs_anim_player:
		return
	var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
	var anim_player = AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	if nexus_script:
		anim_player.set_script(nexus_script)
	gltf_instance.add_child(anim_player)
	anim_player.owner = root_node

	if anim_lib_path.is_empty() or not ResourceLoader.exists(anim_lib_path):
		return
	var library = ResourceLoader.load(anim_lib_path)
	if not library:
		push_error("Nexus Wrapper: Could not load animation library: %s" % anim_lib_path)
		return
	anim_player.add_animation_library("", library)

	if _has_physics_body_recursive(gltf_instance):
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

	var animation_processor = preload(
		"res://addons/nexus_importer/processors/animation_processor.gd"
	).new()
	animation_processor.apply_scene_retargeting(root_node, anim_player)

	var anim_list = library.get_animation_list()
	if anim_list.size() > 0:
		anim_player.set_meta("nexus_autoplay", anim_list[0])


func assign_wrapper_script(root_node: Node3D, target_script_path: String) -> void:
	if target_script_path.is_empty() or not ResourceLoader.exists(target_script_path):
		return
	var script = ResourceLoader.load(target_script_path)
	if script is Script:
		root_node.set_script(script)


func attach_resonance_nodes(gltf_instance: Node, resonance_nodes: Array) -> void:
	if resonance_nodes.is_empty():
		return
	if not ClassDB.class_exists("ResonanceStaticGeometry"):
		push_warning(
			"Nexus Wrapper: Nexus Resonance addon not active. ResonanceGeometry nodes were skipped."
		)
		return
	for entry in resonance_nodes:
		if not entry is Dictionary:
			continue
		var resonance_node = _instantiate_resonance_node(entry, gltf_instance)
		if resonance_node:
			gltf_instance.add_child(resonance_node)
			resonance_node.owner = gltf_instance.owner if gltf_instance.owner else gltf_instance


func _instantiate_resonance_node(entry: Dictionary, gltf_instance: Node) -> Node3D:
	var material_path: String = entry.get("material_path", "")
	var shape_type: String = entry.get("type", "RESONANCE_STATIC")
	var discard_mesh = entry.get("discard_mesh", false)
	var base_name = NexusUtils.sanitize_node_name(entry.get("node_name", "Resonance"))
	if base_name.is_empty():
		base_name = "Resonance"

	var mesh_path: String = entry.get("mesh_path", "")
	if not mesh_path.is_empty():
		return _instantiate_resonance_from_sidecar(
			entry, mesh_path, shape_type, discard_mesh, base_name, material_path
		)

	var path_from_root: String = entry.get("path_from_root", "")
	if path_from_root.is_empty():
		return null
	return _instantiate_resonance_from_mesh_instance(
		gltf_instance, path_from_root, shape_type, discard_mesh, base_name, material_path
	)


func _instantiate_resonance_from_sidecar(
	entry: Dictionary,
	mesh_path: String,
	shape_type: String,
	discard_mesh: bool,
	base_name: String,
	material_path: String
) -> Node3D:
	var mesh_ref = ResourceLoader.load(mesh_path)
	if not mesh_ref or not mesh_ref is Mesh:
		push_warning("Nexus Wrapper: Could not load resonance mesh from '%s' - skipped." % mesh_path)
		return null
	var name_from_res = mesh_path.get_file().get_basename()
	base_name = NexusUtils.sanitize_node_name(name_from_res)
	if base_name.is_empty():
		base_name = "Resonance"
	var transform_str: String = entry.get("transform_str", "")
	var resonance_node := _create_resonance_geometry_node(shape_type)
	if not transform_str.is_empty():
		var t = str_to_var(transform_str)
		if t is Transform3D:
			resonance_node.transform = t
	_apply_resonance_material_and_mesh(resonance_node, material_path, mesh_ref)
	resonance_node.name = base_name if discard_mesh else (base_name + "_Resonance")
	return resonance_node


func _instantiate_resonance_from_mesh_instance(
	gltf_instance: Node,
	path_from_root: String,
	shape_type: String,
	discard_mesh: bool,
	base_name: String,
	material_path: String
) -> Node3D:
	var mesh_instance = gltf_instance.get_node_or_null(NodePath(path_from_root))
	if not mesh_instance or not mesh_instance is MeshInstance3D or not mesh_instance.mesh:
		push_warning(
			"Nexus Wrapper: Resonance node path '%s' not found or invalid - skipped." % path_from_root
		)
		return null
	var mesh_ref = mesh_instance.mesh
	var resonance_node := _create_resonance_geometry_node(shape_type)
	resonance_node.transform = mesh_instance.transform
	_apply_resonance_material_and_mesh(resonance_node, material_path, mesh_ref)
	resonance_node.name = base_name if discard_mesh else (base_name + "_Resonance")
	return resonance_node


func _create_resonance_geometry_node(shape_type: String) -> Node3D:
	if shape_type == "RESONANCE_STATIC":
		return ClassDB.instantiate("ResonanceStaticGeometry")
	return ClassDB.instantiate("ResonanceDynamicGeometry")


func _apply_resonance_material_and_mesh(
	resonance_node: Node3D,
	material_path: String,
	mesh_ref: Mesh
) -> void:
	var material = _load_resonance_material(material_path)
	if material:
		if resonance_node.has_method("set_material"):
			resonance_node.set_material(material)
		else:
			resonance_node.set("material", material)
	if resonance_node.has_method("set_geometry_override"):
		resonance_node.set_geometry_override(mesh_ref)
	else:
		resonance_node.set("geometry_override", mesh_ref)


func _load_resonance_material(path: String) -> Resource:
	if path.is_empty():
		return _create_default_resonance_material()
	if ResourceLoader.exists(path):
		var res = load(path)
		if res and res.get_class() == "ResonanceMaterial":
			return res
	return _create_default_resonance_material()


func _create_default_resonance_material() -> Resource:
	if not ClassDB.class_exists("ResonanceMaterial"):
		return null
	return ClassDB.instantiate("ResonanceMaterial")


func _has_physics_body_recursive(node: Node) -> bool:
	if node is PhysicsBody3D:
		return true
	for child in node.get_children():
		if _has_physics_body_recursive(child):
			return true
	return false


func _has_resonance_nodes(gltf_path: String) -> bool:
	if gltf_path.is_empty():
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return false
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return false
	var gltf = json.get_data()
	if gltf == null:
		return false
	var nodes = gltf.get("nodes", [])
	for n in nodes:
		var extras = n.get("extras", {})
		var node_meta = extras.get("NEXUS_NODE_METADATA")
		if node_meta is Dictionary:
			var shape = node_meta.get("nexus_mesh_collision_shape", "")
			if shape in ["RESONANCE_STATIC", "RESONANCE_DYNAMIC"]:
				return true
	return false
