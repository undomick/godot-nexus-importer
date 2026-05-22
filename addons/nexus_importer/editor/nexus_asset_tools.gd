class_name NexusAssetTools
extends RefCounted

## Asset index loading, bulk reimport, and index sanitization.

var _reimport_manager: NexusReimportManager


func _init(reimport_manager: NexusReimportManager) -> void:
	_reimport_manager = reimport_manager


func load_asset_index() -> Dictionary:
	var asset_index_path = NexusPaths.asset_index_path()
	if not FileAccess.file_exists(asset_index_path):
		push_error("Nexus: Asset index not found at '%s'." % asset_index_path)
		return {}
	var file = FileAccess.open(asset_index_path, FileAccess.READ)
	if not file:
		push_error("Nexus: Could not open asset index.")
		return {}
	var json = JSON.new()
	if json.parse(file.get_as_text()) != OK:
		file.close()
		push_error("Nexus: Asset index is not valid JSON.")
		return {}
	file.close()
	var data = json.get_data()
	if not data is Dictionary:
		push_error("Nexus: Asset index root must be an object.")
		return {}
	return data


func reimport_from_index() -> void:
	var asset_index = load_asset_index()
	if asset_index.is_empty():
		return
	var gltf_paths: Array[String] = []
	var material_paths: Array[String] = []
	var skipped := 0

	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			push_warning("Nexus: Asset '%s' has invalid entry - skipped." % asset_id)
			skipped += 1
			continue
		var rel_path = entry.get("relative_path", "")
		if rel_path.is_empty():
			push_warning("Nexus: Asset '%s' has no relative_path - skipped." % asset_id)
			skipped += 1
			continue
		var gltf_path = NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			push_warning("Nexus: Asset '%s' has invalid path - skipped." % asset_id)
			skipped += 1
			continue
		if not FileAccess.file_exists(gltf_path):
			push_warning("Nexus: Asset '%s' not found at '%s' - skipped." % [asset_id, gltf_path])
			skipped += 1
			continue
		gltf_paths.append(gltf_path)

	var material_index_path = NexusPaths.material_index_path()
	if FileAccess.file_exists(material_index_path):
		var file = FileAccess.open(material_index_path, FileAccess.READ)
		if file:
			var json = JSON.new()
			if json.parse(file.get_as_text()) == OK:
				var mat_data = json.get_data()
				if mat_data is Dictionary:
					for mat_id in mat_data.keys():
						var mat_entry = mat_data[mat_id]
						if mat_entry is Dictionary:
							var rel = mat_entry.get("relative_path", "")
							if not rel.is_empty():
								var p = NexusUtils.validate_index_path(rel)
								if not p.is_empty() and FileAccess.file_exists(p):
									material_paths.append(p)
			file.close()

	var dirs_to_scan: Dictionary = {}
	for p in gltf_paths:
		dirs_to_scan[p.get_base_dir()] = true
	for p in material_paths:
		dirs_to_scan[p.get_base_dir()] = true
	var texture_paths: Array[String] = []
	for dir_path in dirs_to_scan.keys():
		texture_paths.append_array(
			NexusSceneUtils.collect_files_with_extensions(dir_path, ["png", "jpg", "jpeg", "webp"])
		)

	_reimport_manager.queue_phased_paths(texture_paths, gltf_paths)

	var total = texture_paths.size() + material_paths.size() + gltf_paths.size() + skipped
	print_rich(
		"[color=cyan]Nexus Reimport:[/color] Queued %d texture(s), %d glTF/GLB. "
		% [texture_paths.size(), gltf_paths.size()]
		+ "%d material(s) (no reimport). Skipped %d." % [material_paths.size(), skipped]
	)
	if total == 0:
		print_rich("[color=yellow]Nexus Reimport:[/color] No assets in index.")


func sanitize_orphaned_assets() -> void:
	var asset_index = load_asset_index()
	if asset_index.is_empty():
		return
	var sanitized: Dictionary = {}
	var removed := 0
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			removed += 1
			continue
		var rel_path = entry.get("relative_path", "")
		if rel_path.is_empty():
			removed += 1
			continue
		var gltf_path = NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			removed += 1
			continue
		if FileAccess.file_exists(gltf_path):
			sanitized[asset_id] = entry
		else:
			removed += 1
	var asset_index_path = NexusPaths.asset_index_path()
	var file = FileAccess.open(asset_index_path, FileAccess.WRITE)
	if not file:
		push_error("Nexus: Could not write asset index.")
		return
	file.store_string(JSON.stringify(sanitized))
	file.close()
	if removed > 0:
		print_rich(
			"[color=cyan]Nexus Sanitization:[/color] Removed %d orphaned entries from asset_index."
			% removed
		)
	else:
		print_rich("[color=green]Nexus Sanitization:[/color] No orphaned entries found.")
