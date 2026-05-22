class_name NexusPaths
extends RefCounted

## Project settings keys and path helpers for Nexus Importer.

const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"
const SETTING_SCENE_STYLE = "nexus/import/scene_style"
const SETTING_ASSET_INDEX = "nexus/import/asset_index_path"
const SETTING_MATERIAL_INDEX = "nexus/import/material_index_path"

const SCENE_STYLE_WRAPPER = "wrapper"
const SCENE_STYLE_INHERITED = "inherited"

const IMPORT_POST_PROCESSOR = "res://addons/nexus_importer/import_post_processor.gd"

static func auto_import_enabled() -> bool:
	return ProjectSettings.get_setting(SETTING_AUTO_IMPORT, true)


static func scene_style() -> String:
	return ProjectSettings.get_setting(SETTING_SCENE_STYLE, SCENE_STYLE_WRAPPER)


static func asset_index_path() -> String:
	return ProjectSettings.get_setting(SETTING_ASSET_INDEX, "res://asset_index.json")


static func material_index_path() -> String:
	return ProjectSettings.get_setting(SETTING_MATERIAL_INDEX, "res://material_index.json")


static func scene_path_for(gltf_path: String, scene_style: String) -> String:
	var basename = gltf_path.get_file().get_basename()
	return gltf_path.get_base_dir().path_join(basename + "_" + scene_style + ".tscn")


static func wrapper_path_for(gltf_path: String) -> String:
	return scene_path_for(gltf_path, SCENE_STYLE_WRAPPER)


static func inherited_path_for(gltf_path: String) -> String:
	return scene_path_for(gltf_path, SCENE_STYLE_INHERITED)
