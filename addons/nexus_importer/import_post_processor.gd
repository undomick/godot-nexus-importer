@tool
extends EditorScenePostImport

## Post-import processor for Nexus glTF assets. Converts nodes, materials, animations, LODs, etc.

const NEXUS_ASSET_META = "NEXUS_ASSET_METADATA"
const NEXUS_NODE_META = "NEXUS_NODE_METADATA"
const LOD_PROCESS_EXPORT_TYPES := ["ASSET", "SKELETAL_ASSET", "COMBINED_ASSET", "LEVEL"]

const AnimationProcessor = preload("res://addons/nexus_importer/processors/animation_processor.gd")
const NexusBatchLock = preload("res://addons/nexus_importer/scripts/nexus_batch_lock.gd")
const NexusImportContext = preload("res://addons/nexus_importer/scripts/nexus_import_context.gd")
const BoneAttachmentProcessor = preload("res://addons/nexus_importer/processors/bone_attachment_processor.gd")
const CollisionProcessor = preload("res://addons/nexus_importer/processors/collision_processor.gd")
const ResonanceProcessor = preload("res://addons/nexus_importer/processors/resonance_processor.gd")
const InstancingProcessor = preload("res://addons/nexus_importer/processors/instancing_processor.gd")
const LightProcessor = preload("res://addons/nexus_importer/processors/light_processor.gd")
const LodProcessor = preload("res://addons/nexus_importer/processors/lod_processor.gd")
const MaterialProcessor = preload("res://addons/nexus_importer/processors/material_processor.gd")
const MultiMeshProcessor = preload("res://addons/nexus_importer/processors/multimesh_processor.gd")
const NavMeshProcessor = preload("res://addons/nexus_importer/processors/navmesh_processor.gd")
const NodeProcessor = preload("res://addons/nexus_importer/processors/node_processor.gd")
const RootProcessor = preload("res://addons/nexus_importer/processors/root_processor.gd")
const VertexColorProcessor = preload("res://addons/nexus_importer/processors/vertex_color_processor.gd")
const UvLayerProcessor = preload("res://addons/nexus_importer/processors/uv_layer_processor.gd")
const CameraProcessor = preload("res://addons/nexus_importer/processors/camera_processor.gd")
const PathProcessor = preload("res://addons/nexus_importer/processors/path_processor.gd")
const NestedCollectionProcessor = preload("res://addons/nexus_importer/processors/nested_collection_processor.gd")
const NexusMeshSanitize = preload("res://addons/nexus_importer/scripts/nexus_mesh_sanitize.gd")
const NexusTransformSanitize = preload("res://addons/nexus_importer/scripts/nexus_transform_sanitize.gd")

var animation_processor = AnimationProcessor.new()
var bone_attachment_processor = BoneAttachmentProcessor.new()
var collision_processor = CollisionProcessor.new()
var resonance_processor = ResonanceProcessor.new()
var instancing_processor = InstancingProcessor.new()
var light_processor = LightProcessor.new()
var lod_processor = LodProcessor.new()
var material_processor = MaterialProcessor.new()
var multimesh_processor = MultiMeshProcessor.new()
var navmesh_processor = NavMeshProcessor.new()
var node_processor = NodeProcessor.new()
var root_processor = RootProcessor.new()
var vertex_color_processor = VertexColorProcessor.new()
var uv_layer_processor = UvLayerProcessor.new()
var camera_processor = CameraProcessor.new()
var path_processor = PathProcessor.new()
var nested_collection_processor = NestedCollectionProcessor.new()

var stats: Dictionary = {
	"paths": 0,
	"materials": 0,
	"collisions": 0,
	"resonance": 0,
	"lods": 0,
	"instances": 0,
	"nested": 0,
	"lights": 0,
	"cameras": 0,
	"anims": 0,
	"physics": "",
	"surface": ""
}


func _post_import(scene: Node) -> Object:
	_reset_stats()

	var gltf_path = get_source_file()
	var scene_meta = NexusUtils.get_nexus_metadata(gltf_path)
	if scene_meta.is_empty():
		return scene

	if NexusBatchLock.is_active():
		NexusBatchLock.defer_path(gltf_path)
		return scene

	var export_type = scene_meta.get("export_type", "UNKNOWN")
	var root_type = scene_meta.get("root_type", "Node3D")
	scene = root_processor.ensure_vehicle_body_root(scene, scene_meta)
	scene.set_meta("_nexus_export_type", export_type)
	scene_meta["_summary_gltf_path"] = gltf_path

	var routed = _route_by_export_type(scene, gltf_path, scene_meta, export_type)
	if routed != null:
		return routed

	_process_scene_tree(scene, scene_meta, gltf_path, export_type)
	_log_import_summary(scene.name, export_type, root_type, scene_meta)

	return scene


func _reset_stats() -> void:
	stats = {
		"paths": 0,
		"materials": 0,
		"collisions": 0,
		"resonance": 0,
		"lods": 0,
		"instances": 0,
		"lights": 0,
		"cameras": 0,
		"anims": 0,
		"physics": "",
		"surface": ""
	}


func _route_by_export_type(
	scene: Node,
	gltf_path: String,
	scene_meta: Dictionary,
	export_type: String
) -> Object:
	if export_type == "ANIMATION_LIB":
		_apply_animation_settings(scene, scene_meta)
		var anim_stats = animation_processor.extract_and_save_animations(scene, gltf_path, scene_meta)
		stats.anims = anim_stats.extracted
		_print_anim_lib_summary(scene.name, {"extracted": anim_stats.extracted, "path": anim_stats.path})
		return scene

	if export_type == "MULTIMESH_MANIFEST":
		NexusImportContext.set_multimesh_post_import_active(true)
		var composite := multimesh_processor.process(gltf_path, scene_meta)
		NexusImportContext.set_multimesh_post_import_active(false)
		NexusSceneUtils.invalidate_multimesh_pipeline_cache(gltf_path)
		return composite

	return null


func _process_scene_tree(
	scene: Node,
	scene_meta: Dictionary,
	gltf_path: String,
	export_type: String
) -> void:
	# Neutralize degenerate (NaN/Inf or singular) Node3D transforms before any
	# processor or Godot subsystem reads them: physics planes, light culler and
	# affine_inverse all warn/fail on non-finite or zero-determinant bases.
	NexusTransformSanitize.sanitize_scene_transforms(scene)
	root_processor.set_collision_layers(scene, scene_meta, stats)
	navmesh_processor.process(scene, scene_meta)

	scene.set_meta("_nexus_gltf_path", gltf_path)
	instancing_processor.reset_import_budget()
	NexusSceneUtils.inject_nexus_node_extras_from_gltf(scene, gltf_path)
	var swap_nexus_materials := _should_swap_nexus_materials(scene_meta)
	if swap_nexus_materials:
		NexusSceneUtils.inject_nexus_material_extras_from_gltf(scene, gltf_path)
	NexusSceneUtils.reroll_duplicate_uuid_markers(scene)
	if export_type in LOD_PROCESS_EXPORT_TYPES:
		NexusMeshSanitize.sanitize_scene_meshes(scene, gltf_path.get_file())
	nested_collection_processor.process_scene(scene, stats)
	var nodes_under_instance = _collect_nodes_under_instance(scene)
	scene.set_meta("nexus_resonance_paths_used", [])
	scene.set_meta("nexus_resonance_mesh_rid_to_path", {})
	_process_node_recursively(scene, scene, scene_meta, nodes_under_instance)
	if swap_nexus_materials:
		_process_materials_recursively(scene, nodes_under_instance)
	else:
		_externalize_gltf_materials_recursively(scene, gltf_path, nodes_under_instance)

	_extract_animations_if_needed(scene, gltf_path, scene_meta, export_type)

	if export_type in LOD_PROCESS_EXPORT_TYPES:
		lod_processor.process(scene, stats)
		_remove_legacy_lod_deferred_nodes(scene)

	if not NexusImportContext.should_defer_external_scene_loads():
		stats.instances += instancing_processor.retry_pending_instances(scene)
		if NexusImportContext.is_instance_pass_active():
			if not InstancingProcessor.has_unresolved_placeholders(scene):
				scene.set_meta(InstancingProcessor.INSTANCES_RESOLVED_META, true)


func _extract_animations_if_needed(
	scene: Node,
	gltf_path: String,
	scene_meta: Dictionary,
	export_type: String
) -> void:
	if export_type not in ["ASSET", "SKELETAL_ASSET", "COMBINED_ASSET", "LEVEL"]:
		return
	var scene_style := NexusSceneUtils.preferred_scene_style_for_gltf(gltf_path)
	var anim_stats = animation_processor.extract_and_save_animations(
		scene, gltf_path, scene_meta, scene_style
	)
	stats.anims = anim_stats.extracted
	if anim_stats.extracted > 0 and not anim_stats.path.is_empty():
		scene.set_meta("nexus_anim_lib_path", anim_stats.path)


func _log_import_summary(name: String, export_type: String, root_type: String, meta: Dictionary) -> void:
	var gltf_path: String = str(meta.get("_summary_gltf_path", ""))
	_print_compact_summary(name, export_type, root_type, meta, gltf_path)


func _remove_legacy_lod_deferred_nodes(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for i in range(node.get_child_count() - 1, -1, -1):
			var child = node.get_child(i)
			if child.name == "NexusLodDeferred" and child.get_script() != null:
				node.remove_child(child)
				child.free()
			else:
				stack.append(child)


func _collect_nodes_under_instance(root: Node) -> Dictionary:
	var result: Dictionary = {}
	_collect_under_instance_visit(root, false, result)
	return result


func _collect_under_instance_visit(n: Node, ancestor_has_asset_id: bool, result: Dictionary) -> void:
	var extras = n.get_meta("extras", {})
	var node_meta = extras.get(NEXUS_NODE_META) if extras is Dictionary else {}
	var this_has_asset_id = (node_meta is Dictionary) and not str(node_meta.get("nexus_asset_id", "")).is_empty()
	var now_inside := ancestor_has_asset_id or this_has_asset_id
	if ancestor_has_asset_id:
		result[n.get_instance_id()] = true
	for child in n.get_children():
		_collect_under_instance_visit(child, now_inside, result)


func _process_node_recursively(
	node: Node,
	root: Node,
	scene_meta: Dictionary,
	nodes_under_instance: Dictionary = {}
) -> void:
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		_process_node_recursively(child, root, scene_meta, nodes_under_instance)

	var node_extras = node.get_meta("extras", {})
	if not node_extras is Dictionary or not NEXUS_NODE_META in node_extras:
		return
	var node_meta = node_extras[NEXUS_NODE_META]

	if node_meta.get("nexus_is_lod", false):
		return

	if path_processor.process(node, node_meta, node.get_parent()):
		stats.paths += 1
		return

	if instancing_processor.process(node, node_meta, root):
		stats.instances += 1
		return
	if light_processor.process(node, node_meta, root):
		stats.lights += 1
		return
	if camera_processor.process(node, node_meta):
		stats.cameras += 1
	# Bone attachment must run before collision so shapes end up under ModifierBoneTarget3D.
	bone_attachment_processor.process(node, node_meta, root)

	var skip_geometry_processors = nodes_under_instance.has(node.get_instance_id())
	if not skip_geometry_processors:
		# Resonance before collision (same mesh may become both)
		if resonance_processor.process(node, node_meta, scene_meta, root, stats):
			return
		if collision_processor.process(node, node_meta, scene_meta, root, stats):
			return

		vertex_color_processor.process(node, node_meta)
		uv_layer_processor.process(node, node_meta)
		node_processor.process(node, node_meta, scene_meta)


func _process_materials_recursively(node: Node, nodes_under_instance: Dictionary) -> void:
	if nodes_under_instance.has(node.get_instance_id()):
		return
	material_processor.process(node, stats)
	for child in node.get_children():
		_process_materials_recursively(child, nodes_under_instance)


func _externalize_gltf_materials_recursively(
	node: Node,
	gltf_path: String,
	nodes_under_instance: Dictionary
) -> void:
	material_processor.begin_externalize_pass()
	_externalize_gltf_materials_walk(node, gltf_path, nodes_under_instance)


func _externalize_gltf_materials_walk(
	node: Node,
	gltf_path: String,
	nodes_under_instance: Dictionary
) -> void:
	if nodes_under_instance.has(node.get_instance_id()):
		return
	material_processor.externalize_embedded(node, gltf_path, stats)
	for child in node.get_children():
		_externalize_gltf_materials_walk(child, gltf_path, nodes_under_instance)


func _should_swap_nexus_materials(scene_meta: Dictionary) -> bool:
	# Typical GLB embeds real materials; keep them instead of swapping to .tres.
	return NexusUtils.should_swap_nexus_materials(scene_meta)


func _apply_animation_settings(scene: Node, meta: Dictionary) -> void:
	var anim_player = NexusSceneUtils.find_animation_player(scene)
	if not anim_player:
		return

	var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
	if nexus_script:
		anim_player.set_script(nexus_script)

	var library = anim_player.get_animation_library("")
	if not library:
		return

	if scene is PhysicsBody3D:
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

	animation_processor.apply_scene_retargeting(scene, anim_player)

	var anim_list = library.get_animation_list()
	stats.anims = anim_list.size()

	if anim_list.size() > 0:
		anim_player.set_meta("nexus_autoplay", anim_list[0])

	var loop_data = meta.get("nexus_animation_loops", {})
	var marker_data = meta.get("nexus_animation_markers", {})
	var root_motion_data = meta.get("nexus_animation_root_motion", {})

	if loop_data.is_empty() and marker_data.is_empty() and root_motion_data.is_empty():
		return

	for anim_name in anim_list:
		var anim: Animation = library.get_animation(anim_name)
		var manifest_key = animation_processor.manifest_key_for_gltf_animation(anim_name, meta)

		if loop_data.has(manifest_key):
			match loop_data[manifest_key]:
				"LOOP": anim.loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": anim.loop_mode = Animation.LOOP_PINGPONG
				"ONCE": anim.loop_mode = Animation.LOOP_NONE

		if marker_data.has(manifest_key):
			animation_processor.add_marker_tracks(anim, marker_data[manifest_key], NodePath(anim_player.name))

		if root_motion_data.has(manifest_key):
			anim.set_meta("nexus_root_motion", true)


func _print_compact_summary(
	name: String,
	type: String,
	root: String,
	meta: Dictionary,
	gltf_path: String = ""
) -> void:
	var group = ""
	var groups = meta.get("godot_groups", [])
	if groups is Array:
		var group_parts: PackedStringArray = []
		for g in groups:
			var label = str(g).strip_edges()
			if not label.is_empty():
				group_parts.append(label)
		group = ", ".join(group_parts)
	var script = meta.get("script_path", "").get_file()

	var parts = []
	if stats.paths > 0: parts.append("%d Paths" % stats.paths)
	if stats.materials > 0: parts.append("%d Mats" % stats.materials)
	if stats.collisions > 0: parts.append("%d Cols" % stats.collisions)
	if stats.get("resonance", 0) > 0: parts.append("%d Resonance" % stats.resonance)
	if stats.anims > 0: parts.append("%d Anims" % stats.anims)
	if stats.lods > 0: parts.append("%d LODs" % stats.lods)
	if stats.lights > 0: parts.append("%d Lights" % stats.lights)
	if stats.cameras > 0: parts.append("%d Cameras" % stats.cameras)
	if stats.instances > 0: parts.append("%d Inst" % stats.instances)

	var details = []
	if not group.is_empty(): details.append("Grp: " + group)
	if not script.is_empty(): details.append("Scr: " + script)
	if not stats.physics.is_empty(): details.append("Phy: " + stats.physics)
	if not stats.surface.is_empty(): details.append("Srf: " + stats.surface)

	var stat_str = ", ".join(parts) if parts else _empty_stats_label(type, gltf_path)
	var detail_str = " | ".join(details)

	if detail_str.is_empty():
		print_rich("[color=cyan]Nexus:[/color] %s (%s) -> [color=gray]%s[/color]" % [name, root, stat_str])
	else:
		print_rich(
			"[color=cyan]Nexus:[/color] %s (%s) -> [color=gray]%s[/color] -> [color=green]%s[/color]"
			% [name, root, stat_str, detail_str]
		)


func _empty_stats_label(export_type: String, gltf_path: String) -> String:
	if export_type == "SKELETAL_ASSET" and _gltf_has_skins_without_meshes(gltf_path):
		return "Skeleton only"
	return "No Geometry"


func _gltf_has_skins_without_meshes(gltf_path: String) -> bool:
	if gltf_path.is_empty() or not NexusUtils.is_gltf_container_path(gltf_path):
		return false
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return false
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return false
	var gltf = json.get_data()
	if gltf == null or not gltf is Dictionary:
		return false
	var skins = gltf.get("skins", [])
	if not skins is Array or skins.is_empty():
		return false
	var meshes = gltf.get("meshes", [])
	return not meshes is Array or meshes.is_empty()


func _print_anim_lib_summary(name: String, anim_stats: Dictionary) -> void:
	var extracted = anim_stats.get("extracted", 0)
	var path = anim_stats.get("path", "")
	if path.is_empty():
		print_rich(
			"[color=cyan]Nexus:[/color] %s (ANIM_LIB) -> [color=gray]%d animations extracted[/color]"
			% [name, extracted]
		)
	else:
		print_rich(
			"[color=cyan]Nexus:[/color] %s (ANIM_LIB) -> [color=gray]%d animations -> %s[/color]"
			% [name, extracted, path.get_file()]
		)
