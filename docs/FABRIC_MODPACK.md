# Fabric Mod Pack Support

> **Status**: Optional feature — disabled by default. Zero impact on vanilla Paper servers.

## Overview

Mindcraft now supports running on **Fabric 1.21** modded servers alongside the default Paper (vanilla) server. When enabled, the bot gains:

- **Mod detection** — Scans the `mods/` directory for Fabric mod JARs and builds a capability registry
- **Modded commands** — `!mineModdedOre`, `!useModdedMachine`, `!processModdedItem`, `!scanModdedBlocks`, `!listMods`
- **LLM context injection** — Detected mods, ores, and machines are injected into the prompt
- **Docker Compose override** — One-command switch from Paper to Fabric

## Quick Start

### 1. Enable Modded Mode

In `settings.js`:
```js
"modded_mode": true,
"server_type": "fabric",
"fabric_mods_dir": "./mods",
```

Or via the launcher (`DragonSlayer-Launcher.ps1`):
```powershell
$MODDED_MODE = $true
```

Or via environment variable:
```bash
export SETTINGS_JSON='{"modded_mode": true, "server_type": "fabric"}'
```

### 2. Add Fabric Mods

Place `.jar` files in the `mods/` directory:

```
mods/
├── sodium-fabric-0.6.0+mc1.21.jar
├── lithium-fabric-0.13.0+mc1.21.jar
├── starlight-fabric-1.2.0+mc1.21.jar
├── ferritecore-fabric-7.0.0+mc1.21.jar
└── baritone-fabric-1.11.0+mc1.21.jar
```

Download mods from [Modrinth](https://modrinth.com/) or [CurseForge](https://www.curseforge.com/minecraft/mc-mods). Ensure all mods target **Minecraft 1.21 + Fabric Loader**.

### 3. Start with Docker (Fabric)

```bash
docker compose -f docker-compose.yml -f docker-compose.fabric.yml up -d
```

This switches the server from `TYPE: "PAPER"` to `TYPE: "FABRIC"` and mounts `./mods` into the container.

### 4. Start with Launcher (Windows)

```powershell
# Edit DragonSlayer-Launcher.ps1:
$MODDED_MODE = $true

# Then run as usual:
.\DragonSlayer-Launcher.ps1
```

## Architecture

```
settings.js                          # modded_mode, server_type, fabric_mods_dir
     │
     ├─► src/registry/modded_registry.js   # Scans mods/ dir, builds capability map
     │        │
     │        └─► ModdedRegistry class
     │              ├── hasMod('create')         → boolean
     │              ├── hasCategory('tech')       → boolean
     │              ├── getAllModdedOres()         → string[]
     │              ├── getAllModdedMachines()     → string[]
     │              └── getPromptSummary()        → string (for LLM injection)
     │
     ├─► src/agent/library/modded_skills.js   # Mod-aware skill functions
     │        ├── mineModdedOre(bot, oreType, count)
     │        ├── useModdedMachine(bot, machineId)
     │        ├── processModdedItem(bot, inputItem, count)
     │        ├── scanModdedBlocks(bot, range)
     │        ├── checkModAvailable(bot, modId)
     │        └── listInstalledMods(bot)
     │
     ├─► src/agent/commands/actions.js    # Registers !commands (gated behind modded_mode)
     │
     └─► docker-compose.fabric.yml        # Docker override: Paper → Fabric
```

## Supported Mods

The registry has built-in knowledge of these mod families:

| Category | Mod IDs | Auto-detected |
|----------|---------|---------------|
| Performance | sodium, lithium, starlight, ferritecore, krypton, c2me | ✅ |
| Tech | create, ae2, mekanism, techreborn, modern-industrialization | ✅ |
| Magic | botania, ars-nouveau, hex-casting, theurgy | ✅ |
| Pathfinding | baritone, fabric-baritone, baritone-api | ✅ |
| Utility | jade, rei, jei, modmenu | ✅ |
| Storage | sophisticated-backpacks, iron-chests, expanded-storage | ✅ |

Unknown mods are still detected by filename and listed, but won't have block/item mappings.

## Modded Commands

These commands are **only available** when `modded_mode: true`:

| Command | Description |
|---------|-------------|
| `!mineModdedOre <oreType> <count>` | Mine modded ores (e.g., `create:zinc_ore`) |
| `!useModdedMachine <machineId>` | Navigate to and interact with a modded machine |
| `!processModdedItem <inputItem> <count>` | Process items using modded machines |
| `!scanModdedBlocks <range>` | Scan for nearby modded blocks |
| `!listMods` | List all detected Fabric mods |

## Backward Compatibility

- **Default**: `modded_mode: false` — zero code paths touched, no modded commands registered
- **Vanilla servers**: All modded skills gracefully return `false` and log a message
- **Docker**: Standard `docker compose up` still uses Paper; Fabric requires explicit `-f docker-compose.fabric.yml`
- **Profiles**: No profile changes needed — modded mode is a global setting
- **Existing commands**: All vanilla commands work identically on Fabric servers

## Recommended Fabric Mod Stack

For best DragonSlayer performance on Fabric 1.21:

```
Performance:  Sodium + Lithium + Starlight + FerriteCore
Pathfinding:  Baritone for Fabric (official port)
Optional:     Jade (HUD), ModMenu (mod management)
```

Total memory overhead: ~200MB additional over vanilla.

## Extending

To add support for a new mod:

1. Add its block/item IDs to `MODDED_INTERACTIONS` in `modded_registry.js`
2. Add its mod ID to the appropriate `MOD_CATEGORIES` entry
3. Optionally add specialized skill functions in `modded_skills.js`
4. Register new `!commands` in `actions.js` (inside the `if (settings.modded_mode)` block)
