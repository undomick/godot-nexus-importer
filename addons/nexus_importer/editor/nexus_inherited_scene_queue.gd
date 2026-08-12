class_name NexusInheritedSceneQueue
extends RefCounted

## Queue and evaluate composition / MultiMesh inherited scene creation.


var _composition_scene_log_fingerprint: String = ""


func queue_wrapper_fixup_for_paths(
	paths: Array[String], wrapper_builder: NexusWrapperBuilder
) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0
	var queued := 0
	for path in paths:
		if path is String and NexusSceneUtils.should_create_packed_scene(path):
			if wrapper_builder.needs_scene_processing(path):
				wrapper_builder.queue_scene(path)
				queued += 1
	return queued

func queue_composition_inherited_scenes_from_index(wrapper_builder: NexusWrapperBuilder) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0

	var evaluation := _evaluate_composition_inherited_scene_candidates(wrapper_builder, true)
	_log_composition_scene_queue_summary(evaluation)
	return evaluation.ready_to_queue.size()

func queue_multimesh_inherited_scenes_from_paths(
	wrapper_builder: NexusWrapperBuilder, gltf_paths: PackedStringArray
) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0

	var evaluation := _evaluate_multimesh_inherited_scene_candidates(
		wrapper_builder, gltf_paths, true
	)
	_log_multimesh_scene_queue_summary(evaluation)
	return evaluation.ready_to_queue.size()

func queue_multimesh_inherited_scenes_from_index(wrapper_builder: NexusWrapperBuilder) -> int:
	var paths: PackedStringArray = []
	for gltf_path in _multimesh_paths_from_index():
		paths.append(gltf_path)
	return queue_multimesh_inherited_scenes_from_paths(wrapper_builder, paths)

func has_pending_inherited_scene_work(wrapper_builder: NexusWrapperBuilder) -> bool:
	if not NexusPaths.auto_import_enabled():
		return false
	var composition_eval := _evaluate_composition_inherited_scene_candidates(wrapper_builder, false)
	if (
		not composition_eval.ready_to_queue.is_empty()
		or not composition_eval.waiting_on_deps.is_empty()
	):
		return true
	var multimesh_eval := _evaluate_multimesh_inherited_scene_candidates(
		wrapper_builder, PackedStringArray(), false
	)
	return (
		not multimesh_eval.ready_to_queue.is_empty()
		or not multimesh_eval.waiting_on_import.is_empty()
	)

func _composition_paths_from_index() -> Array[String]:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return []

	var by_canonical: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		var meta := NexusUtils.get_nexus_metadata(gltf_path)
		var export_type: String = str(meta.get("export_type", ""))
		if not NexusExportOrder.is_composition_export_type(export_type):
			continue
		by_canonical[gltf_path] = true

	for path in NexusSceneUtils.discover_unindexed_composition_gltfs(asset_index):
		var canonical := NexusUtils.to_res_gltf_path(path)
		if canonical.is_empty():
			continue
		by_canonical[canonical] = true

	var composition_paths: Array[String] = []
	for key in by_canonical.keys():
		composition_paths.append(key)

	composition_paths.sort_custom(func(a: String, b: String) -> bool:
		var meta_a := NexusUtils.get_nexus_metadata(a)
		var meta_b := NexusUtils.get_nexus_metadata(b)
		var pri_a := NexusExportOrder.export_type_priority(str(meta_a.get("export_type", "")))
		var pri_b := NexusExportOrder.export_type_priority(str(meta_b.get("export_type", "")))
		if pri_a != pri_b:
			return pri_a < pri_b
		return a < b
	)
	return composition_paths

func _evaluate_composition_inherited_scene_candidates(
	wrapper_builder: NexusWrapperBuilder,
	do_queue: bool
) -> Dictionary:
	var ready_to_queue: Array[String] = []
	var waiting_on_deps: Array[String] = []
	var skipped_bloated: Array[String] = []
	var skipped_up_to_date: Array[String] = []

	for gltf_path in _composition_paths_from_index():
		if not NexusSceneUtils.should_create_packed_scene(gltf_path):
			continue
		if not NexusSceneUtils.is_thin_composition_gltf(gltf_path):
			skipped_bloated.append(gltf_path.get_file())
			continue
		if not wrapper_builder.needs_scene_processing(gltf_path):
			skipped_up_to_date.append(gltf_path.get_file())
			continue
		if not NexusSceneUtils.composition_dependencies_ready(gltf_path):
			waiting_on_deps.append(gltf_path.get_file())
			continue
		if wrapper_builder.is_scene_queued(gltf_path):
			continue
		ready_to_queue.append(gltf_path)
		if do_queue:
			wrapper_builder.queue_scene(gltf_path)

	return {
		"ready_to_queue": ready_to_queue,
		"waiting_on_deps": waiting_on_deps,
		"skipped_bloated": skipped_bloated,
		"skipped_up_to_date": skipped_up_to_date,
	}

func _log_composition_scene_queue_summary(evaluation: Dictionary) -> void:
	var queued_count: int = evaluation.get("ready_to_queue", []).size()
	var bloated: Array = evaluation.get("skipped_bloated", [])
	var waiting_deps: Array = evaluation.get("waiting_on_deps", [])
	var up_to_date: Array = evaluation.get("skipped_up_to_date", [])

	if (
		queued_count == 0
		and bloated.is_empty()
		and waiting_deps.is_empty()
		and up_to_date.is_empty()
	):
		return

	var has_actionable := queued_count > 0 or not bloated.is_empty() or not waiting_deps.is_empty()
	if not has_actionable and not up_to_date.is_empty():
		var fingerprint := ", ".join(up_to_date)
		if fingerprint == _composition_scene_log_fingerprint:
			return
		_composition_scene_log_fingerprint = fingerprint
	elif has_actionable:
		_composition_scene_log_fingerprint = ""

	var parts: PackedStringArray = []
	if queued_count > 0:
		parts.append("queued %d" % queued_count)
	if not bloated.is_empty():
		parts.append("skipped_bloated: [%s]" % ", ".join(bloated))
	if not waiting_deps.is_empty():
		parts.append("skipped_deps: [%s]" % ", ".join(waiting_deps))
	if not up_to_date.is_empty():
		parts.append("skipped_up_to_date: [%s]" % ", ".join(up_to_date))
	print_rich("[color=cyan]Nexus Reimport:[/color] Composition inherited scenes: %s." % ", ".join(parts))

func _multimesh_paths_from_index() -> Array[String]:
	var asset_index := NexusUtils.load_index_json(
		NexusPaths.asset_index_path(),
		"asset_index.json",
		false,
	)
	if asset_index.is_empty():
		return []

	var by_canonical: Dictionary = {}
	for asset_id in asset_index.keys():
		var entry = asset_index[asset_id]
		if not entry is Dictionary:
			continue
		var rel_path: String = entry.get("relative_path", "")
		if rel_path.is_empty():
			continue
		var gltf_path := NexusUtils.validate_index_path(rel_path)
		if gltf_path.is_empty() or not FileAccess.file_exists(gltf_path):
			continue
		if not NexusMultiMeshUtils.is_multimesh_manifest(gltf_path):
			continue
		by_canonical[gltf_path] = true

	var paths: Array[String] = []
	for key in by_canonical.keys():
		paths.append(key)
	return NexusSceneUtils.sort_gltf_paths_with_placeholder_defer(paths)

func _evaluate_multimesh_inherited_scene_candidates(
	wrapper_builder: NexusWrapperBuilder,
	gltf_paths: PackedStringArray,
	do_queue: bool
) -> Dictionary:
	var ready_to_queue: Array[String] = []
	var waiting_on_sources: Array[String] = []
	var waiting_on_import: Array[String] = []
	var skipped_up_to_date: Array[String] = []

	var paths_to_scan: Array[String] = []
	if gltf_paths.is_empty():
		paths_to_scan = _multimesh_paths_from_index()
	else:
		for path in gltf_paths:
			if path is String and not path.is_empty():
				paths_to_scan.append(path)

	for gltf_path in paths_to_scan:
		if not NexusSceneUtils.should_create_packed_scene(gltf_path):
			continue
		if not NexusMultiMeshUtils.is_multimesh_manifest(gltf_path):
			continue
		if not wrapper_builder.needs_scene_processing(gltf_path):
			skipped_up_to_date.append(gltf_path.get_file())
			continue
		var stage_info := NexusMultiMeshUtils.multimesh_pipeline_stage(gltf_path)
		var stage: String = str(stage_info.get("stage", ""))
		match stage:
			NexusMultiMeshUtils.MULTIMESH_STAGE_SOURCES:
				waiting_on_sources.append(gltf_path.get_file())
			NexusMultiMeshUtils.MULTIMESH_STAGE_MANIFEST:
				waiting_on_import.append(gltf_path.get_file())
			NexusMultiMeshUtils.MULTIMESH_STAGE_INHERITED:
				if wrapper_builder.is_scene_queued(gltf_path):
					continue
				ready_to_queue.append(gltf_path)
				if do_queue:
					wrapper_builder.queue_scene(gltf_path)
			NexusMultiMeshUtils.MULTIMESH_STAGE_DONE:
				skipped_up_to_date.append(gltf_path.get_file())

	return {
		"ready_to_queue": ready_to_queue,
		"waiting_on_sources": waiting_on_sources,
		"waiting_on_import": waiting_on_import,
		"skipped_up_to_date": skipped_up_to_date,
	}

func _log_multimesh_scene_queue_summary(evaluation: Dictionary) -> void:
	var queued_count: int = evaluation.get("ready_to_queue", []).size()
	var waiting_sources: Array = evaluation.get("waiting_on_sources", [])
	var waiting_import: Array = evaluation.get("waiting_on_import", [])
	var up_to_date: Array = evaluation.get("skipped_up_to_date", [])

	if (
		queued_count == 0
		and waiting_sources.is_empty()
		and waiting_import.is_empty()
		and up_to_date.is_empty()
	):
		return

	var parts: PackedStringArray = []
	if queued_count > 0:
		parts.append("queued %d" % queued_count)
	if not waiting_sources.is_empty():
		parts.append("skipped_sources: [%s]" % ", ".join(waiting_sources))
	if not waiting_import.is_empty():
		parts.append("skipped_import: [%s]" % ", ".join(waiting_import))
	if not up_to_date.is_empty():
		parts.append("skipped_up_to_date: [%s]" % ", ".join(up_to_date))
	print_rich("[color=cyan]Nexus Reimport:[/color] MultiMesh inherited scenes: %s." % ", ".join(parts))
