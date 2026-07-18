class_name NexusPaths
extends RefCounted

## Project settings keys and path helpers for Nexus Importer.

const SETTING_AUTO_IMPORT = "nexus/import/auto_assign_post_processor"
const SETTING_ASSET_INDEX = "nexus/import/asset_index_path"
const SETTING_MATERIAL_INDEX = "nexus/import/material_index_path"

const SCENE_STYLE_WRAPPER = "wrapper"
const SCENE_STYLE_INHERITED = "inherited"
const SCENE_STYLE_DISABLED = "disabled"

const IMPORT_POST_PROCESSOR = "res://addons/nexus_importer/import_post_processor.gd"

static func auto_import_enabled() -> bool:
	return ProjectSettings.get_setting(SETTING_AUTO_IMPORT, true)


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


## Sidecar .tres path for an embedded GLB material next to the container file.
static func gltf_material_tres_path(gltf_path: String, material_name: String) -> String:
	var stem := gltf_path.get_file().get_basename()
	var safe := NexusUtils.sanitize_path_segment(material_name)
	if safe.is_empty() or safe == "_":
		safe = "Material"
	return gltf_path.get_base_dir().path_join("%s_%s.tres" % [stem, safe])
