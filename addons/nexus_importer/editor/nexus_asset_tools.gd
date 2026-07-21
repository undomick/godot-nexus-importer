class_name NexusAssetTools
extends RefCounted

## Asset index loading, bulk reimport, and index sanitization.

var _reimport_manager: NexusReimportManager

func _init(reimport_manager: NexusReimportManager) -> void:
	_reimport_manager = reimport_manager

func load_asset_index() -> Dictionary:
	return NexusUtils.load_index_json(NexusPaths.asset_index_path(), "asset_index.json")

func load_material_index() -> Dictionary:
	return NexusUtils.load_index_json(NexusPaths.material_index_path(), "material_index.json")

func reimport_from_index() -> void:
	var asset_index = load_asset_index()
	if asset_index.is_empty():
		return
	var gltf_paths: Array[String] = []
	var material_paths: Array[String] = []
	var skipped := 0

	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
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

	var discovered := NexusSceneUtils.discover_unindexed_composition_gltfs(asset_index)
	for path in discovered:
		if path not in gltf_paths:
			gltf_paths.append(path)
	if not discovered.is_empty():
		print_rich(
			"[color=yellow]Nexus Reimport:[/color] Found %d composition/level glTF(s) on disk missing from asset_index.json."
			% discovered.size()
		)

	var mat_index = NexusUtils.load_index_json(
		NexusPaths.material_index_path(),
		"material_index.json",
		false,
	)
	for mat_id in mat_index.keys():
		var mat_entry = mat_index[mat_id]
		var rel = mat_entry.get("relative_path", "")
		if rel.is_empty():
			continue
		var p = NexusUtils.validate_index_path(rel)
		if not p.is_empty() and FileAccess.file_exists(p):
			material_paths.append(p)

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

	var split := NexusSceneUtils.split_gltf_paths_for_phased_reimport(gltf_paths)
	var wave1_paths: Array = split.get("wave1", [])
	var deferred_paths: Array = split.get("deferred", [])
	_reimport_manager.queue_phased_reimport_from_gltf_paths(texture_paths, gltf_paths)

	var total = texture_paths.size() + material_paths.size() + gltf_paths.size() + skipped
	print_rich(
		"[color=cyan]Nexus Reimport:[/color] Queued %d texture(s), %d glTF/GLB (wave 1). "
		% [texture_paths.size(), wave1_paths.size()]
		+ "Deferred %d composition/level glTF(s) for wave 2. "
		% deferred_paths.size()
		+ "%d material(s) (no reimport; re-export from Blender to refresh .tres). Skipped %d."
		% [material_paths.size(), skipped]
	)
	if total == 0:
		print_rich("[color=yellow]Nexus Reimport:[/color] No assets in index.")

func _sanitize_index_entries(
	index_path: String,
	label: String,
	file_exists_check: Callable,
) -> void:
	var load_result := NexusUtils.try_load_index_json(index_path, label)
	if not load_result.ok:
		push_error("Nexus: Refusing to sanitize %s: %s" % [label, load_result.error])
		return

	var source_index: Dictionary = load_result.entries
	if source_index.is_empty():
		return

	var sanitized: Dictionary = {}
	var removed := 0
	for entry_id in source_index.keys():
		var entry = source_index[entry_id]
		var rel_path = entry.get("relative_path", "")
		if rel_path.is_empty():
			removed += 1
			continue
		var resource_path = NexusUtils.validate_index_path(rel_path)
		if resource_path.is_empty():
			removed += 1
			continue
		if file_exists_check.call(resource_path):
			sanitized[entry_id] = entry
		else:
			removed += 1

	if not NexusUtils.atomic_write_index_json(index_path, sanitized, label):
		return

	if removed > 0:
		print_rich(
			"[color=cyan]Nexus Sanitization:[/color] Removed %d orphaned entries from %s."
			% [removed, label]
		)
	else:
		print_rich("[color=green]Nexus Sanitization:[/color] No orphaned entries found in %s." % label)

func sanitize_orphaned_assets() -> void:
	_sanitize_index_entries(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		func(resource_path: String) -> bool: return FileAccess.file_exists(resource_path),
	)

func sanitize_orphaned_materials() -> void:
	_sanitize_index_entries(
		NexusPaths.material_index_path(),
		"material_index.json",
		func(resource_path: String) -> bool: return FileAccess.file_exists(resource_path),
	)
