# Diamond Pickaxe Gameplay Chunk Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `getDiamondPickaxe(bot)` skill and a `!getDiamondPickaxe` command that automatically progress a bot through wooden → stone → iron → diamond pickaxe tiers.

**Architecture:** State machine — re-reads inventory at the start of each tier so the function is idempotent and restartable from any partially-completed state. Uses only existing skill primitives (`collectBlock`, `craftRecipe`, `smeltItem`, `digDown`, `goToSurface`).

**Tech Stack:** Node.js ESM, mineflayer, existing skills.js / actions.js patterns.

---

## Task 1: Add `getDiamondPickaxe` skill to `skills.js`

**Files:**
- Modify: `src/agent/library/skills.js` — append after line 2643 (end of `exitMinecart`)

**Step 1: Open the file and verify the insertion point**

Confirm that `src/agent/library/skills.js` ends with the `exitMinecart` function closing brace at line 2643. The new function goes directly after it.

**Step 2: Append the skill function**

Add this block at the end of `src/agent/library/skills.js`, after the `exitMinecart` closing brace:

```javascript

export async function getDiamondPickaxe(bot) {
    /**
     * Automatically obtain a diamond pickaxe by progressing through tool tiers.
     * Detects any existing pickaxe and starts from the appropriate tier,
     * so calling it twice is safe (idempotent).
     * Tiers: wooden → stone → iron → diamond.
     * @param {MinecraftBot} bot, reference to the minecraft bot.
     * @returns {Promise<boolean>} true if diamond pickaxe obtained, false otherwise.
     * @example
     * await skills.getDiamondPickaxe(bot);
     **/
    let inv;

    // Already done
    inv = world.getInventoryCounts(bot);
    if (inv['diamond_pickaxe'] > 0) {
        log(bot, 'Already have a diamond pickaxe!');
        return true;
    }

    // ── TIER 1: wooden pickaxe ───────────────────────────────────────────────
    inv = world.getInventoryCounts(bot);
    if (!inv['wooden_pickaxe'] && !inv['stone_pickaxe'] && !inv['iron_pickaxe']) {
        log(bot, 'Starting tool progression: collecting logs...');
        const logTypes = ['oak_log', 'birch_log', 'spruce_log', 'dark_oak_log',
                          'acacia_log', 'jungle_log', 'mangrove_log'];
        // Use logs already in inventory, or collect some
        let logType = logTypes.find(l => (inv[l] ?? 0) >= 3);
        if (!logType) {
            for (const lt of logTypes) {
                if (await collectBlock(bot, lt, 3)) { logType = lt; break; }
            }
        }
        if (!logType) {
            log(bot, 'Cannot find any logs to begin tool progression.');
            return false;
        }
        const plankType = logType.replace('_log', '_planks');
        if (!await craftRecipe(bot, plankType, 1)) {
            log(bot, `Failed to craft ${plankType}.`);
            return false;
        }
        if (!await craftRecipe(bot, 'stick', 1)) {
            log(bot, 'Failed to craft sticks.');
            return false;
        }
        if (!await craftRecipe(bot, 'wooden_pickaxe', 1)) {
            log(bot, 'Failed to craft wooden pickaxe.');
            return false;
        }
        log(bot, 'Wooden pickaxe crafted.');
    }

    // ── TIER 2: stone pickaxe ────────────────────────────────────────────────
    inv = world.getInventoryCounts(bot);
    if (!inv['stone_pickaxe'] && !inv['iron_pickaxe']) {
        log(bot, 'Collecting cobblestone for stone pickaxe...');
        if (!await collectBlock(bot, 'stone', 3)) {
            log(bot, 'Could not find stone. Try moving to a rocky area.');
            return false;
        }
        if (!await craftRecipe(bot, 'stone_pickaxe', 1)) {
            log(bot, 'Failed to craft stone pickaxe.');
            return false;
        }
        log(bot, 'Stone pickaxe crafted.');
    }

    // ── TIER 3: iron pickaxe ─────────────────────────────────────────────────
    inv = world.getInventoryCounts(bot);
    if (!inv['iron_pickaxe']) {
        log(bot, 'Collecting iron ore for iron pickaxe...');
        let gotIron = await collectBlock(bot, 'iron_ore', 3);
        if (!gotIron) gotIron = await collectBlock(bot, 'deepslate_iron_ore', 3);
        if (!gotIron) {
            log(bot, 'Could not find iron ore. Try digging deeper or exploring caves.');
            return false;
        }
        if (!await smeltItem(bot, 'raw_iron', 3)) {
            log(bot, 'Failed to smelt raw iron into iron ingots.');
            return false;
        }
        if (!await craftRecipe(bot, 'iron_pickaxe', 1)) {
            log(bot, 'Failed to craft iron pickaxe.');
            return false;
        }
        log(bot, 'Iron pickaxe crafted.');
    }

    // ── TIER 4: diamond pickaxe ──────────────────────────────────────────────
    log(bot, 'Digging to diamond level (y=-11)...');
    const targetY = -11;
    const currentY = Math.floor(bot.entity.position.y);
    if (currentY > targetY) {
        const dist = currentY - targetY;
        if (!await digDown(bot, dist)) {
            log(bot, 'Stopped before reaching diamond level (lava or cave gap detected). Try again from a different spot.');
            return false;
        }
    }

    log(bot, 'Searching for diamond ore...');
    let gotDiamonds = await collectBlock(bot, 'deepslate_diamond_ore', 3);
    if (!gotDiamonds) gotDiamonds = await collectBlock(bot, 'diamond_ore', 3);
    if (!gotDiamonds) {
        log(bot, 'No diamond ore found near y=-11. Explore at this depth and try again with !getDiamondPickaxe.');
        return false;
    }

    if (!await craftRecipe(bot, 'diamond_pickaxe', 1)) {
        log(bot, 'Failed to craft diamond pickaxe. Need 3 diamonds + 2 sticks on a crafting table.');
        return false;
    }

    await goToSurface(bot);
    log(bot, 'Diamond pickaxe obtained!');
    return true;
}
```

**Step 3: Lint**

```bash
npm run lint
```

Expected: 0 errors, 0 warnings. Fix any issues before continuing.

**Step 4: Commit**

```bash
git add src/agent/library/skills.js
git commit -m "feat: add getDiamondPickaxe skill — state machine through all 4 tool tiers"
```

---

## Task 2: Add `!getDiamondPickaxe` command to `actions.js`

**Files:**
- Modify: `src/agent/commands/actions.js:520` — insert before the closing `];` on line 521

**Step 1: Open the file and locate the insertion point**

The `actionsList` array ends with `!useOn` closing at line 520, followed by `];` on line 521. Insert the new command between line 520 and 521.

**Step 2: Add the command entry**

Change the end of `actions.js` from:
```javascript
        perform: runAsAction(async (agent, tool_name, target) => {
            await skills.useToolOn(agent.bot, tool_name, target);
        })
    },
];
```

To:
```javascript
        perform: runAsAction(async (agent, tool_name, target) => {
            await skills.useToolOn(agent.bot, tool_name, target);
        })
    },
    {
        name: '!getDiamondPickaxe',
        description: 'Automatically progress through wooden → stone → iron → diamond pickaxe tiers. Detects existing pickaxes and skips already-completed tiers, so it is safe to call multiple times.',
        params: {},
        perform: runAsAction(async (agent) => {
            await skills.getDiamondPickaxe(agent.bot);
        })
    },
];
```

**Step 3: Lint**

```bash
npm run lint
```

Expected: 0 errors, 0 warnings.

**Step 4: Commit**

```bash
git add src/agent/commands/actions.js
git commit -m "feat: add !getDiamondPickaxe command wrapping getDiamondPickaxe skill"
```

---

## Task 3: Manual verification

Since this project has no automated test harness (`npm test` prints "No tests configured"), verification is done by running the bot and issuing the command.

**Step 1: Start a Minecraft instance and connect the bot**

```bash
npm start
```

**Step 2: In Minecraft chat, send:**

```
!getDiamondPickaxe
```

**Expected behaviour:**
- Bot logs progress through each tier it needs to complete
- Bot digs down to y=-11
- Bot mines 3 diamond ore blocks
- Bot returns to surface
- Bot's inventory contains `diamond_pickaxe`
- Final log line: `Diamond pickaxe obtained!`

**Step 3: Re-run to verify idempotency**

Send `!getDiamondPickaxe` again. Expected first log line: `Already have a diamond pickaxe!` with immediate return.

**Step 4: Commit if any fixes were needed during testing**

```bash
git add -p
git commit -m "fix: <describe what needed fixing>"
```

---

## Task 4: Push

```bash
git push
```
