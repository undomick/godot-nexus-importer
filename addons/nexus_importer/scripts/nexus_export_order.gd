class_name NexusExportOrder
extends RefCounted

## Export-type priority for Godot reimport and wrapper creation (mirrors Blender export order).
## ASSET/SKELETAL -> COMBINED -> ANIMATION_LIB -> MULTIMESH -> LEVEL

const PRIORITY_ASSET := 0
const PRIORITY_COMBINED := 1
const PRIORITY_ANIMATION_LIB := 2
const PRIORITY_MULTIMESH := 3
const PRIORITY_LEVEL := 4
const PRIORITY_OTHER := 99

const TYPE_ASSET := "ASSET"
const TYPE_SKELETAL_ASSET := "SKELETAL_ASSET"
const TYPE_COMBINED_ASSET := "COMBINED_ASSET"
const TYPE_ANIMATION_LIB := "ANIMATION_LIB"
const TYPE_MULTIMESH := "MULTIMESH"
const TYPE_MULTIMESH_MANIFEST := "MULTIMESH_MANIFEST"
const TYPE_LEVEL := "LEVEL"

## COMBINED_ASSET / LEVEL - compositions that instance other assets.
const COMPOSITION_EXPORT_TYPES: Array[String] = [TYPE_COMBINED_ASSET, TYPE_LEVEL]

## Export types that run mesh sanitize + LOD visibility processing on import.
const LOD_PROCESS_EXPORT_TYPES: Array[String] = [
	TYPE_ASSET,
	TYPE_SKELETAL_ASSET,
	TYPE_COMBINED_ASSET,
	TYPE_LEVEL,
]

## Types re-queued after base assets change (dependents of ASSET/SKELETAL).
const DEPENDENT_EXPORT_TYPES: Array[String] = [
	TYPE_COMBINED_ASSET,
	TYPE_ANIMATION_LIB,
	TYPE_MULTIMESH_MANIFEST,
	TYPE_LEVEL,
]

## Indexed dependents scanned when a changed glTF may invalidate compositions.
const INDEX_DEPENDENT_EXPORT_TYPES: Array[String] = [
	TYPE_COMBINED_ASSET,
	TYPE_LEVEL,
	TYPE_MULTIMESH_MANIFEST,
]

const GLTF_PRIORITY_SEQUENCE: Array[int] = [
	PRIORITY_ASSET,
	PRIORITY_COMBINED,
	PRIORITY_ANIMATION_LIB,
	PRIORITY_MULTIMESH,
	PRIORITY_LEVEL,
	PRIORITY_OTHER,
]


static func export_type_priority(export_type: String) -> int:
	match export_type:
		TYPE_ASSET, TYPE_SKELETAL_ASSET:
			return PRIORITY_ASSET
		TYPE_COMBINED_ASSET:
			return PRIORITY_COMBINED
		TYPE_ANIMATION_LIB:
			return PRIORITY_ANIMATION_LIB
		TYPE_MULTIMESH, TYPE_MULTIMESH_MANIFEST:
			return PRIORITY_MULTIMESH
		TYPE_LEVEL:
			return PRIORITY_LEVEL
	return PRIORITY_OTHER


static func export_type_priority_for_gltf(gltf_path: String) -> int:
	if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
		return PRIORITY_OTHER
	var meta := NexusUtils.get_nexus_metadata(gltf_path)
	if meta.is_empty():
		return PRIORITY_OTHER
	var export_type: String = str(meta.get("export_type", ""))
	var priority := export_type_priority(export_type)
	if priority != PRIORITY_OTHER:
		return priority
	if str(meta.get("root_type", "")) == "NAVMESH":
		return PRIORITY_MULTIMESH
	return PRIORITY_OTHER


static func is_composition_export_type(export_type: String) -> bool:
	return export_type in COMPOSITION_EXPORT_TYPES


static func is_lod_process_export_type(export_type: String) -> bool:
	return export_type in LOD_PROCESS_EXPORT_TYPES


static func is_dependent_export_type(export_type: String) -> bool:
	return export_type in DEPENDENT_EXPORT_TYPES


static func is_index_dependent_export_type(export_type: String) -> bool:
	return export_type in INDEX_DEPENDENT_EXPORT_TYPES


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
