class_name NexusImportConfigFixer
extends RefCounted

## Import-config drift fixups, sidecar salvage, and startup priming.


var _purged_binary_import_warned: Dictionary = {}
var _on_queue_reimport: Callable = Callable()


func set_reimport_queue_callback(cb: Callable) -> void:
	_on_queue_reimport = cb


func fix_import_config_if_needed(gltf_path: String, do_write: bool = true) -> bool:
	if not FileAccess.file_exists(gltf_path):
		return false

	var meta = NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return false

	var import_config_path = gltf_path + ".import"
	var import_config = ConfigFile.new()
	var config_corrupt := false
	if FileAccess.file_exists(import_config_path):
		var loaded := NexusUtils.load_text_config(import_config_path)
		import_config = loaded.config
		if not loaded.ok:
			config_corrupt = true
			if loaded.corrupt:
				NexusUtils.remove_corrupt_import_sidecar(import_config_path)
			push_warning(
				"Nexus: Could not load import config for %s."
				% gltf_path.get_file()
			)
			import_config = ConfigFile.new()
			_salvage_sidecar_fields(import_config, import_config_path)

	if not config_corrupt and not NexusSceneUtils.import_config_has_drift(gltf_path, import_config, meta):
		return false

	NexusSceneUtils.apply_desired_import_config_params(gltf_path, import_config, meta)

	if config_corrupt:
		import_config.set_value("remap", "importer", "scene")
		import_config.set_value("remap", "importer_version", 1)
		import_config.set_value("remap", "type", "PackedScene")

	if do_write:
		var err = import_config.save(import_config_path)
		if err != OK:
			push_error(
				"Nexus: Failed to save import config for %s: %s"
				% [gltf_path.get_file(), error_string(err)]
			)
			return false
	return true

func prime_nexus_import_configs() -> int:
	_purge_binary_import_sidecars()
	var updated := 0
	var reimport_paths: Array[String] = []
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	var gltf_to_index_entry := index_entries_by_gltf_path(asset_index)

	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path := str(entry.get("relative_path", ""))
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		if _prime_import_config_for_path(gltf_path, reimport_paths):
			updated += 1

	for gltf_path in _discover_nexus_gltf_paths():
		if gltf_to_index_entry.has(gltf_path):
			continue
		if _prime_import_config_for_path(gltf_path, reimport_paths):
			updated += 1

	# Config rewrite requires reimport; fs.update_file alone is not enough.
	if not reimport_paths.is_empty():
		if _on_queue_reimport.is_valid():
			_on_queue_reimport.call(reimport_paths)
	return updated

func _prime_import_config_for_path(
	gltf_path: String, reimport_paths: Array[String]
) -> bool:
	if not fix_import_config_if_needed(gltf_path, true):
		return false
	# Sidecar rewrite makes the cached scene stale; always queue reimport.
	if gltf_path not in reimport_paths:
		reimport_paths.append(gltf_path)
	return true

static func index_entries_by_gltf_path(asset_index: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path := str(entry.get("relative_path", ""))
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty():
			continue
		result[gltf_path] = entry
	return result

func _discover_nexus_gltf_paths() -> Array[String]:
	var paths: Array[String] = []
	var props_root := _props_root_dir()
	if props_root.is_empty():
		return paths
	_collect_nexus_gltf_paths(props_root, paths)
	return paths

func _props_root_dir() -> String:
	for candidate in ["res://props", "res://assets"]:
		if DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ""

func _collect_nexus_gltf_paths(dir_path: String, out: Array[String]) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = dir_path.path_join(name)
		if dir.current_is_dir():
			_collect_nexus_gltf_paths(full, out)
		elif name.get_extension().to_lower() in ["gltf", "glb"]:
			if not NexusUtils.get_nexus_metadata(full).is_empty():
				out.append(full)
		name = dir.get_next()
	dir.list_dir_end()

func _purge_binary_import_sidecars() -> void:
	for root in ["res://props", "res://assets", "res://textures"]:
		if DirAccess.dir_exists_absolute(root):
			_purge_binary_import_sidecars_in_dir(root)

func _purge_binary_import_sidecars_in_dir(dir_path: String) -> void:
	var dir = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full = dir_path.path_join(name)
		if dir.current_is_dir():
			_purge_binary_import_sidecars_in_dir(full)
		elif name.ends_with(".import"):
			if NexusUtils.remove_corrupt_import_sidecar(full):
				if not _purged_binary_import_warned.has(full):
					_purged_binary_import_warned[full] = true
					push_warning(
						"Nexus: Removed corrupt binary import sidecar '%s'."
						% full.get_file()
					)
		name = dir.get_next()
	dir.list_dir_end()

func _salvage_sidecar_fields(config: ConfigFile, import_path: String) -> void:
	var text := NexusUtils.read_utf8_text(import_path)
	if text.is_empty():
		return
	var section := ""
	for line_raw in text.split("\n", false):
		var line = line_raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2)
			continue
		var eq = line.find("=")
		if eq < 0 or section.is_empty():
			continue
		var key = line.substr(0, eq).strip_edges()
		var value = _unquote_sidecar_value(line.substr(eq + 1).strip_edges())
		if key.is_empty():
			continue
		config.set_value(section, key, value)

func _unquote_sidecar_value(value: String) -> Variant:
	if value.begins_with("[") and value.ends_with("]"):
		var inner = value.substr(1, value.length() - 2)
		var parts: Array[String] = []
		var current := ""
		var in_quotes := false
		for i in range(inner.length()):
			var ch = inner[i]
			if ch == '"':
				in_quotes = not in_quotes
				continue
			if ch == "," and not in_quotes:
				parts.append(current.strip_edges())
				current = ""
				continue
			current += ch
		if not current.is_empty():
			parts.append(current.strip_edges())
		var arr: PackedStringArray = []
		for part in parts:
			arr.append(str(_unquote_sidecar_value(part)))
		return arr
	if value.length() >= 2 and value.begins_with('"') and value.ends_with('"'):
		return value.substr(1, value.length() - 2).replace('\\"', '"')
	if value == "true":
		return true
	if value == "false":
		return false
	if value == "null":
		return null
	return value
