@tool
extends Object

## Swaps mesh materials based on nexus_material_id using material_index.json.

var _material_index: Dictionary = {}
var _index_loaded: bool = false

func _load_material_index() -> bool:
	var path = ProjectSettings.get_setting("nexus/import/material_index_path", "res://material_index.json")
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		_index_loaded = true
		return false

	var json = JSON.new()
	if json.parse(file.get_as_text()) == OK:
		_material_index = json.get_data()
	file.close()

	_index_loaded = true
	return not _material_index.is_empty()

func process(node: Node, stats: Dictionary) -> void:
	if not node is MeshInstance3D or not is_instance_valid(node.mesh): return
	if not _load_material_index(): return

	var mesh_was_duplicated = false
	var swapped_count = 0

	for i in range(node.mesh.get_surface_count()):
		var current_material: Material = node.mesh.surface_get_material(i)
		if not is_instance_valid(current_material): continue
			
		if current_material.has_meta("extras"):
			var extras = current_material.get_meta("extras")
			if extras.has("nexus_material_id"):
				var mat_id = extras["nexus_material_id"]
				var mat_entry = _material_index.get(mat_id, {})
				if mat_entry is Dictionary:
					var rel_path = mat_entry.get("relative_path", "")
					if not rel_path.is_empty():
						var tres_path = NexusUtils.validate_index_path(rel_path)
						if not tres_path.is_empty() and ResourceLoader.exists(tres_path):
							var external_material = ResourceLoader.load(tres_path, "", ResourceLoader.CACHE_MODE_REPLACE)
							if is_instance_valid(external_material):
								if not mesh_was_duplicated:
									node.mesh = node.mesh.duplicate()
									mesh_was_duplicated = true
								node.mesh.surface_set_material(i, external_material)
								swapped_count += 1
	
	stats.materials += swapped_count
