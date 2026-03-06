# Changelog

All notable changes to the Nexus Pipeline (Blender → Godot) are documented here.

## [1.2.0] - 2026-03-07

### Added

#### Blender Addon (nexus_b2g)

- **Collection Presets**: New preset bar in the Collection Section for quick application of export settings. Five numbered slots plus a "Manage" button allow saving, applying, reordering, and renaming presets. Presets are stored in the Source Folder (`nexus_collection_presets.json`), shared across all .blend files in the project. Apply affects all selected collections in the Outliner (plus the active one), excluding the Scene root. Rename via double-click on the preset name; overwriting a slot resets the name to the default.

#### Godot Addon (nexus_importer)

- **Reimport Assets**: New toolbar action reads asset_index.json and queues all glTFs (that exist at their expected paths) for reimport. Missing assets are skipped with a warning.
- **Asset Sanitization**: New toolbar action removes asset_index.json entries whose glTF files no longer exist, cleaning orphaned index entries.
- **Toolbar Menu Tooltips**: All menu entries now have descriptive tooltips explaining their purpose and usage.

### Changed

#### Blender Addon (nexus_b2g)

- **Animation Settings (animation.py)**: "Scan/Refresh All Strips" now removes orphaned settings (entries for renamed or deleted NLA strips). Init button label changed from "Initialize Strips on this Armature" to "Initialize Missing Strip Settings". Strips without a linked action (e.g. Meta strips) show a hint that they will not be exported.
- **Collection Properties (collection.py)**: Physics Material browser now pre-fills with the existing path (res:// converted to system path) when opened, matching Script Browser behavior. MultiMesh "Identify Invalid Sources" now correctly lists collections that are instanced but not set to Asset or Skeletal Asset.
- **Asset Catalog (assets.py)**: `get_catalog_file_path` now returns `Optional[Path]` for correct type consistency. `sync_collection_asset` now checks `ensure_library_registered` and aborts with a warning if project paths are invalid.

#### Godot Addon (nexus_importer)

- **Toolbar Menu**: Tools menu entries (Import Mode, Repathing Tool, Export Animation Library) are now grouped in a "Nexus Importer" submenu, aligning with other Nexus products.

### Fixed

#### Godot Addon (nexus_importer)

- **"Task 'reimport' already exists" (large assets)**: Added `resources_reimporting` signal to track Godot's reimport state. Wrapper creation, config writes, and `reimport_files()` are now blocked while `_reimport_in_progress` is true, preventing the error when importing assets with many textures.
- **MultiMesh "Instance count must be 0" errors**: Godot bug #95617/#106950 causes property deserialization order issues when loading .multimesh.res files. multimesh_processor now creates fresh MultiMesh instances and skips ResourceLoader.load after save, using the in-memory resource directly.

#### Blender Addon (nexus_b2g)

- **Collection Properties Handler**: `update_collection_properties` now uses try/finally to ensure the handler lock is always released. Previously, an exception could leave the lock stuck, permanently disabling UI sync.
- **Material Reference Browser**: `MATERIAL_OT_open_reference_browser` now uses `get_target_path` (Godot project folder) instead of `get_project_root` for res://-to-system-path conversion. This fixes incorrect starting paths when opening the file browser for material references.
- **Material Texture Tracing**: `trace_texture_source` and `_recursive_trace` now accept `context` as a parameter and pass it to `ingest_texture` instead of using `bpy.context`. Avoids issues when exporting in background mode or from hooks with limited context.
- **Material Exception Handling**: `_get_uid_from_tres` and `replace_materials_with_placeholders` now log exceptions via `log.NEXUS_LOGGER.debug()` instead of silently swallowing them.
- **Asset Catalog Write (assets.py)**: `_atomic_catalog_write` now sets `temp_name` immediately after creating the temp file to fix a temp-file leak when `writelines`/`flush`/`fsync` throw before assignment.
- **gltfpack Optimizer (optimizer.py)**: When "Optimize Mesh" is enabled, gltfpack now uses `-kv` (keep all vertex attributes) and `-vtf` (floating-point texture coordinates) so UVs, vertex colors, and other game-engine relevant data are no longer stripped during optimization.

## [1.1.4] - 2025-03-05

### Added

#### Blender Addon (nexus_b2g)

- **Material Resource Name**: When using "Generate New" for materials, a new "Name" field is available. This maps to Godot's `resource_name` property on the exported .tres material, enabling Raycast-based surface identification (e.g. footstep sounds, particle FX). Queried in Godot via `get_surface_material(surface_index).resource_name`.

## [1.1.3] - 2025-03-04

### Changed

#### Blender Addon (nexus_b2g)

- **Metadata instead of Surface Tag**: Surface Tag (Collection) and Surface Tag Override (Object) have been replaced by a flexible Metadata system. Users can define arbitrary key-value pairs with types float, int, bool, string, and StringName; these are set in Godot via `node.set_meta()`. Significant upgrade over the previous single-field approach.

#### Godot Addon (nexus_importer)

- **Metadata import**: Root processor and collision processor now handle the new `nexus_metadata` format. Legacy glTF files with `physics_surface_name` or `nexus_surface_override` remain valid through backward compatibility.

## [1.1.2] - 2025-03-03

### Changed

#### Blender Addon (nexus_b2g)

- **Structured Logging**: Replaced all `print()` calls with Python's `logging` module. New `log.py` provides `NEXUS_LOGGER` with DEBUG/INFO/WARNING/ERROR levels for easier debugging and log filtering.
- **Material Index Batching**: Material index is now loaded once and written once per export run instead of per material, reducing I/O overhead for scenes with many materials.
- **Optimizer Robustness**: File swap during gltfpack optimization uses `safe_remove` and `safe_move` with retry logic (3 attempts, 0.1s delay) to handle temporary file locks from Godot importer or other processes.
- **Hash Caching**: Material hash results are cached per export run to avoid redundant computation when the same material is used by multiple objects. Cache is cleared at the start of each export.
- **Smart Cache Quick-Reject**: Asset hash is only calculated when necessary. If the export path changed or the file is missing, the expensive hash computation is skipped and the asset is exported directly.
- **Orphan Parse Robustness**: `cleanup_asset_index_logic` and `cleanup_material_index_logic` now parse orphan entries using `split(" (", 1)[0]` instead of `split(' ')[0]`, correctly handling IDs that may contain spaces.

### Fixed

- **Dead Code**: Removed unreachable `return None` after the final return in `material.py` `_generate_tres_content`.
- **Silent Exception Swallowing**: Replaced bare `except ValueError: pass` and `except Exception: pass` with explicit logging. Path-relative errors log at DEBUG; selection restore failures log at WARNING.

## [1.1.1] - 2025-03-01

### Fixed

#### Blender Addon (nexus_b2g)

- **Asset-ID Duplicates**: Duplicated collections no longer share the same `asset_id`. When a collection is duplicated, renamed, and its content (mesh, collision) modified, the duplicate previously retained the original `asset_id`, causing all linked Level instances to reference the same exported asset. `ensure_unique_asset_ids()` now detects duplicate IDs before export and assigns new UUIDs to duplicates. Console output: `NEXUS Fix: Found duplicate Asset ID '...'. Assigned new ID '...' to collection '...'.`

#### Godot Addon (nexus_importer)

- **Duplicate ResonanceGeometry in Levels**: When combining assets into a Level, baked collection-instance meshes were processed by both the resonance processor and the instancing processor. This created extra ResonanceGeometry nodes at the scene root even though the instanced asset already contained them. Nodes that are descendants of a `nexus_asset_id` node are now skipped by the resonance and collision processors, since the entire subtree is replaced by the instanced asset.
- **Recursive reimport_files() Error**: The wrapper creation step ran while reimport was still in progress (`_reimport_pending`), causing `ResourceSaver.save()` to trigger Godot's file watcher and produce "Attempted to call reimport_files() recursively". Wrapper creation is now blocked until all reimports have finished (`and not _reimport_pending`).
- **"Task 'reimport' already exists"**: Config write triggers Godot's file watcher; calling `reimport_files()` too early caused duplicate reimport tasks. Reimport is now queued only after `resources_reimported` fires (signal-based). Two-cycle wait handles textures firing before glTF on heavy imports.

