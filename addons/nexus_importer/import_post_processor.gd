@tool
extends EditorScenePostImport

const NEXUS_ASSET_META = "NEXUS_ASSET_METADATA"
const NEXUS_NODE_META = "NEXUS_NODE_METADATA"

# All processor instances are loaded here.
const AnimationProcessor = preload("res://addons/nexus_importer/processors/animation_processor.gd")
const BoneAttachmentProcessor = preload("res://addons/nexus_importer/processors/bone_attachment_processor.gd")
const CollisionProcessor = preload("res://addons/nexus_importer/processors/collision_processor.gd")
const InstancingProcessor = preload("res://addons/nexus_importer/processors/instancing_processor.gd")
const LightProcessor = preload("res://addons/nexus_importer/processors/light_processor.gd")
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
var material_processor = MaterialProcessor.new()
var multimesh_processor = MultiMeshProcessor.new()
var navmesh_processor = NavMeshProcessor.new()
var node_processor = NodeProcessor.new()
var root_processor = RootProcessor.new()
var vertex_color_processor = VertexColorProcessor.new()


# This is the main function of the "Worker".
# It is called by Godot after the GLTF has been converted to a PackedScene.
func _post_import(scene: Node) -> Object:
	var gltf_path = get_source_file()
	
	# === DIE ROBUSTE METHODE (NACH BLENDER-STUDIO-VORBILD) ===
	# Wir ignorieren die Metadaten des 'scene'-Node und lesen sie direkt
	# aus der ursprünglichen .gltf-Datei. Das ist die Quelle der Wahrheit.
	var scene_meta = _get_nexus_metadata_from_file(gltf_path)
	if scene_meta.is_empty():
		# Dies ist keine Nexus-Datei, also nichts tun.
		return scene
	
	# Erstelle die .tscn-Datei, falls sie nicht existiert.
	_ensure_scene_file_exists(gltf_path, scene)
		
	# Handle spezielle Export-Typen
	var export_type = scene_meta.get("export_type")
	if export_type == "ANIMATION_LIB":
		animation_processor.process(scene, scene_meta)
		return scene 
	if export_type == "MULTIMESH_MANIFEST":
		return multimesh_processor.process(gltf_path, scene_meta)

	# Führe alle strukturellen Prozessoren aus.
	print("Nexus Worker: Processing nodes for '%s'..." % scene.name) # Debug-Ausgabe
	root_processor.set_collision_layers(scene, scene_meta)
	navmesh_processor.process(scene, scene_meta)
	_process_node_recursively(scene, scene, scene_meta)
	_process_materials_recursively(scene)
	
	return scene

func _get_nexus_metadata_from_file(gltf_path: String) -> Dictionary:
	if not FileAccess.file_exists(gltf_path): return {}
	var file = FileAccess.open(gltf_path, FileAccess.READ)
	if not file: return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK: return {}
	var gltf_data = json.get_data()
	
	# 1. Standard
	var meta = gltf_data.get("scenes", [{}])[0].get("extras", {}).get("NEXUS_ASSET_METADATA", {})
	
	# 2. Optimizer Fallback (Asset Extras)
	if meta.is_empty():
		meta = gltf_data.get("asset", {}).get("extras", {}).get("NEXUS_ASSET_METADATA", {})
		
	return meta

# This function is the direct equivalent of `ensure_scene_for_gltf` from the Blender Studio addon.
# Its only job is to create the wrapper .tscn if it doesn't already exist.
func _ensure_scene_file_exists(gltf_path: String, imported_scene: Node):
	var scene_path = gltf_path.get_base_dir().path_join(imported_scene.name + ".tscn")

	if FileAccess.file_exists(scene_path):
		return # The file already exists, our job is done.

	print("Nexus Worker: Proactively creating missing scene file at '%s'." % scene_path)
	
	var packed_scene = PackedScene.new()
	var root_node = Node3D.new()
	root_node.name = imported_scene.name

	# Load the original, unprocessed GLTF as a resource to instance it.
	var gltf_resource: PackedScene = ResourceLoader.load(gltf_path)
	if not gltf_resource:
		push_error("Nexus Worker: Could not load GLTF resource to create scene instance.")
		return
		
	var gltf_instance = gltf_resource.instantiate()
	
	root_node.add_child(gltf_instance)
	gltf_instance.owner = root_node
	
	if packed_scene.pack(root_node) == OK:
		ResourceSaver.save(packed_scene, scene_path)
	
	root_node.free()


# --- Recursive Processor Calls (Unchanged) ---
func _process_node_recursively(node: Node, root: Node, scene_meta: Dictionary):
	print("Processing Node: %s (Type: %s)" % [node.name, node.get_class()])
	
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		_process_node_recursively(child, root, scene_meta)
	
	var node_extras = node.get_meta("extras", {})
	if not NEXUS_NODE_META in node_extras: return
	var node_meta = node_extras[NEXUS_NODE_META]

	if instancing_processor.process(node, node_meta, root): return
	if light_processor.process(node, node_meta, root): return
	if bone_attachment_processor.process(node, node_meta, root): return
	if collision_processor.process(node, node_meta, root): return
	
	vertex_color_processor.process(node, node_meta)
	node_processor.process(node, node_meta)
	
func _process_materials_recursively(node: Node):
	material_processor.process(node)
	for child in node.get_children():
		_process_materials_recursively(child)
