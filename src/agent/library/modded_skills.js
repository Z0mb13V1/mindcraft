/**
 * modded_skills.js — Mod-aware skill functions for Fabric modded servers.
 *
 * These skills extend the base skills.js with awareness of modded blocks,
 * items, and machines. They are only registered when settings.modded_mode
 * is true. All functions gracefully degrade on vanilla servers.
 *
 * Depends on:
 *   - skills.js (base skill primitives)
 *   - world.js (block/entity queries)
 *   - ModdedRegistry (mod detection)
 */

import * as skills from './skills.js';
import * as world from './world.js';

// ═══════════════════════════════════════════════════════════════════════════
// MODDED ORE MINING
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Mine modded ores from installed Fabric mods.
 * Searches for any registered modded ore types and collects them.
 * Falls back to vanilla ore mining if no modded ores are found.
 * @param {Bot} bot - The mineflayer bot instance
 * @param {string} oreType - Specific modded ore ID (e.g., 'create:zinc_ore') or 'any' for closest
 * @param {number} count - Number of ores to mine (default: 1)
 * @returns {Promise<boolean>} true if ores were collected
 **/
export async function mineModdedOre(bot, oreType = 'any', count = 1) {
    const registry = bot._moddedRegistry;
    if (!registry?.enabled) {
        skills.log(bot, 'Modded mode not enabled. Use collectBlock for vanilla ores.');
        return false;
    }

    let targetOres;
    if (oreType === 'any') {
        targetOres = registry.getAllModdedOres();
        if (targetOres.length === 0) {
            skills.log(bot, 'No modded ores registered. Falling back to vanilla mining.');
            return false;
        }
    } else {
        targetOres = [oreType];
    }

    skills.log(bot, `Searching for modded ores: ${targetOres.join(', ')}`);

    // Try each ore type until we find one
    for (const ore of targetOres) {
        // Strip namespace for mineflayer block lookup (e.g., 'create:zinc_ore' → 'zinc_ore')
        const blockName = ore.includes(':') ? ore.split(':')[1] : ore;
        try {
            const nearestBlock = world.getNearestBlock(bot, blockName, 64);
            if (nearestBlock) {
                skills.log(bot, `Found ${ore} at ${nearestBlock.position}`);
                await skills.collectBlock(bot, blockName, count);
                return true;
            }
        } catch {
            // Block type not recognized by this server — skip
            continue;
        }
    }

    skills.log(bot, 'No modded ores found nearby.');
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// MODDED MACHINE INTERACTION
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Interact with a modded machine block (e.g., Create mixer, AE2 inscriber).
 * Navigates to the nearest instance and right-clicks it.
 * @param {Bot} bot - The mineflayer bot instance
 * @param {string} machineId - Full machine block ID (e.g., 'create:mechanical_press')
 * @returns {Promise<boolean>} true if interaction succeeded
 **/
export async function useModdedMachine(bot, machineId) {
    const registry = bot._moddedRegistry;
    if (!registry?.enabled) {
        skills.log(bot, 'Modded mode not enabled.');
        return false;
    }

    const blockName = machineId.includes(':') ? machineId.split(':')[1] : machineId;

    skills.log(bot, `Looking for modded machine: ${machineId}`);

    const machineBlock = world.getNearestBlock(bot, blockName, 32);
    if (!machineBlock) {
        skills.log(bot, `No ${machineId} found within 32 blocks.`);
        return false;
    }

    // Navigate to the machine
    const pos = machineBlock.position;
    await skills.goToPosition(bot, pos.x, pos.y, pos.z, 2);

    // Right-click to interact
    try {
        await bot.activateBlock(machineBlock);
        skills.log(bot, `Interacted with ${machineId} at ${pos}`);
        return true;
    } catch (err) {
        skills.log(bot, `Failed to interact with ${machineId}: ${err.message}`);
        return false;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MODDED SMELTING / PROCESSING
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Use a modded furnace or processing machine to smelt/process items.
 * Tries modded alternatives first (e.g., Create's millstone), falls back to vanilla furnace.
 * @param {Bot} bot - The mineflayer bot instance
 * @param {string} inputItem - Item to process (e.g., 'create:zinc_ore')
 * @param {number} count - Number of items to process (default: 1)
 * @returns {Promise<boolean>} true if processing started
 **/
export async function processModdedItem(bot, inputItem, count = 1) {
    const registry = bot._moddedRegistry;
    if (!registry?.enabled) {
        skills.log(bot, 'Modded mode not enabled. Use smeltItem for vanilla smelting.');
        return false;
    }

    // Check if Create mod is available for alternate processing
    if (registry.hasMod('create')) {
        const millstone = world.getNearestBlock(bot, 'millstone', 32);
        if (millstone) {
            skills.log(bot, `Found Create millstone at ${millstone.position}, attempting processing...`);
            const pos = millstone.position;
            await skills.goToPosition(bot, pos.x, pos.y, pos.z, 2);
            try {
                await bot.activateBlock(millstone);
                skills.log(bot, `Activated millstone for ${inputItem}`);
                return true;
            } catch (err) {
                skills.log(bot, `Millstone interaction failed: ${err.message}. Falling back to furnace.`);
            }
        }
    }

    // Fallback to vanilla furnace
    const itemName = inputItem.includes(':') ? inputItem.split(':')[1] : inputItem;
    skills.log(bot, `Falling back to vanilla smelting for ${itemName}`);
    await skills.smeltItem(bot, itemName, count);
    return true;
}

// ═══════════════════════════════════════════════════════════════════════════
// MOD DETECTION / QUERY SKILLS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Check if a specific mod is available on the server.
 * @param {Bot} bot - The mineflayer bot instance
 * @param {string} modId - Mod identifier to check (e.g., 'create', 'sodium')
 * @returns {Promise<boolean>} true if mod is detected
 **/
export async function checkModAvailable(bot, modId) {
    const registry = bot._moddedRegistry;
    if (!registry?.enabled) {
        skills.log(bot, 'Modded mode not enabled.');
        return false;
    }

    const available = registry.hasMod(modId);
    skills.log(bot, `Mod '${modId}': ${available ? 'AVAILABLE' : 'NOT FOUND'}`);
    return available;
}

/**
 * List all detected mods on the current server.
 * @param {Bot} bot - The mineflayer bot instance
 * @returns {Promise<string[]>} Array of installed mod IDs
 **/
export async function listInstalledMods(bot) {
    const registry = bot._moddedRegistry;
    if (!registry?.enabled) {
        skills.log(bot, 'Modded mode not enabled. Running on vanilla server.');
        return [];
    }

    const mods = registry.getModIds();
    if (mods.length === 0) {
        skills.log(bot, 'No Fabric mods detected in mods directory.');
    } else {
        skills.log(bot, `Installed mods (${mods.length}): ${mods.join(', ')}`);
    }
    return mods;
}

// ═══════════════════════════════════════════════════════════════════════════
// MODDED BLOCK SCANNING
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Scan nearby area for modded blocks (ores, machines) and report findings.
 * Useful for exploration and resource assessment on modded servers.
 * @param {Bot} bot - The mineflayer bot instance
 * @param {number} range - Search radius in blocks (default: 32)
 * @returns {Promise<object>} Map of found modded block types → count
 **/
export async function scanModdedBlocks(bot, range = 32) {
    const registry = bot._moddedRegistry;
    if (!registry?.enabled) {
        skills.log(bot, 'Modded mode not enabled.');
        return {};
    }

    const allTargets = [...registry.getAllModdedOres(), ...registry.getAllModdedMachines()];
    if (allTargets.length === 0) {
        skills.log(bot, 'No modded block types registered to scan for.');
        return {};
    }

    const found = {};
    for (const blockId of allTargets) {
        const blockName = blockId.includes(':') ? blockId.split(':')[1] : blockId;
        try {
            const block = world.getNearestBlock(bot, blockName, range);
            if (block) {
                found[blockId] = (found[blockId] || 0) + 1;
            }
        } catch {
            // Block type not on this server
        }
    }

    if (Object.keys(found).length > 0) {
        const summary = Object.entries(found).map(([k, v]) => `${k}: ${v}`).join(', ');
        skills.log(bot, `Modded blocks found nearby: ${summary}`);
    } else {
        skills.log(bot, 'No modded blocks found in scan range.');
    }

    return found;
}
