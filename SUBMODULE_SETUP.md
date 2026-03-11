# Submodule Setup Guide

This repository uses the standard `addons/nexus_importer/` structure for Godot Asset Library compatibility.

## Adding as Submodule

### Option A: Clone repo into a subfolder + symlink

Add the full repo as a submodule, then symlink the addon folder:

```bash
# From your Godot project root (or repo root for monorepo)
git submodule add https://github.com/undomick/godot-nexus-importer.git godot-nexus-importer
```

Then create a symlink so Godot finds the addon:

**Windows (Developer Mode or as Administrator):**
```powershell
mklink /D addons\nexus_importer godot-nexus-importer\addons\nexus_importer
```

**Linux / macOS:**
```bash
mkdir -p addons
ln -s ../godot-nexus-importer/addons/nexus_importer addons/nexus_importer
```

### Option B: Monorepo (Godot project in `game/`)

```bash
git submodule add https://github.com/undomick/godot-nexus-importer.git godot-nexus-importer
```

**Windows:**
```powershell
mklink /D game\addons\nexus_importer godot-nexus-importer\addons\nexus_importer
```

**Linux / macOS:**
```bash
ln -s ../../godot-nexus-importer/addons/nexus_importer game/addons/nexus_importer
```

### Option C: Clone repo that already has the submodule

```bash
git clone --recurse-submodules https://github.com/your-org/your-repo.git
# or after a normal clone:
git submodule update --init --recursive
```

Then create the symlink as above.

## Updating the Submodule

```bash
cd godot-nexus-importer
git pull origin main
cd ..
git add godot-nexus-importer
git commit -m "Update Nexus Importer submodule"
```

Or pin to a specific tag:

```bash
cd godot-nexus-importer
git fetch --tags
git checkout v1.3.0
cd ..
git add godot-nexus-importer
git commit -m "Pin Nexus Importer to v1.3.0"
```

## Verifying Setup

After setup, you should have:

- `addons/nexus_importer/plugin.cfg`
- `addons/nexus_importer/plugin.gd`
- `addons/nexus_importer/processors/`
- `addons/nexus_importer/runtime/`

Enable the plugin: **Project → Project Settings → Plugins → Nexus Importer**.
