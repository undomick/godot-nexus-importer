# Nexus Importer for Godot
[![Discord](https://img.shields.io/discord/1446024019341086864?label=Discord&logo=discord&style=flat-square&color=5865F2)](https://discord.gg/VTSpAEHHhW)
[![Ko-fi](https://img.shields.io/badge/Support%20me-Ko--fi-F16061?style=flat-square&logo=ko-fi&logoColor=white)](https://ko-fi.com/jundrie)

**The intelligent link for your Blender-Godot pipeline. Turn your Blender exports into game-ready Godot assets, automatically.**

Tired of re-configuring your scenes in Godot after every re-import from Blender? Do you spend hours manually adding `CollisionShape3D` nodes, re-assigning materials, and attaching scripts to every single imported asset?

The Nexus Importer puts an end to this repetitive process. By seamlessly integrating with the Godot engine, it acts as an intelligent post-processor that understands your assets exported from Blender and automatically configures them for in-game use. Design your assets in Blender and let Nexus handle the rest.

> ### ⚠️ Important Prerequisite!
>
> The Nexus Importer for Godot is **not** a general-purpose GLTF importer. It is the **exclusive counterpart** to our Blender addon, **[Nexus: Blender to Godot](LINK_TO_MY_BLENDER_ADDON_HERE)**.
>
> This Godot addon will only work as intended on `.gltf` files that have been exported using the corresponding Blender addon, as it relies on the special metadata written during the export process.

---

### Key Features - Your New Workflow

Instead of post-processing your assets in Godot, you define everything at the source: in Blender. The Nexus Importer interprets your settings and builds the scenes just the way you need them.

*   **Dedicated Export Types:**
    Define the role of your asset directly in Blender. Whether it's an `Asset`, an animated `Skeletal Asset`, a pure `Animation Library`, or a complete `Level`—Nexus applies the appropriate export settings and conventions for each type. This ensures a clean separation of concerns and an organized project workflow.

*   **Automatic Collision Shape Generation:**
    Define primitive collision shapes (Box, Capsule, etc.) or Trimesh/Convex shapes directly in Blender on a per-object basis. Nexus automatically creates and configures the `CollisionShape3D` nodes in Godot. No more manual setup.

*   **Seamless External Material Workflow:**
    Manage your materials as reusable `.tres` files in Godot. The Nexus addon in Blender links your models to these external materials. Edit your materials in Godot without fear of them being overwritten on the next re-import.

*   **Scripts & Groups on Autopilot:**
    Assign a script to your assets or add them to a Godot group right from Blender's UI. Your objects are correctly configured the moment they arrive in Godot.

*   **And Many More Features:**
    The Nexus pipeline is packed with tools to make your life easier: pre-configured root node presets (**StaticBody3D**, **RigidBody3D**, etc.), a flexible **folder structure** for exports, a powerful **batch-export** for automating entire project folders, optional **mesh optimization** (via glTFpack), and a robust pipeline for **Vertex Colors**.

### How It Works

The magic is in the metadata.
1.  The **Nexus Blender addon** embeds a set of "instructions" (`NEXUS_METADATA`) into the `.gltf` file during export.
2.  The **Nexus Importer in Godot** reads these instructions during the import process.
3.  It uses a modular system of processors to modify, extend, and package the imported scene into a final, instanced `.tscn` file based on those instructions.

### Installation

1.  Download the addon from the `addons/` directory of this repository.
2.  Place the `nexus_importer` folder into the `addons/` folder of your Godot project.
3.  Go to `Project -> Project Settings -> Plugins` and enable the "Nexus Importer" plugin.

That's it! The importer is now active and will automatically process any `.gltf` file created with the Nexus Blender addon.

## 💬 Support & Community

Join the Discord server to ask questions, suggest features, or show off your projects made with this addon!

<a href="https://discord.gg/VTSpAEHHhW"><img src="https://img.shields.io/badge/Join-Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join Discord"></a> <a href="https://ko-fi.com/jundrie"><img src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-F16061?style=for-the-badge&logo=ko-fi&logoColor=white" alt="Support me on Ko-fi"></a>
