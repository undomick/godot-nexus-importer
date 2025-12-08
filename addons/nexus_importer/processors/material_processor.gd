# file: addons/nexus_importer/processors/material_processor.gd
@tool
extends Object

var _material_index: Dictionary = {}
var _index_loaded: bool = false

# Loads the material_index.json file once per import session to minimize disk I/O.
func _load_material_index() -> bool:
	if _index_loaded:
		return not _material_index.is_empty()

	var file = FileAccess.open('res://material_index.json', FileAccess.READ)
	if not file:
		_index_loaded = true
		return false
	
	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		_material_index = json.get_data()
	
	_index_loaded = true
	return not _material_index.is_empty()

# Main processing function called for every node.
# It replaces placeholder materials with the actual .tres resources defined in the index.
func process(node: Node):
	if not node is MeshInstance3D or not is_instance_valid(node.mesh):
		return

	if not _load_material_index():
		return

	# We duplicate the mesh resource once if we need to modify materials.
	# This ensures we don't accidentally modify the shared original resource 
	# if it is used elsewhere, while keeping instances sharing the same modified mesh linked.
	var mesh_was_duplicated = false

	for i in range(node.mesh.get_surface_count()):
		var current_material: Material = node.mesh.surface_get_material(i)
		
		# If no material is assigned, we can't check for metadata.
		if not is_instance_valid(current_material):
			continue
			
		# Check for the ID injected by the Blender extension hook.
		if current_material.has_meta("extras"):
			var extras = current_material.get_meta("extras")
			if extras.has("nexus_material_id"):
				var mat_id = extras["nexus_material_id"]
				
				if _material_index.has(mat_id):
					var tres_path = "res://" + _material_index[mat_id]["relative_path"]
					
					if ResourceLoader.exists(tres_path):
						# CRITICAL FIX: Use CACHE_MODE_REPLACE.
						# This forces Godot to reload the resource from disk, ignoring the RAM cache.
						# This solves "ghosting" issues where material updates in Blender 
						# were not visible in Godot until a restart.
						var external_material = ResourceLoader.load(tres_path, "", ResourceLoader.CACHE_MODE_REPLACE)
						
						if is_instance_valid(external_material):
							# Create a unique copy of the mesh before modifying it.
							if not mesh_was_duplicated:
								node.mesh = node.mesh.duplicate()
								mesh_was_duplicated = true
							
							# Swap the placeholder with the actual Godot material.
							node.mesh.surface_set_material(i, external_material)
