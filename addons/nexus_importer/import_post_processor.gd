@tool
extends EditorScenePostImport

## Post-import processor for Nexus glTF assets. Converts nodes, materials, animations, LODs, etc.

const NEXUS_ASSET_META = "NEXUS_ASSET_METADATA"
const NEXUS_NODE_META = "NEXUS_NODE_METADATA"

const AnimationProcessor = preload("res://addons/nexus_importer/processors/animation_processor.gd")
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
const CameraProcessor = preload("res://addons/nexus_importer/processors/camera_processor.gd")
const PathProcessor = preload("res://addons/nexus_importer/processors/path_processor.gd")

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
var camera_processor = CameraProcessor.new()
var path_processor = PathProcessor.new()

# --- STATISTICS CONTAINER ---
var stats: Dictionary = {
	"paths": 0,
	"materials": 0,
	"collisions": 0,
	"resonance": 0,
	"lods": 0,
	"scripts": 0,
	"instances": 0,
	"lights": 0,
	"cameras": 0,
	"anims": 0,
	"physics": "",
	"surface": ""
}

func _post_import(scene: Node) -> Object:
	# Reset Stats
	stats = {
		"paths": 0,
		"materials": 0,
		"collisions": 0,
		"resonance": 0,
		"lods": 0,
		"scripts": 0,
		"instances": 0,
		"lights": 0,
		"cameras": 0,
		"anims": 0,
		"physics": "",
		"surface": ""
	}
	
	var gltf_path = get_source_file()
	var scene_meta = NexusUtils.get_nexus_metadata(gltf_path)
	if scene_meta.is_empty(): return scene
	
	var export_type = scene_meta.get("export_type", "UNKNOWN")
	var root_type = scene_meta.get("root_type", "Node3D")
	scene.set_meta("_nexus_export_type", export_type)
	
	# --- EXPORT TYPE CHECKS ---
	if export_type == "ANIMATION_LIB":
		_apply_animation_settings(scene, scene_meta)
		# Extract and save AnimationLibrary .tres to target asset folder (target_animlib_path from manifest)
		var anim_stats = animation_processor.extract_and_save_animations(scene, gltf_path, scene_meta)
		stats.anims = anim_stats.extracted
		_print_anim_lib_summary(scene.name, {"extracted": anim_stats.extracted, "path": anim_stats.path})
		return scene
		
	if export_type == "MULTIMESH_MANIFEST":
		return multimesh_processor.process(gltf_path, scene_meta)

	# --- NODE PROCESSING ---
	root_processor.set_collision_layers(scene, scene_meta, stats)
	navmesh_processor.process(scene, scene_meta)
	
	# Pass glTF path for bone attachment fallback (read raw node transform from file)
	scene.set_meta("_nexus_gltf_path", gltf_path)
	# Godot 4.4+ puts glTF extras in node meta; older versions may not – inject from glTF if missing
	_inject_extras_from_gltf(scene, gltf_path)
	# Pre-pass: nodes under nexus_asset_id will be replaced by instancing – skip resonance/collision to avoid duplicates
	var nodes_under_instance = _collect_nodes_under_instance(scene)
	# Resonance processor reuses paths within same import; overwrites on reimport. Must be reset per asset.
	scene.set_meta("nexus_resonance_paths_used", [])
	_process_node_recursively(scene, scene, scene_meta, nodes_under_instance)
	_process_materials_recursively(scene)
	
	# --- ANIMATION EXTRACTION (only here!) ---
	# For assets or levels, extract animations.
	if export_type in ["ASSET", "SKELETAL_ASSET", "LEVEL"]:
		var anim_stats = animation_processor.extract_and_save_animations(scene, gltf_path, scene_meta)
		stats.anims = anim_stats.extracted
		
		# Store path to extracted file in root meta so plugin.gd can read it when building the wrapper.
		if anim_stats.extracted > 0:
			scene.set_meta("nexus_anim_lib_path", anim_stats.path)

	if export_type in ["ASSET", "SKELETAL_ASSET"]:
		lod_processor.process(scene, stats)

	# Inject deferred LOD applicator when visibility range was applied (stored in meta)
	if stats.lods > 0:
		var applicator = Node.new()
		applicator.name = "NexusLodDeferred"
		applicator.set_script(load("res://addons/nexus_importer/runtime/nexus_lod_deferred.gd"))
		scene.add_child(applicator)
		applicator.owner = scene

	_print_compact_summary(scene.name, export_type, root_type, scene_meta)

	return scene

func _inject_extras_from_gltf(root: Node, gltf_path: String) -> void:
	## Ensures node extras (NEXUS_NODE_METADATA) are available. Godot 4.4+ imports them to meta;
	## older versions may not – in that case we read from glTF and inject manually.
	if gltf_path.is_empty() or not NexusUtils.is_gltf_container_path(gltf_path):
		return
	var json_text := NexusUtils.get_gltf_json_text(gltf_path)
	if json_text.is_empty():
		return
	var json = JSON.new()
	if json.parse(json_text) != OK:
		return
	var gltf = json.get_data()
	if gltf == null: return
	var nodes = gltf.get("nodes", [])
	var name_to_extras: Dictionary = {}
	for n in nodes:
		var extras = n.get("extras", {})
		var node_meta = extras.get("NEXUS_NODE_METADATA")
		if node_meta:
			var nm = n.get("name", "")
			if not nm.is_empty():
				name_to_extras[nm] = extras
	if name_to_extras.is_empty(): return
	var stack: Array = [root]
	while not stack.is_empty():
		var nd = stack.pop_back()
		if nd.name in name_to_extras:
			var existing = nd.get_meta("extras", {})
			if not (existing is Dictionary) or not existing.has("NEXUS_NODE_METADATA"):
				nd.set_meta("extras", name_to_extras[nd.name])
		for i in range(nd.get_child_count() - 1, -1, -1):
			stack.append(nd.get_child(i))

func _collect_nodes_under_instance(root: Node) -> Dictionary:
	## Returns a set (dict of id->true) of nodes that are descendants of a node with nexus_asset_id.
	## These nodes will be replaced by instancing – skip resonance/collision to avoid duplicates.
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

func _process_node_recursively(node: Node, root: Node, scene_meta: Dictionary, nodes_under_instance: Dictionary = {}) -> void:
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		_process_node_recursively(child, root, scene_meta, nodes_under_instance)
	
	var node_extras = node.get_meta("extras", {})
	if not node_extras is Dictionary or not NEXUS_NODE_META in node_extras:
		return
	var node_meta = node_extras[NEXUS_NODE_META]

	if node_meta.get("nexus_is_lod", false): return

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
	if bone_attachment_processor.process(node, node_meta, root): return

	# Skip resonance/collision for nodes under nexus_asset_id – whole subtree gets replaced by instanced asset
	var skip_geometry_processors = nodes_under_instance.has(node.get_instance_id())
	if not skip_geometry_processors:
		# Resonance Geometry (must run before Collision Processor)
		if resonance_processor.process(node, node_meta, scene_meta, root, stats):
			return
		# Pass Stats to Collision Processor!
		if collision_processor.process(node, node_meta, scene_meta, root, stats):
			return

	vertex_color_processor.process(node, node_meta)
	node_processor.process(node, node_meta, scene_meta)

func _process_materials_recursively(node: Node) -> void:
	# Pass Stats to Material Processor!
	material_processor.process(node, stats)
	for child in node.get_children():
		_process_materials_recursively(child)

func _apply_animation_settings(scene: Node, meta: Dictionary) -> void:
	var anim_player = _find_animation_player(scene)
	if not anim_player: return

	var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
	if nexus_script:
		anim_player.set_script(nexus_script)

	var library = anim_player.get_animation_library("")
	if not library: return

	if scene is PhysicsBody3D:
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS

	animation_processor.apply_scene_retargeting(scene, anim_player)

	var anim_list = library.get_animation_list()
	stats.anims = anim_list.size()

	# Use nexus_autoplay meta (deferred play) to avoid "data.tree is null" when opening at editor startup
	if anim_list.size() > 0:
		anim_player.set_meta("nexus_autoplay", anim_list[0])

	# 4. Check for Nexus Metadata
	var loop_data = meta.get("nexus_animation_loops", {})
	var marker_data = meta.get("nexus_animation_markers", {})
	var root_motion_data = meta.get("nexus_animation_root_motion", {})
	
	if loop_data.is_empty() and marker_data.is_empty() and root_motion_data.is_empty():
		return

	for anim_name in anim_list:
		var anim: Animation = library.get_animation(anim_name)
		
		# A. Loop Modes
		if loop_data.has(anim_name):
			var loop_type = loop_data[anim_name]
			match loop_type:
				"LOOP": anim.loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": anim.loop_mode = Animation.LOOP_PINGPONG
				"ONCE": anim.loop_mode = Animation.LOOP_NONE
		
		# B. Method call tracks (visible) + metadata (get_nexus_markers)
		if marker_data.has(anim_name):
			animation_processor.add_marker_tracks(anim, marker_data[anim_name], NodePath(anim_player.name))

		# C. Root Motion Flag
		if root_motion_data.has(anim_name):
			anim.set_meta("nexus_root_motion", true)

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer: return node
	for child in node.get_children():
		var res = _find_animation_player(child)
		if res: return res
	return null

func _print_compact_summary(name: String, type: String, root: String, meta: Dictionary) -> void:
	var group = meta.get("group_name", "")
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
	
	var stat_str = ", ".join(parts) if parts else "No Geometry"
	var detail_str = " | ".join(details)
	
	if detail_str.is_empty():
		print_rich("[color=cyan]Nexus:[/color] %s (%s) -> [color=gray]%s[/color]" % [name, root, stat_str])
	else:
		print_rich("[color=cyan]Nexus:[/color] %s (%s) -> [color=gray]%s[/color] -> [color=green]%s[/color]" % [name, root, stat_str, detail_str])

func _print_anim_lib_summary(name: String, anim_stats: Dictionary) -> void:
	var extracted = anim_stats.get("extracted", 0)
	var path = anim_stats.get("path", "")
	if path.is_empty():
		print_rich("[color=cyan]Nexus:[/color] %s (ANIM_LIB) -> [color=gray]%d animations extracted[/color]" % [name, extracted])
	else:
		print_rich("[color=cyan]Nexus:[/color] %s (ANIM_LIB) -> [color=gray]%d animations -> %s[/color]" % [name, extracted, path.get_file()])
