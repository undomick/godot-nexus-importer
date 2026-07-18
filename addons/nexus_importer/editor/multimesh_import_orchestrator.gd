class_name MultiMeshImportOrchestrator
extends RefCounted

## Single state machine for MultiMesh manifest import and inherited scene creation.

const NexusImportContext = preload("res://addons/nexus_importer/scripts/nexus_import_context.gd")
const NexusSceneUtils = preload("res://addons/nexus_importer/scripts/nexus_scene_utils.gd")

var _plugin: EditorPlugin


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin


func begin_manifest_wave() -> void:
	NexusImportContext.set_mass_import_active(false)
	NexusImportContext.set_multimesh_wave_active(true)


func end_manifest_wave() -> void:
	NexusImportContext.set_multimesh_wave_active(false)


func advance_manifest(
	gltf_path: String,
	reimport_manager: NexusReimportManager
) -> bool:
	if gltf_path.is_empty() or not NexusSceneUtils.is_multimesh_manifest(gltf_path):
		return false

	var stage_info := NexusSceneUtils.multimesh_pipeline_stage(gltf_path)
	var stage: String = str(stage_info.get("stage", ""))
	NexusSceneUtils.multimesh_pipeline_log_status(gltf_path)

	match stage:
		NexusSceneUtils.MULTIMESH_STAGE_SOURCES:
			reimport_manager.seed_deferred_multimesh_paths([gltf_path])
			_request_multimesh_wave()
			return true
		NexusSceneUtils.MULTIMESH_STAGE_MANIFEST:
			if not NexusImportContext.mark_multimesh_retry(gltf_path):
				push_error(
					"Nexus MultiMesh: Manifest reimport retries exhausted for '%s': %s"
					% [gltf_path.get_file(), str(stage_info.get("reason", ""))]
				)
				return false
			begin_manifest_wave()
			reimport_manager.queue_multimesh_manifest_reimport(gltf_path)
			return true
	return false


func advance_inherited(gltf_path: String, wrapper_builder: NexusWrapperBuilder) -> bool:
	if gltf_path.is_empty() or not NexusSceneUtils.is_multimesh_manifest(gltf_path):
		return false

	var stage_info := NexusSceneUtils.multimesh_pipeline_stage(gltf_path)
	var stage: String = str(stage_info.get("stage", ""))
	if stage != NexusSceneUtils.MULTIMESH_STAGE_INHERITED:
		return false
	if not wrapper_builder.needs_scene_processing(gltf_path):
		return false
	if wrapper_builder.is_scene_queued(gltf_path):
		return false
	return wrapper_builder.queue_scene(gltf_path)


func on_manifest_reimport_done(
	paths: PackedStringArray,
	reimport_manager: NexusReimportManager,
	wrapper_builder: NexusWrapperBuilder
) -> int:
	end_manifest_wave()
	var queued := 0
	for path in paths:
		if path.is_empty() or not NexusSceneUtils.is_multimesh_manifest(path):
			continue
		# A fresh manifest reimport is the user's retry signal — clear any prior
		# inherited-open timeout abort so the build can be attempted again.
		wrapper_builder.clear_inherited_abort(path)
		if NexusSceneUtils.multimesh_manifest_import_complete(path):
			NexusImportContext.clear_multimesh_retry(path)
		if advance_inherited(path, wrapper_builder):
			queued += 1
		elif NexusSceneUtils.multimesh_pipeline_stage(path).get("stage") == NexusSceneUtils.MULTIMESH_STAGE_MANIFEST:
			advance_manifest(path, reimport_manager)
	return queued


func advance_pending_from_index(
	wrapper_builder: NexusWrapperBuilder,
	reimport_manager: NexusReimportManager
) -> int:
	if not NexusPaths.auto_import_enabled():
		return 0
	if NexusImportContext.is_multimesh_post_import_active():
		return 0
	var queued := 0
	for gltf_path in _multimesh_paths_from_index():
		var stage_info := NexusSceneUtils.multimesh_pipeline_stage_throttled(gltf_path)
		var stage: String = str(stage_info.get("stage", ""))
		if stage == NexusSceneUtils.MULTIMESH_STAGE_INHERITED:
			if advance_inherited(gltf_path, wrapper_builder):
				queued += 1
		elif stage == NexusSceneUtils.MULTIMESH_STAGE_MANIFEST:
			advance_manifest(gltf_path, reimport_manager)
	return queued


func handle_inherited_failure(
	gltf_path: String,
	reimport_manager: NexusReimportManager,
	reason: String
) -> void:
	if gltf_path.is_empty():
		return
	NexusSceneUtils.multimesh_pipeline_log_status(gltf_path)
	var stage: String = str(NexusSceneUtils.multimesh_pipeline_stage(gltf_path).get("stage", ""))
	if stage == NexusSceneUtils.MULTIMESH_STAGE_MANIFEST:
		advance_manifest(gltf_path, reimport_manager)
	elif stage == NexusSceneUtils.MULTIMESH_STAGE_SOURCES:
		reimport_manager.seed_deferred_multimesh_paths([gltf_path])
		_request_multimesh_wave()
	else:
		push_error(
			"Nexus MultiMesh: Inherited scene failed for '%s': %s"
			% [gltf_path.get_file(), reason]
		)


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
		if NexusSceneUtils.is_multimesh_manifest(gltf_path):
			by_canonical[gltf_path] = true

	var paths: Array[String] = []
	for key in by_canonical.keys():
		paths.append(key)
	return paths


func _request_multimesh_wave() -> void:
	if _plugin and _plugin.has_method("request_multimesh_wave"):
		_plugin.request_multimesh_wave()
