# file: addons/nexus_importer/processors/material_processor.gd
@tool
extends Object

var _material_index: Dictionary = {}
var _index_loaded: bool = false

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

func _check_and_apply_pending_update(mat_id: String) -> void:
	pass

func process(node: Node):
	if not node is MeshInstance3D or not is_instance_valid(node.mesh):
		return

	if not _load_material_index():
		return

	# Wir duplizieren das Mesh einmal, wenn wir Änderungen vornehmen müssen.
	var mesh_was_duplicated = false

	for i in range(node.mesh.get_surface_count()):
		var current_material: Material = node.mesh.surface_get_material(i)
		if not is_instance_valid(current_material):
			continue
			
		# Wir suchen nicht mehr nach "DUMMY_", sondern direkt nach unserer ID in den Metadaten.
		if current_material.has_meta("extras"):
			var extras = current_material.get_meta("extras")
			if extras.has("nexus_material_id"):
				var mat_id = extras["nexus_material_id"]
				
				if _material_index.has(mat_id):
					var tres_path = "res://" + _material_index[mat_id]["relative_path"]
					if not ResourceLoader.exists(tres_path):
						continue

					var external_material = ResourceLoader.load(tres_path)
					if is_instance_valid(external_material):
						# Erstelle eine einzigartige Kopie des Meshes, bevor wir es ändern.
						if not mesh_was_duplicated:
							node.mesh = node.mesh.duplicate()
							mesh_was_duplicated = true
						
						# Wende das externe .tres-Material an.
						node.mesh.surface_set_material(i, external_material)
