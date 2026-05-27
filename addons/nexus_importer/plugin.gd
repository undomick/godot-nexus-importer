@tool
extends EditorPlugin

## Nexus Importer: Custom glTF importer for the Nexus Blender Export Pipeline.

const NexusReimportManagerScript = preload("res://addons/nexus_importer/editor/nexus_reimport_manager.gd")
const NexusWrapperBuilderScript = preload("res://addons/nexus_importer/editor/nexus_wrapper_builder.gd")
const NexusAssetToolsScript = preload("res://addons/nexus_importer/editor/nexus_asset_tools.gd")
const NexusBatchLockScript = preload("res://addons/nexus_importer/scripts/nexus_batch_lock.gd")

const MENU_ID_IMPORT_MODE = 0
const MENU_ID_SCENE_STYLE = 1
const MENU_ID_REIMPORT_ASSETS = 2
const MENU_ID_ASSET_SANITIZATION = 3

var scene_post_processor = preload("res://addons/nexus_importer/scene_post_processor.gd").new()
var _tool_submenu: PopupMenu
var _fs_context_plugin: RefCounted
var _reimport_manager: NexusReimportManager
var _wrapper_builder: NexusWrapperBuilder
var _asset_tools: NexusAssetTools
var _scan_needed: bool = false
var _batch_lock_was_active: bool = false


func _enter_tree():
	add_scene_post_import_plugin(scene_post_processor)
	var fs = get_editor_interface().get_resource_filesystem()
	if not fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.connect(_on_resources_reimported)
	if not fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.connect(_on_resources_reimporting)

	_reimport_manager = NexusReimportManagerScript.new(self)
	_wrapper_builder = NexusWrapperBuilderScript.new(self)
	_asset_tools = NexusAssetToolsScript.new(_reimport_manager)
	set_process(true)

	_register_project_settings()

	_tool_submenu = PopupMenu.new()
	_tool_submenu.id_pressed.connect(_on_tool_submenu_id_pressed)
	add_tool_submenu_item("Nexus Importer", _tool_submenu)
	_update_tool_menu_items()
	_fs_context_plugin = preload("res://addons/nexus_importer/fs_context_menu.gd").new()
	if _fs_context_plugin.has_method("set_nexus_plugin"):
		_fs_context_plugin.set_nexus_plugin(self)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_context_plugin)
	print_rich("[color=green]Nexus Importer: Ready.[/color]")


func _exit_tree():
	set_process(false)
	if _fs_context_plugin:
		remove_context_menu_plugin(_fs_context_plugin)
		_fs_context_plugin = null
	remove_scene_post_import_plugin(scene_post_processor)
	remove_tool_menu_item("Nexus Importer")
	_tool_submenu = null

	var fs = get_editor_interface().get_resource_filesystem()
	if fs.resources_reimported.is_connected(_on_resources_reimported):
		fs.resources_reimported.disconnect(_on_resources_reimported)
	if fs.resources_reimporting.is_connected(_on_resources_reimporting):
		fs.resources_reimporting.disconnect(_on_resources_reimporting)

	_reimport_manager = null
	_wrapper_builder = null
	_asset_tools = null


func _process(_delta):
	if _reimport_manager == null or _wrapper_builder == null:
		return

	var batch_locked := NexusBatchLockScript.is_active()
	if batch_locked:
		_batch_lock_was_active = true
		return

	if _batch_lock_was_active:
		_batch_lock_was_active = false
		_flush_batch_deferred_imports()

	if _reimport_manager.cooldown_remaining > 0:
		_reimport_manager.cooldown_remaining -= 1
		return

	var fs = get_editor_interface().get_resource_filesystem()
	if fs.is_scanning():
		_reimport_manager.cooldown_remaining = 10
		return

	if _reimport_manager.tick_phased_reimport():
		return

	if _wrapper_builder.tick_scene_creation(_reimport_manager):
		if _wrapper_builder.scan_when_idle:
			_wrapper_builder.scan_when_idle = false
			_scan_needed = true
			var dependent_count := _reimport_manager.queue_dependent_gltfs_from_index()
			if dependent_count > 0:
				print_rich(
					"[color=cyan]Nexus:[/color] Queued %d dependent glTF(s) for reimport after wrapper creation."
					% dependent_count
				)
		return

	if _scan_needed:
		_scan_needed = false
		fs.scan()


func _on_resources_reimporting(_resources: PackedStringArray):
	if _reimport_manager == null:
		return
	_reimport_manager.on_resources_reimporting(_resources)


func _on_resources_reimported(resources: PackedStringArray):
	if _reimport_manager == null or _wrapper_builder == null:
		return
	if _reimport_manager.on_resources_reimported(
		resources,
		_wrapper_builder,
		func(wants_scan: bool): _scan_needed = wants_scan
	):
		_show_nexus_notification("Nexus: Import complete", EditorToaster.SEVERITY_INFO)


func _nexus_apply_deferred_config_writes():
	if _reimport_manager == null:
		return
	_reimport_manager.apply_deferred_config_writes()


func _nexus_flush_pending_reimport_queue(just_reimported: Array):
	if _reimport_manager == null:
		return
	_reimport_manager.flush_pending_reimport_queue(just_reimported)


func _nexus_restore_selection(nodes: Array[Node]):
	var selection = get_editor_interface().get_selection()
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			selection.add_node(node)


func _flush_batch_deferred_imports() -> void:
	if _reimport_manager == null:
		return
	if not NexusBatchLockScript.has_deferred_paths():
		return
	var phased: Dictionary = NexusBatchLockScript.take_deferred_phased()
	var textures: Array = phased.get("textures", [])
	var gltfs: Array = phased.get("gltfs", [])
	if textures.is_empty() and gltfs.is_empty():
		return
	print_rich(
		"[color=cyan]Nexus:[/color] Batch export finished; reimporting %d deferred resource(s)."
		% (textures.size() + gltfs.size())
	)
	_reimport_manager.queue_phased_paths(textures, gltfs)
	_scan_needed = true


func _show_nexus_notification(message: String, severity: int = 0) -> void:
	if not get_editor_interface().has_method("get_editor_toaster"):
		return
	var toaster = get_editor_interface().get_editor_toaster()
	if toaster and toaster.has_method("push_toast"):
		toaster.push_toast(message, severity)


func queue_scene_creation(gltf_path: String, scene_type: String) -> void:
	if gltf_path.is_empty() or scene_type.is_empty():
		return
	if scene_type != NexusPaths.SCENE_STYLE_WRAPPER and scene_type != NexusPaths.SCENE_STYLE_INHERITED:
		return
	if not FileAccess.file_exists(gltf_path):
		push_warning("Nexus: glTF/GLB not found: %s" % gltf_path)
		return
	_wrapper_builder.queue_scene(gltf_path, scene_type)


func queue_scene_creation_for_folder(folder_path: String, scene_type: String) -> int:
	return _wrapper_builder.queue_scenes_in_folder(folder_path, scene_type)


func _register_project_settings() -> void:
	var needs_save := false
	if not ProjectSettings.has_setting(NexusPaths.SETTING_AUTO_IMPORT):
		ProjectSettings.set_setting(NexusPaths.SETTING_AUTO_IMPORT, true)
		ProjectSettings.set_initial_value(NexusPaths.SETTING_AUTO_IMPORT, true)
		needs_save = true
	if not ProjectSettings.has_setting(NexusPaths.SETTING_ASSET_INDEX):
		ProjectSettings.set_setting(NexusPaths.SETTING_ASSET_INDEX, "res://asset_index.json")
		ProjectSettings.set_initial_value(NexusPaths.SETTING_ASSET_INDEX, "res://asset_index.json")
		needs_save = true
	if not ProjectSettings.has_setting(NexusPaths.SETTING_MATERIAL_INDEX):
		ProjectSettings.set_setting(NexusPaths.SETTING_MATERIAL_INDEX, "res://material_index.json")
		ProjectSettings.set_initial_value(NexusPaths.SETTING_MATERIAL_INDEX, "res://material_index.json")
		needs_save = true
	if not ProjectSettings.has_setting(NexusPaths.SETTING_SCENE_STYLE):
		ProjectSettings.set_setting(NexusPaths.SETTING_SCENE_STYLE, NexusPaths.SCENE_STYLE_WRAPPER)
		ProjectSettings.set_initial_value(NexusPaths.SETTING_SCENE_STYLE, NexusPaths.SCENE_STYLE_WRAPPER)
		needs_save = true
	if needs_save:
		ProjectSettings.save()


func _on_tool_submenu_id_pressed(id: int) -> void:
	match id:
		MENU_ID_IMPORT_MODE:
			_toggle_import_mode()
		MENU_ID_SCENE_STYLE:
			_toggle_scene_style()
		MENU_ID_REIMPORT_ASSETS:
			_asset_tools.reimport_from_index()
		MENU_ID_ASSET_SANITIZATION:
			_asset_tools.sanitize_orphaned_assets()


func _toggle_import_mode():
	var current = NexusPaths.auto_import_enabled()
	ProjectSettings.set_setting(NexusPaths.SETTING_AUTO_IMPORT, not current)
	ProjectSettings.save()
	_update_tool_menu_items()


func _toggle_scene_style():
	var current = NexusPaths.scene_style()
	var next_val = (
		NexusPaths.SCENE_STYLE_INHERITED
		if current == NexusPaths.SCENE_STYLE_WRAPPER
		else NexusPaths.SCENE_STYLE_WRAPPER
	)
	ProjectSettings.set_setting(NexusPaths.SETTING_SCENE_STYLE, next_val)
	ProjectSettings.save()
	_update_tool_menu_items()


func _update_tool_menu_items() -> void:
	if not _tool_submenu:
		return
	_tool_submenu.clear()
	var is_auto = NexusPaths.auto_import_enabled()
	var scene_style = NexusPaths.scene_style()
	_tool_submenu.add_item("Import Mode (Auto)" if is_auto else "Import Mode (Manual)", MENU_ID_IMPORT_MODE)
	_tool_submenu.set_item_tooltip(
		-1,
		"Toggle automatic post-processing. When Auto: config updates and scene creation run on import. When Manual: run tools explicitly."
	)
	_tool_submenu.add_item("Scene Style (%s)" % scene_style.capitalize(), MENU_ID_SCENE_STYLE)
	_tool_submenu.set_item_tooltip(
		-1,
		"Toggle scene creation style. Wrapper = Node3D container with GLTF instance. Inherited = Scene inherits directly from the GLTF."
	)
	_tool_submenu.add_separator()
	_tool_submenu.add_item("Reimport Assets", MENU_ID_REIMPORT_ASSETS)
	_tool_submenu.set_item_tooltip(
		-1,
		"Read asset_index.json and reimport all glTF/GLB files that exist at their expected paths. Skips missing assets with a warning."
	)
	_tool_submenu.add_item("Asset Sanitization", MENU_ID_ASSET_SANITIZATION)
	_tool_submenu.set_item_tooltip(
		-1,
		"Remove asset_index.json entries whose glTF/GLB files no longer exist. Cleans orphaned index entries."
	)
