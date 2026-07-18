@tool
extends Object

const NexusMeshSanitize = preload("res://addons/nexus_importer/scripts/nexus_mesh_sanitize.gd")

## Swaps mesh materials based on nexus_material_id using material_index.json.
## Targets may be StandardMaterial3D, ORMMaterial3D, or ShaderMaterial (.tres + .gdshader from shader graph convert).
## For material_pipeline=gltf, externalize_embedded writes editable .tres sidecars next to the GLB.

const EXPECTED_SHADER_CONVERT_VERSION := 5

var _material_index: Dictionary = {}
var _index_mtime: int = -1
var _warned_versions: Dictionary = {}
## instance_id -> loaded Material for one import pass (dedupe across surfaces/meshes).
var _externalize_cache: Dictionary = {}
## Reserved sidecar paths for this import (avoid name collisions before files exist).
var _externalize_claimed_paths: Dictionary = {}

func _load_material_index() -> bool:
	var path = NexusPaths.material_index_path()
	if not FileAccess.file_exists(path):
		_index_mtime = -1
		_material_index = {}
		return false

	var mtime := FileAccess.get_modified_time(path)
	if mtime == _index_mtime and not _material_index.is_empty():
		return true

	var load_result := NexusUtils.try_load_index_json(path, "material_index.json")
	if not load_result.ok:
		if load_result.error.contains("not valid JSON") or load_result.error.contains("root must be"):
			push_error("Nexus Material: %s" % load_result.error)
		_index_mtime = -1
		_material_index = {}
		return false

	_material_index = load_result.entries
	_index_mtime = mtime
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
								_check_shader_convert_version(external_material, mat_id)
								if not mesh_was_duplicated:
									node.mesh = node.mesh.duplicate()
									mesh_was_duplicated = true
								node.mesh.surface_set_material(i, external_material)
								if external_material.get_meta("nexus_uses_vertex_color", false):
									_ensure_mesh_vertex_colors(node)
								swapped_count += 1
	
	stats.materials += swapped_count


## Reset per-import caches before walking a scene for GLB material externalization.
func begin_externalize_pass() -> void:
	_externalize_cache.clear()
	_externalize_claimed_paths.clear()


## Writes embedded glTF materials as .tres next to gltf_path and rebinds mesh surfaces.
## Existing sidecar files are preserved (user edits survive reimport).
func externalize_embedded(node: Node, gltf_path: String, stats: Dictionary) -> void:
	if not node is MeshInstance3D or not is_instance_valid(node.mesh):
		return
	if gltf_path.is_empty() or not NexusUtils.is_gltf_container_path(gltf_path):
		return

	var mesh_was_duplicated := false
	var externalized_count := 0

	for i in range(node.mesh.get_surface_count()):
		var current_material: Material = node.mesh.surface_get_material(i)
		if not is_instance_valid(current_material):
			continue

		var external_material := _resolve_externalized_material(current_material, gltf_path, i)
		if not is_instance_valid(external_material):
			continue
		if external_material == current_material and not str(current_material.resource_path).is_empty():
			continue

		if not mesh_was_duplicated:
			node.mesh = node.mesh.duplicate()
			mesh_was_duplicated = true
		node.mesh.surface_set_material(i, external_material)
		externalized_count += 1

	stats.materials += externalized_count


func _resolve_externalized_material(
	source: Material,
	gltf_path: String,
	surface_index: int
) -> Material:
	var cache_key := source.get_instance_id()
	if _externalize_cache.has(cache_key):
		return _externalize_cache[cache_key]

	var existing_path := str(source.resource_path)
	if not existing_path.is_empty() and ResourceLoader.exists(existing_path):
		_externalize_cache[cache_key] = source
		return source

	var mat_name := str(source.resource_name).strip_edges()
	if mat_name.is_empty():
		mat_name = "surface_%d" % surface_index

	var tres_path := _allocate_gltf_material_path(gltf_path, mat_name)
	if ResourceLoader.exists(tres_path) or FileAccess.file_exists(tres_path):
		var loaded := ResourceLoader.load(tres_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if loaded is Material and is_instance_valid(loaded):
			_externalize_cache[cache_key] = loaded
			_externalize_claimed_paths[tres_path] = true
			return loaded
		push_warning("Nexus Material: Could not load existing sidecar '%s'." % tres_path)

	var to_save: Material = source.duplicate(true)
	if not is_instance_valid(to_save):
		return null
	if str(to_save.resource_name).is_empty():
		to_save.resource_name = mat_name

	var save_err := ResourceSaver.save(to_save, tres_path)
	if save_err != OK:
		push_warning("Nexus Material: Could not save '%s' (%s)." % [tres_path, error_string(save_err)])
		return null

	var saved := ResourceLoader.load(tres_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	if not (saved is Material) or not is_instance_valid(saved):
		push_warning("Nexus Material: Saved '%s' but reload failed." % tres_path)
		return null

	_externalize_cache[cache_key] = saved
	_externalize_claimed_paths[tres_path] = true

	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs:
			fs.update_file(tres_path)

	return saved


## Prefer stem_Name.tres; if that path is already claimed by another material this pass,
## append _2, _3, ... Existing on-disk files are the preserve target for that name.
func _allocate_gltf_material_path(gltf_path: String, material_name: String) -> String:
	var base := NexusPaths.gltf_material_tres_path(gltf_path, material_name)
	if not _externalize_claimed_paths.has(base):
		return base

	var stem := base.get_basename()
	var ext := base.get_extension()
	var n := 2
	var candidate := base
	while n <= 9999:
		candidate = "%s_%d.%s" % [stem, n, ext]
		if not _externalize_claimed_paths.has(candidate) and not (
			ResourceLoader.exists(candidate) or FileAccess.file_exists(candidate)
		):
			return candidate
		n += 1
	return candidate


## Warns once per material when shader_convert version in metadata does not match the importer.
func _check_shader_convert_version(material: Material, mat_id: String) -> void:
	if material is not ShaderMaterial:
		return
	if _warned_versions.has(mat_id):
		return
	var version := 1
	if material.has_meta("nexus_shader_convert_version"):
		version = int(material.get_meta("nexus_shader_convert_version"))
	if version != EXPECTED_SHADER_CONVERT_VERSION:
		_warned_versions[mat_id] = true
		push_warning("[Nexus] Material '%s' was generated by shader_convert v%d (importer expects v%d). Re-export from Blender to refresh." % [mat_id, version, EXPECTED_SHADER_CONVERT_VERSION])


## Godot 4.4+ can import vertex colors but fail to bind them to spatial shader COLOR.
## Rebuild surfaces with explicit PackedColorArray when a converted shader reads them.
func _ensure_mesh_vertex_colors(node: MeshInstance3D) -> void:
	if not is_instance_valid(node.mesh) or node.mesh.get_surface_count() == 0:
		return

	var source_mesh: Mesh = node.mesh
	var new_mesh := ArrayMesh.new()
	var rebuilt := false

	for surface_idx in range(source_mesh.get_surface_count()):
		var arrays = source_mesh.surface_get_arrays(surface_idx)
		var colors = arrays[Mesh.ARRAY_COLOR]
		if colors != null and colors.size() > 0:
			var color_array := PackedColorArray()
			for color in colors:
				if color is Color:
					color_array.push_back(color)
				else:
					var alpha := 1.0
					if color.size() > 3:
						alpha = color[3]
					color_array.push_back(Color(color[0], color[1], color[2], alpha))
			arrays[Mesh.ARRAY_COLOR] = color_array
			rebuilt = true

		arrays = NexusMeshSanitize.sanitize_surface_arrays(
			arrays,
			source_mesh.surface_get_primitive_type(surface_idx),
		)
		new_mesh.add_surface_from_arrays(
			source_mesh.surface_get_primitive_type(surface_idx),
			arrays,
		)
		new_mesh.surface_set_material(surface_idx, source_mesh.surface_get_material(surface_idx))

	if rebuilt:
		node.mesh = new_mesh
		print_verbose(" -> Rebuilt mesh vertex colors for shader COLOR on '%s'." % node.name)
