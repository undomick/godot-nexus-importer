# Nexus Importer – Addon Documentation

Godot addon for importing assets from the Nexus Blender Export Pipeline.

## Setup

1. **Install**: Add as submodule (see main README) or copy from a release ZIP into `addons/nexus_importer`.
2. **Asset Index**: After exporting from Blender, `asset_index.json` and `material_index.json` appear in the Godot project root.
3. **Import Mode**: Project → Tools → Nexus Importer → Import Mode
   - **Auto**: Config and wrappers update on import. Recommended for most workflows.
   - **Manual**: Run Tools → Nexus Importer → Reimport Assets after each Blender export.

## How It Works

- **Automatic**: When you open a Godot project or reimport files, Nexus detects glTF files with Nexus metadata and applies post-processing (root type, collision layers, bone attachments, materials, etc.).
- **Wrappers**: Nexus creates `.tscn` wrapper scenes for imported glTFs when needed (e.g. for scripts, animation libraries).
- **Feedback**: A notification appears in the editor when Nexus processes imports (Godot 4.4+).

## Project Settings

Under `nexus/import/`:

- `auto_assign_post_processor`: Enable automatic Nexus processing (default: true)
- `asset_index_path`: Path to asset_index.json (default: res://asset_index.json)
- `material_index_path`: Path to material_index.json (default: res://material_index.json)

## Index Files

- **asset_index.json**: Tracks exported assets (paths, hashes). Required for placeholders and reimport.
- **material_index.json**: Tracks shared materials. Do not delete; Nexus uses it for material swapping.

## Troubleshooting

- **Imports look like plain glTF**: Ensure the glTF was exported from Blender with Nexus (Nexus Export sidebar). Check that Import Mode is Auto or run Reimport Assets manually.
- **Placeholder not replaced**: Asset ID in Blender must match an entry in asset_index.json. Run Reimport Assets after exporting.
