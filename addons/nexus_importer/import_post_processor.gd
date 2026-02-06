@tool
extends EditorScenePostImport

## Post-import processor for Nexus glTF assets. Converts nodes, materials, animations, LODs, etc.

const NEXUS_ASSET_META = "NEXUS_ASSET_METADATA"
const NEXUS_NODE_META = "NEXUS_NODE_METADATA"

const AnimationProcessor = preload("res://addons/nexus_importer/processors/animation_processor.gd")
const BoneAttachmentProcessor = preload("res://addons/nexus_importer/processors/bone_attachment_processor.gd")
const CollisionProcessor = preload("res://addons/nexus_importer/processors/collision_processor.gd")
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
var stats = {
	"paths": 0,
	"materials": 0,
	"collisions": 0,
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
	
	# --- EXPORT TYPE CHECKS ---
	if export_type == "ANIMATION_LIB":
		_apply_animation_settings(scene, scene_meta)
		var anim_stats = animation_processor.process(scene, scene_meta)
		_print_anim_lib_summary(scene.name, anim_stats)
		return scene
		
	if export_type == "MULTIMESH_MANIFEST":
		return multimesh_processor.process(gltf_path, scene_meta)

	# --- NODE PROCESSING ---
	root_processor.set_collision_layers(scene, scene_meta, stats)
	navmesh_processor.process(scene, scene_meta)
	
	_process_node_recursively(scene, scene, scene_meta)
	_process_materials_recursively(scene)
	
	# --- ANIMATION EXTRACTION (only here!) ---
	# For assets or levels, extract animations.
	if export_type in ["ASSET", "SKELETAL_ASSET", "LEVEL"]:
		var anim_stats = animation_processor.extract_and_save_animations(scene, gltf_path, scene_meta)
		stats.anims = anim_stats.extracted
		
		# Store path to extracted file in root meta so plugin.gd can read it when building the wrapper.
		if anim_stats.extracted > 0:
			scene.set_meta("nexus_anim_lib_path", anim_stats.path)

	lod_processor.process(scene, stats)
	
	_print_compact_summary(scene.name, export_type, scene_meta.get("root_type", "Node3D"), scene_meta)
	
	return scene

func _process_node_recursively(node: Node, root: Node, scene_meta: Dictionary):
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		_process_node_recursively(child, root, scene_meta)
	
	var node_extras = node.get_meta("extras", {})
	if not NEXUS_NODE_META in node_extras: return
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
		pass
	if bone_attachment_processor.process(node, node_meta, root): return
	
	# Pass Stats to Collision Processor!
	if collision_processor.process(node, node_meta, scene_meta, root, stats): 
		return
	
	vertex_color_processor.process(node, node_meta)
	node_processor.process(node, node_meta, scene_meta)

func _process_materials_recursively(node: Node):
	# Pass Stats to Material Processor!
	material_processor.process(node, stats)
	for child in node.get_children():
		_process_materials_recursively(child)

func _apply_animation_settings(scene: Node, meta: Dictionary):
	# 1. Find Player (Always do this first)
	var anim_player = _find_animation_player(scene)
	if not anim_player: return

	# 2. Nexus script on AnimationPlayer (on_nexus_event, get_nexus_markers)
	var nexus_script = load("res://addons/nexus_importer/runtime/nexus_animation_player.gd")
	if nexus_script:
		anim_player.set_script(nexus_script)

	# 3. Get Library
	var library = anim_player.get_animation_library("")
	if not library: return
	
	if scene is PhysicsBody3D:
		anim_player.callback_mode_process = AnimationPlayer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	
	animation_processor.apply_scene_retargeting(scene, anim_player) 
	
	var anim_list = library.get_animation_list()
	stats.anims = anim_list.size()
	
	# 3. Always set Autoplay and Current Animation for preview
	# This ensures the animation is visible in the editor immediately.
	if anim_list.size() > 0:
		anim_player.autoplay = anim_list[0]
		anim_player.current_animation = anim_list[0] 
		anim_player.advance(0)

	# 4. Check for Nexus Metadata
	var loop_data = meta.get("nexus_animation_loops", {})
	var marker_data = meta.get("nexus_animation_markers", {})
	var root_motion_data = meta.get("nexus_animation_root_motion", {})
	
	if loop_data.is_empty() and marker_data.is_empty() and root_motion_data.is_empty():
		return

	# 5. Apply Settings
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
			var markers = marker_data[anim_name]
			_remove_legacy_method_tracks(anim)
			anim.set_meta("nexus_markers", markers)
			var track_idx = anim.add_track(Animation.TYPE_METHOD)
			anim.track_set_path(track_idx, NodePath(anim_player.name))
			for m in markers:
				var marker_name = m.get("name", "") if m is Dictionary else str(m)
				var marker_time = m.get("time", 0.0) if m is Dictionary else 0.0
				var key_data = {"method": "on_nexus_event", "args": [marker_name]}
				anim.track_insert_key(track_idx, marker_time, key_data)
				
		# C. Root Motion Flag
		if root_motion_data.has(anim_name):
			anim.set_meta("nexus_root_motion", true)

func _remove_legacy_method_tracks(anim: Animation) -> void:
	for i in range(anim.get_track_count() - 1, -1, -1):
		if anim.track_get_type(i) == Animation.TYPE_METHOD:
			for k in range(anim.track_get_key_count(i)):
				var key_val = anim.track_get_key_value(i, k)
				if key_val is Dictionary and key_val.get("method", "") == "on_nexus_event":
					anim.remove_track(i)
					break

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer: return node
	for child in node.get_children():
		var res = _find_animation_player(child)
		if res: return res
	return null

func _print_compact_summary(name: String, type: String, root: String, meta: Dictionary):
	var group = meta.get("group_name", "")
	var script = meta.get("script_path", "").get_file()
	
	var parts = []
	if stats.paths > 0: parts.append("%d Paths" % stats.paths)
	if stats.materials > 0: parts.append("%d Mats" % stats.materials)
	if stats.collisions > 0: parts.append("%d Cols" % stats.collisions)
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

func _print_anim_lib_summary(name: String, anim_stats: Dictionary):
	var added = anim_stats.get("added", 0)
	var removed = anim_stats.get("removed", 0)
	print_rich("[color=cyan]Nexus:[/color] %s (ANIM_LIB) -> [color=gray]%d Added, %d Removed[/color]" % [name, added, removed])
