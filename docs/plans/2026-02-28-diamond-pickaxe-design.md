# Design: Get a Diamond Pickaxe (Gameplay Chunk)

**Date:** 2026-02-28
**Status:** Approved

---

## Overview

Implement the "Get a diamond pickaxe" gameplay chunk as a reusable skill function plus a built-in command. This is the most foundational end-game chunk — a diamond pickaxe is required to mine obsidian for the nether portal, which gates all subsequent end-game progression.

---

## Architecture

### Skill function — `getDiamondPickaxe(bot)`

**File:** `src/agent/library/skills.js`

A state machine that inspects the bot's inventory at entry to determine the highest-tier pickaxe already held, then executes only the remaining steps. Fully idempotent and restartable.

**States and actions:**

| State | Condition | Actions |
|-------|-----------|---------|
| `DONE` | has `diamond_pickaxe` | return immediately |
| `HAVE_IRON` | has `iron_pickaxe` | dig to y=-11, mine 3 diamond ore, craft diamond pickaxe, return to surface |
| `HAVE_STONE` | has `stone_pickaxe` | collect 3 iron ore, smelt to iron ingots, craft iron pickaxe → fall through |
| `HAVE_WOODEN` | has `wooden_pickaxe` | collect 3 cobblestone, craft stone pickaxe → fall through |
| `NOTHING` | no pickaxe | collect 3 logs, craft planks + sticks + crafting table, craft wooden pickaxe → fall through |

Each tier falls through to the next until diamond is reached.

**Existing skills used:**
- `collectBlock(bot, blockType, num)` — wood, stone, iron ore, diamond ore
- `craftRecipe(bot, itemName, num)` — planks, sticks, all pickaxes
- `smeltItem(bot, itemName, num)` — raw iron → iron ingots
- `digDown(bot, levels)` — reach diamond depth (y=-11, ~surface+60 levels down)
- `goToSurface(bot)` — return after mining diamonds

**Diamond depth:** y=-11 is optimal for diamond ore in Minecraft 1.18+.

**Ore targets:**
- Iron: `iron_ore` or `deepslate_iron_ore`
- Diamond: `diamond_ore` or `deepslate_diamond_ore`

---

### Command wrapper — `!getDiamondPickaxe`

**File:** `src/agent/commands/actions.js`

A no-parameter built-in command following the same pattern as `!collectBlocks`. Calls `skills.getDiamondPickaxe(bot)` and returns a human-readable success or failure message. Appears in `$COMMAND_DOCS` so all bots can discover and call it directly without `!newAction`.

---

## What is NOT in scope

- Mining obsidian (separate chunk: Build a nether portal)
- Enchanting the pickaxe
- Fortune/Silk Touch considerations
- Multi-bot coordination for this chunk
