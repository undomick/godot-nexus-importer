class_name NexusExportOrder
extends RefCounted

## Export-type priority for Godot reimport and wrapper creation (mirrors Blender export order).

const PRIORITY_ASSET := 0
const PRIORITY_ANIMATION_LIB := 1
const PRIORITY_MULTIMESH := 2
const PRIORITY_COMBINED := 3
const PRIORITY_LEVEL := 4
const PRIORITY_OTHER := 99

const GLTF_PRIORITY_SEQUENCE: Array[int] = [
	PRIORITY_ASSET,
	PRIORITY_ANIMATION_LIB,
	PRIORITY_MULTIMESH,
	PRIORITY_COMBINED,
	PRIORITY_LEVEL,
	PRIORITY_OTHER,
]


static func export_type_priority_for_gltf(gltf_path: String) -> int:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return PRIORITY_OTHER
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return PRIORITY_OTHER
	var export_type: String = str(meta.get("export_type", ""))
	match export_type:
		"ASSET", "SKELETAL_ASSET":
			return PRIORITY_ASSET
		"ANIMATION_LIB":
			return PRIORITY_ANIMATION_LIB
		"MULTIMESH", "MULTIMESH_MANIFEST":
			return PRIORITY_MULTIMESH
		"COMBINED_ASSET":
			return PRIORITY_COMBINED
		"LEVEL":
			return PRIORITY_LEVEL
	if str(meta.get("root_type", "")) == "NAVMESH":
		return PRIORITY_MULTIMESH
	return PRIORITY_OTHER


static func sort_gltf_paths(paths: Array) -> Array[String]:
	var sorted: Array[String] = []
	for path in paths:
		if path is String and not path.is_empty():
			sorted.append(path)
	sorted.sort_custom(func(a: String, b: String) -> bool:
		var pri_a := export_type_priority_for_gltf(a)
		var pri_b := export_type_priority_for_gltf(b)
		if pri_a != pri_b:
			return pri_a < pri_b
		return a < b
	)
	return sorted


static func paths_at_priority(paths: Array, priority: int) -> Array[String]:
	var result: Array[String] = []
	for path in paths:
		if path is String and export_type_priority_for_gltf(path) == priority:
			result.append(path)
	return result


static func next_priority_with_paths(paths: Array, start_priority: int) -> int:
	for priority in GLTF_PRIORITY_SEQUENCE:
		if priority < start_priority:
			continue
		if not paths_at_priority(paths, priority).is_empty():
			return priority
	return -1
