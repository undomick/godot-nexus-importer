@tool
extends EditorContextMenuPlugin

## Adds "Create Nexus Wrapper Scene" and "Create Nexus Inherited Scene" to the FileSystem
## dock context menu when glTF files are selected. When folders are selected, adds options
## to create wrapper/inherited scenes for all Nexus glTFs within (recursively).

var _nexus_plugin: EditorPlugin

func set_nexus_plugin(plugin: EditorPlugin) -> void:
	_nexus_plugin = plugin

func _popup_menu(paths: PackedStringArray) -> void:
	if paths.is_empty():
		return
	var has_gltf = false
	var has_folder = false
	for p in paths:
		if NexusUtils.is_gltf_container_path(p):
			has_gltf = true
		elif DirAccess.dir_exists_absolute(p):
			has_folder = true
		if has_gltf and has_folder:
			break
	if has_gltf:
		add_context_menu_item("Create Nexus Wrapper Scene", _on_create_wrapper)
		add_context_menu_item("Create Nexus Inherited Scene", _on_create_inherited)
	if has_folder:
		add_context_menu_item("Create Nexus Wrapper Scenes (Recursive)", _on_create_wrapper_folder)
		add_context_menu_item("Create Nexus Inherited Scenes (Recursive)", _on_create_inherited_folder)
	if not has_gltf and not has_folder:
		return

func _on_create_wrapper(paths: Array) -> void:
	_queue_for_scene_type(paths, "wrapper")

func _on_create_inherited(paths: Array) -> void:
	_queue_for_scene_type(paths, "inherited")

func _on_create_wrapper_folder(paths: Array) -> void:
	_queue_for_folder_scene_type(paths, "wrapper")

func _on_create_inherited_folder(paths: Array) -> void:
	_queue_for_folder_scene_type(paths, "inherited")

func _queue_for_scene_type(paths: Array, scene_type: String) -> void:
	if not _nexus_plugin or not _nexus_plugin.has_method("queue_scene_creation"):
		push_warning("Nexus Importer: Context menu plugin could not reach Nexus Importer.")
		return
	for p in paths:
		if p is String and NexusUtils.is_gltf_container_path(p):
			_nexus_plugin.queue_scene_creation(p, scene_type)

func _queue_for_folder_scene_type(paths: Array, scene_type: String) -> void:
	if not _nexus_plugin or not _nexus_plugin.has_method("queue_scene_creation_for_folder"):
		push_warning("Nexus Importer: Context menu plugin could not reach Nexus Importer.")
		return
	for p in paths:
		if p is String and DirAccess.dir_exists_absolute(p):
			_nexus_plugin.queue_scene_creation_for_folder(p, scene_type)
