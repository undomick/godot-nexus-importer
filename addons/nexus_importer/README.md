# Nexus Importer – Addon Documentation

Godot addon for importing assets from the Nexus Blender Export Pipeline.

## Setup

1. **Install**: Add as submodule (see main README) or copy from a release ZIP into `addons/nexus_importer`.
2. **Asset Index**: After exporting from Blender, `asset_index.json` and `material_index.json` appear in the Godot project root.
3. **Import Mode**: Project → Tools → Nexus Importer → Import Mode
   - **Auto**: After import/reimport, Nexus assigns import settings, runs post-processing, and queues wrapper scenes when needed. Recommended for most workflows.
   - **Manual**: Run Tools → Nexus Importer → Reimport Assets after each Blender export. Post-processing still runs on glTF import; wrapper creation and batch reimport are manual.

## How It Works

- **glTF post-processing**: Every reimport runs `import_post_processor.gd` when configured on the `.import` file (collision, materials, animations, LODs, etc.). This is independent of Auto/Manual mode.
- **Auto-only editor steps**: Wrapper `.tscn` generation, multimesh manifest scanning, and import-config fixes run automatically only when Import Mode is **Auto** (or when you use Reimport Assets / context menus).
- **Import order**: Batch and manual reimports drain glTF queues in one `reimport_files` batch per wave (textures, then asset glTFs, then composition glTFs when dependencies are ready). Wrapper/inherited scenes are built in export-type priority. Composition glTFs import in a second wave with `mass_import=false` so instancing runs during post-import; any remaining placeholders use a single glTF reimport plus async inherited save.
- **Batch import**: After a Blender batch export, `mass_import` defers per-signal config/wrapper work and external scene loads during the bulk asset glTF reimport. Composition glTFs import in a second wave once dependency scenes exist, then inherited scenes are saved via the editor (`open_scene_from_path` + `save_scene_as`) so roots use `instance=ExtResource(...)` instead of baked meshes.
- **Reimport Assets**: Menu action reimports from `asset_index.json` and also queues dependent composition glTFs (Combined/Level/MultiMesh manifest).
- **Wrappers**: Nexus creates `.tscn` wrapper scenes for imported glTFs when needed (e.g. for scripts, animation libraries).
- **Feedback**: A notification appears in the editor when Nexus processes imports (Godot 4.4+).

## Project Settings

Under `nexus/import/`:

- `auto_assign_post_processor`: Enable automatic wrapper/config updates on import (default: true). Does not disable glTF post-processing; use Manual mode when you want to control reimport timing.
- `asset_index_path`: Path to asset_index.json (default: res://asset_index.json)
- `material_index_path`: Path to material_index.json (default: res://material_index.json)

## Index Files

- **asset_index.json**: Tracks exported assets (paths, hashes). Required for placeholders and reimport.
- **material_index.json**: Tracks shared materials for **glTF Separate** / **GLB Separate**. Do not delete; Nexus uses it for material swapping. Typical **GLB** exports (`material_pipeline: gltf`) extract materials as editable `.tres` files next to the `.glb` instead (delete a sidecar and reimport to refresh from the GLB).

## Shader includes (`shader_inc/`)

Converted materials may `#include` shared GLSL from `res://addons/nexus_importer/shader_inc/` (map range, procedural hash, Voronoi/Noise slices per feature and dimension, simple procedural textures, radial tiling, etc.). After updating the Nexus Blender addon, refresh these files:

```bash
python path/to/nexus_b2g/shader_convert/tools/sync_shader_includes.py --godot-root /path/to/godot/project
```

Export fails with a missing-include error if `shader_inc` is out of date relative to the Blender addon version.

## Troubleshooting

- **Imports look like plain glTF**: Ensure the glTF was exported from Blender with Nexus (Nexus Export sidebar). Check that Import Mode is Auto or run Reimport Assets manually.
- **Placeholder not replaced**: Asset ID in Blender must match an entry in asset_index.json. Run Reimport Assets after exporting.
- **Inherited scenes show white meshes or unique children instead of instances** (e.g. `sand_inherited.tscn`, `pack1_inherited.tscn`, `structure_inherited.tscn`): Delete stale `*_inherited.tscn` files and re-export from Blender (composition glTFs must be thin: instance nodes with `nexus_asset_id` only, no embedded mesh subtrees). Then run **Reimport Assets** in Godot. Inherited scenes must reference child scenes via `instance=ExtResource(...)`; if a composition `.gltf` or `.tscn` contains embedded `ArrayMesh` sub-resources under instance roots, re-export from Blender with the current Nexus addon.
- **Godot keeps reimporting / closing tabs after import**: Usually a Level/Combined inherited build aborted on unresolved placeholders (e.g. deleted wrappers still referenced by markers). Nexus now marks that glTF aborted and stops the loop. After fixing missing assets, re-export or run **Reimport Assets** to clear the abort and rebuild.
- **MultiMesh manifest (`MULTIMESH_MANIFEST`)**: Import runs in three stages — (1) source glTFs/scenes ready in `asset_index.json`, (2) manifest glTF reimport builds `MultiMeshInstance3D` nodes in the import cache **and** writes `.multimesh*.res` sidecars, (3) inherited/wrapper scene saved via the editor. Stage 3 starts only when both cache and sidecars are complete; sidecars alone are not enough. Console success line: `Nexus MultiMesh: <name> -> N sources, N MMIs`, then `Nexus Inherited: Created '<name>_inherited.tscn'.`
