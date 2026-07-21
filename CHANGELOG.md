# Changelog

All notable changes to the Nexus Pipeline (Blender → Godot) are documented here.

## [2.0.1] - 2026-07-21

### Blender Addon (nexus_b2g)

- Nested **Levels** export inline again (like nested Assets).
- sticky **asset_id** no longer leak into exports.
- Large Levels are no longer blocked by a thin node-count budget alone.
- SMART batch no longer skips files that still need export (empty `assets` / missing glTFs).
- Safer index writes when Godot is open; clearer batch log after interactive export.
- **Discard Mesh** toggles additional Viewport Display (Wire / Textured).

### Godot Addon (nexus_importer)

- Levels/Combined no longer loop-rebuild unresolved inherited scenes.
- MultiMesh keeps source materials/textures more reliably after batch import.
- Import order: Assets/Skeletals → Combined → Anim Lib → MultiMesh → Level.

## [2.0.0] - 2026-07-18

### Blender Addon (nexus_b2g)

- **New Collection Types:** Exclude, Folder, Combined Asset
- **New Root Type:** VehicleBody3D
- **New Collision Type:** SeparationRayShape3D (Use an empty to find this collision type)
- **Breaking:** nested Levels blocked; use new **Combined Asset** type.
- Nested Assets inline are now possible.
- Anim-lib `.res` next to the anim-lib glTF; glTF carries `target_asset_path` for the skeleton.
- Project path presets (1–8); separate Material / Texture Layout (default: Dedicated folder) replaces Resource Layout.
- gltfpack **1.2** with **Clean** / **Compressed** modes, new optimizer options.
- Sync Lights from Godot; extended light metadata/UI (Area, gobos, cull mask, …).
- Shader export: Mix Shader, more nodes (Layer Weight, Sky, Sheen, …), group/displacement support; partial BSDFs warn instead of failing export.
- Fixes: Smart Export skip/hash, curve multi-user bake, visibility, collection name sanitize, shared Level materials, Reference Existing re-export.
- **Geometry Container GLB:** export a shareable `.glb` with materials and textures embedded. Previous binary mode is now **GLB Separate**.
- **Parallel batch export** (opt-in): run several `.blend` files at once via Parallel Workers.
- **Smart batch** skips unchanged files entirely (Force still re-exports everything).
- **Set Defaults** in Project Paths: preferred Scene Style per root type, stored with the Source folder.
- Cleaner batch log (less spam, clearer errors); empty/invalid collections warn or skip without leaving empty folders.

### Godot Addon (nexus_importer)

- Scene Style (generate Wrapper or Inherited) was moved to Blender (Collection Section)
- Anim-lib `.res` from `animation_libs/`; skeleton via `target_asset_path` (legacy fallback kept).
- Faster batch reimport; level/combined instancing waits until dependency scenes exist.
- Nested Asset/Skeletal collections import with their own Godot root type.
- Extended light import (AreaLight3D 4.7+, gobos, visibility/shadow, …).
- Tools → Sanitize orphaned materials.
- Import pipeline fixes (wrappers, Combined before Level, lights metadata).
- Typical **GLB** imports write editable `.tres` materials next to the `.glb`; Nexus Separate still uses the material index.

## [1.5.1] - 2026-05-31

### Blender Addon (nexus_b2g)

- Fixed level export duplicating asset textures and breaking shared materials in Godot.

### Godot Addon (nexus_importer)

- Importer reloads `material_index.json` when the file changes, so material updates apply without restarting the editor.

## [1.5.0] - 2026-05-27

### Blender Addon (nexus_b2g)

- Added extended material conversion from Blender shader nodes to Godot shaders.
- Updated mesh optimization to **gltfpack 1.1** (Safe / Compact modes in UI).
- Re-organized target path and export layout options; settings now persist in addon preferences across `.blend` files.
- Improved compatibility with third-party glTF export addons.
- Minor bug and UI fixes.

### Godot Addon (nexus_importer)

- Import warning when shader materials were exported with an older Blender addon version.

## [1.4.0] - 2026-03-22

### Added

#### Blender Addon (nexus_b2g)

- **Flexible Source / Target paths**: Each of Source and Target can be resolved either **relative to Project Root** (recommended monorepo layout: e.g. `src` / `game`) or as an **absolute** folder on disk. Browse outside Project Root automatically switches the affected side to absolute mode. Preferences JSON export/import is now **version 2** and includes the new fields (older JSON files still import with defaults).
- **GLB export (experimental)**: **Geometry Container** in Quick Export (persistent addon preference) chooses **glTF Separate** (default: `.gltf` + external buffers/textures, texture organize + optional gltfpack) or **GLB** (single binary file). Asset index validation and manual registration support `.glb`. **gltfpack** is skipped for GLB; `organize_textures` remains a no-op for `.glb`. MultiMesh manifest files stay `.gltf`. Treat as experimental until you have validated your assets end-to-end in Godot.

#### Godot Addon (nexus_importer)

- **GLB support (experimental)**: Reads **NEXUS** metadata from the **JSON chunk** of `.glb` files (same `extras` contract as `.gltf`). Reimport, import config, filesystem context menu, and folder batching treat `**.glb` like `.gltf`**. Prefer regression-testing wrappers, materials, LODs, resonance, and animation libraries after switching formats.

### Changed

#### Blender Addon (nexus_b2g)

- **Project path validation**: Target must exist on disk and resolve correctly; absolute Source requires a valid directory when that mode is selected. **Project Root** remains required for batch export, presets, and related features.
- **Project Paths UI**: Enum label **“Relative to project root”** (was “Under project root”). For absolute folders, only the native `DIR_PATH` control is shown (no duplicate folder icon next to the custom browse operator).

### Fixed

#### Blender Addon (nexus_b2g)

- **Reference Existing (material)**: `material_index.json` entries were overwritten after export with the default generated `.tres` path, so Godot kept using the wrong resource. The post-pass now only merges `source_blend_file` (and name) and leaves `**relative_path` / `content_hash`** to the material exporter. The material file browser stores `**res://`** paths via the same conversion as typed paths.
- **Material export skip logic**: When `content_hash` already matched the reference state but `**relative_path` in the index was still wrong** (legacy inconsistency), export skipped and never repaired the index. Skip now requires **hash match and path match** for Reference; for Generate, **hash + path + on-disk** `.tres` **content** matching a fresh generation (including `nexus_material_id`), so stale or incomplete hashes no longer suppress needed writes.

## [1.3.1] - 2026-03-15

### Fixed

#### Godot Addon (nexus_importer)

- **In some cases "importer for type '' not found" occured on Reimport**: Materials (.tres) were incorrectly queued for reimport. Godot has no importer for native resource formats; calling reimport_files on .tres triggered the error. Materials are still discovered for texture directory scanning but are no longer passed to reimport_files.
- **Duplicate .res files for Resonance Geometry on Reimport**: Resonance geometry sidecar .res files were created with incremented suffixes (SM_Door_reso_1.res, ...) whenever the base file already existed. The resonance processor now overwrites the existing file on reimport. The idx suffix is only used when multiple resonance nodes in the same glTF share the same base name.

## [1.3.0] - 2026-03-10

### Added

#### Blender Addon (nexus_b2g)

- **Icon Bar**: Left-hand vertical icon bar for quick section navigation. Click an icon to select and display the corresponding section (blue highlight). Pin sections to keep them visible (orange/red highlight).

## [1.2.1] - 2026-03-09

### Added

#### Godot Addon (nexus_importer)

- **Wrapper and Inherited Scenes**: The addon can now create both Wrapper Scenes and Inherited Scenes for glTF assets. Scene type is configurable via tools (`nexus/import/scene_style`); automatic creation uses the selected style. Alternatively, use the FileSystem context menu on glTF files or folders: "Create Nexus Wrapper Scene" or "Create Nexus Inherited Scene" to create the desired scene type on demand.

### Fixed

#### Godot Addon (nexus_importer)

- **Manual Import Mode: glTFs not processed**: When Import Mode was set to Manual, glTFs were not interpreted at all

#### Blender Addon (nexus_b2g)

- **Resonance Geometry Dynamic overwritten by Static**: When exporting assets with Resonance Geometry set to Dynamic, the value was incorrectly reset to Static in both the UI and the exported glTF. This occurred when `update_object_properties` reapplied the root-type default (Static for StaticBody/Area) even after the user had explicitly chosen Dynamic. The logic now preserves an explicit Dynamic choice and no longer overwrites it with Static.

### Known Issues

#### Blender Addon (nexus_b2g)

- **Zen UV compatibility**: When Zen UV and Nexus are both enabled, selecting Animation Library or Multimesh in the Collection section may cause Blender to crash. This is caused by Zen UV's depsgraph handler (Blender issue #128361). Workaround: Disable Zen UV when using these export types. Nexus shows a warning when both are active.

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

