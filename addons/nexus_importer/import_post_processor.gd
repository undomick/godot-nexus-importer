@tool
extends EditorScenePostImport

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


func _post_import(scene: Node) -> Object:
	# --- DEBUG ZEILE ---
	print("Nexus Entry: _post_import called for '%s'" % get_source_file())
	
	var gltf_path = get_source_file()
	
	var scene_meta = _get_nexus_metadata_from_file(gltf_path)
	if scene_meta.is_empty():
		return scene
	
	var export_type = scene_meta.get("export_type")
	
	# --- EXPORT TYPE CHECKS ---
	
	if export_type == "ANIMATION_LIB":
		animation_processor.process(scene, scene_meta)
		return scene 
		
	if export_type == "MULTIMESH_MANIFEST":
		return multimesh_processor.process(gltf_path, scene_meta)

	# --- NODE PROCESSING ---

	print("Nexus Worker: Processing nodes for '%s'..." % scene.name)
	
	root_processor.set_collision_layers(scene, scene_meta)
	navmesh_processor.process(scene, scene_meta)
	
	_process_node_recursively(scene, scene, scene_meta)
	
	_process_materials_recursively(scene)
	_apply_animation_settings(scene, scene_meta)
	
	lod_processor.process(scene)
	
	return scene

func _get_nexus_metadata_from_file(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path): return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return {}
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return {}
	var gltf_data = json.get_data()
	
	# 1. Check Root Extras (MultiMesh Manifests usually land here)
	var meta = gltf_data.get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 2. Check Scene Extras (Standard Assets)
	if meta.is_empty():
		meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 3. Check Asset Extras (Optimizer Fallback)
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
		
	return meta

func _apply_animation_settings(scene: Node, meta: Dictionary):
	var loop_data = meta.get("nexus_animation_loops", {})
	var marker_data = meta.get("nexus_animation_markers", {})
	
	if loop_data.is_empty() and marker_data.is_empty():
		return

	var anim_player = _find_animation_player(scene)
	if not anim_player: return

	var library = anim_player.get_animation_library("")
	if not library: return

	for anim_name in library.get_animation_list():
		var anim: Animation = library.get_animation(anim_name)
		
		# 1. Apply Loop
		if loop_data.has(anim_name):
			var loop_type = loop_data[anim_name]
			match loop_type:
				"LOOP": anim.loop_mode = Animation.LOOP_LINEAR
				"PINGPONG": anim.loop_mode = Animation.LOOP_PINGPONG
				"ONCE": anim.loop_mode = Animation.LOOP_NONE
		
		# 2. Apply Markers
		if marker_data.has(anim_name):
			var markers = marker_data[anim_name]
			var track_idx = -1
			for i in range(anim.get_track_count()):
				if anim.track_get_type(i) == Animation.TYPE_METHOD and anim.track_get_path(i) == NodePath("."):
					track_idx = i
					break
			
			if track_idx == -1:
				track_idx = anim.add_track(Animation.TYPE_METHOD)
				anim.track_set_path(track_idx, ".")
			
			while anim.track_get_key_count(track_idx) > 0:
				anim.track_remove_key(track_idx, 0)
				
			for m in markers:
				var key_data = {"method": "on_nexus_event", "args": [m["name"]]}
				anim.track_insert_key(track_idx, m["time"], key_data)
				
			print(" -> Added %d markers to animation '%s'." % [markers.size(), anim_name])

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer: return node
	for child in node.get_children():
		var res = _find_animation_player(child)
		if res: return res
	return null

# --- Recursive Processor Calls ---

func _process_node_recursively(node: Node, root: Node, scene_meta: Dictionary):
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		_process_node_recursively(child, root, scene_meta)
	
	var node_extras = node.get_meta("extras", {})
	if not NEXUS_NODE_META in node_extras: return
	var node_meta = node_extras[NEXUS_NODE_META]

	# --- LOD GATEKEEPER ---
	if node_meta.get("nexus_is_lod", false):
		return
	# ----------------------

	if instancing_processor.process(node, node_meta, root): return
	if light_processor.process(node, node_meta, root): return
	if bone_attachment_processor.process(node, node_meta, root): return
	if collision_processor.process(node, node_meta, root): return
	
	vertex_color_processor.process(node, node_meta)
	
	node_processor.process(node, node_meta, scene_meta)
	
func _process_materials_recursively(node: Node):
	material_processor.process(node)
	for child in node.get_children():
		_process_materials_recursively(child)
