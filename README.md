# Nexus Importer for Godot
[![Discord](https://img.shields.io/discord/1446024019341086864?label=Discord&logo=discord&style=flat-square&color=5865F2)](https://discord.gg/VTSpAEHHhW)
[![Ko-fi](https://img.shields.io/badge/Support%20me-Ko--fi-F16061?style=flat-square&logo=ko-fi&logoColor=white)](https://ko-fi.com/jundrie)

**The intelligent link for your Blender-Godot pipeline. Turn your Blender exports into game-ready Godot assets, automatically.**

Tired of re-configuring your scenes in Godot after every re-import from Blender? The Nexus Importer acts as an intelligent post-processor that understands your assets exported from Blender and automatically configures them for in-game use.

> **Prerequisite:** This addon works exclusively with glTF files exported by the [Nexus: Godot Pipeline](https://superhivemarket.com/products/nexus-godot-pipeline) Blender addon. It relies on metadata written during export.

## Installation

**Option A: Godot Asset Library** (when published)

1. Open your Godot project.
2. AssetLib → search for "Nexus Pipeline Importer" → Install.

**Option B: Manual install from release**

1. Download `nexus_importer-<version>.zip` from [Releases](https://github.com/undomick/godot-nexus-importer/releases).
2. Extract to your Godot project root (you should get `addons/nexus_importer/`).
3. Project → Project Settings → Plugins → enable "Nexus Importer".

**Option C: Git submodule**

See [SUBMODULE_SETUP.md](SUBMODULE_SETUP.md) for submodule and symlink instructions.

## Key Features - Your New Workflow

Instead of post-processing your assets in Godot, you define everything at the source: in Blender. The Nexus Importer interprets your settings and builds the scenes just the way you need them.

*   **Dedicated Export Types:**
    Define the role of your asset directly in Blender. Whether it's an `Asset`, an animated `Skeletal Asset`, a pure `Animation Library`, or a complete `Level`—Nexus applies the appropriate export settings and conventions for each type. This ensures a clean separation of concerns and an organized project workflow.

*   **Automatic Collision Shape Generation:**
    Define primitive collision shapes (Box, Capsule, etc.) or Trimesh/Convex shapes directly in Blender on a per-object basis. Nexus automatically creates and configures the `CollisionShape3D` nodes in Godot. No more manual setup.

*   **Seamless External Material Workflow:**
    Manage your materials as reusable `.tres` files in Godot. The Nexus addon in Blender links your models to these external materials. Edit your materials in Godot without fear of them being overwritten on the next re-import.

*   **Scripts & Groups on Autopilot:**
    Assign a script to your assets or add them to a Godot group right from Blender's UI. Your objects are correctly configured the moment they arrive in Godot.

*   **Nexus Resonance (Real Spatial Audio) support:**
    Instead of creating for every geometry an extra ResonanceGeometry-Node (which can get quite tedious), you can assign it from within Blender to your asset. Get Nexus Resonance from [here](https://github.com/undomick/godot-nexus-resonance)!

*   **And Many More Features:**
    The Nexus pipeline is packed with tools to make your life easier: 
    * manage asset presets/templates
    * a flexible **folder structure** for exports
    * a powerful **batch-export** for automating entire project folders
    * optional **mesh optimization** (via glTFpack)
    * supports exports of cameras, lights, paths directly out of Blender
    * asset tracking and clean up
    * automatic or manual creation of wrapper scenes and/or inherited scenes from glTF

## 💬 Support & Community

Join the Discord server to ask questions, suggest features, or show off your projects made with this addon!

<a href="https://discord.gg/VTSpAEHHhW"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join Discord"></a> <a href="https://ko-fi.com/jundrie"><img src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-F16061?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Support me on Ko-fi"></a>