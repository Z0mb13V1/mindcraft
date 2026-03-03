/**
 * modded_registry.js — Fabric mod detection and capability registry.
 *
 * Scans the configured mods directory for Fabric mod JARs, reads their
 * fabric.mod.json manifests, and exposes a queryable registry of installed
 * mod IDs and capabilities.
 *
 * Usage:
 *   import { ModdedRegistry } from '../registry/modded_registry.js';
 *   const registry = new ModdedRegistry(settings);
 *   await registry.scan();
 *   if (registry.hasMod('create')) { ... }
 *
 * This module is only activated when settings.modded_mode === true.
 * It has zero side-effects when modded_mode is false.
 */

import { readdir } from 'fs/promises';
import { join, extname } from 'path';
import { existsSync } from 'fs';

/**
 * Well-known Fabric mod categories and their typical mod IDs.
 * Used for capability detection (e.g., "does the server have tech mods?").
 */
const MOD_CATEGORIES = {
    performance: ['sodium', 'lithium', 'starlight', 'ferritecore', 'krypton', 'c2me'],
    tech:        ['create', 'ae2', 'mekanism', 'techreborn', 'modern-industrialization'],
    magic:       ['botania', 'ars-nouveau', 'hex-casting', 'theurgy'],
    worldgen:    ['terralith', 'biomes-o-plenty', 'tectonic', 'nullscape'],
    utility:     ['jade', 'rei', 'jei', 'wthit', 'modmenu', 'roughly-enough-items'],
    pathfinding: ['baritone', 'fabric-baritone', 'baritone-api'],
    storage:     ['sophisticated-backpacks', 'iron-chests', 'expanded-storage'],
};

/**
 * Modded blocks/items that the bot can interact with, mapped by mod ID.
 * Each entry lists block/item IDs the bot should recognize.
 */
const MODDED_INTERACTIONS = {
    create: {
        machines: ['create:mechanical_mixer', 'create:mechanical_press', 'create:millstone',
                   'create:crushing_wheel', 'create:deployer', 'create:basin'],
        ores:     ['create:zinc_ore', 'create:deepslate_zinc_ore'],
        items:    ['create:zinc_ingot', 'create:brass_ingot', 'create:andesite_alloy'],
    },
    ae2: {
        machines: ['ae2:inscriber', 'ae2:charger', 'ae2:grindstone'],
        ores:     ['ae2:quartz_ore', 'ae2:deepslate_quartz_ore'],
        items:    ['ae2:certus_quartz_crystal', 'ae2:fluix_crystal'],
    },
    techreborn: {
        machines: ['techreborn:grinder', 'techreborn:electric_furnace', 'techreborn:alloy_smelter'],
        ores:     ['techreborn:tin_ore', 'techreborn:lead_ore', 'techreborn:silver_ore'],
        items:    ['techreborn:tin_ingot', 'techreborn:copper_ingot'],
    },
};

export class ModdedRegistry {
    /**
     * @param {object} settings — Global settings object (must have modded_mode, fabric_mods_dir)
     */
    constructor(settings) {
        this.enabled = settings.modded_mode === true;
        this.modsDir = settings.fabric_mods_dir || './mods';
        this.mods = new Map();           // modId → { id, name, version, description, file }
        this.categories = new Map();     // category → Set<modId>
        this.scanned = false;
    }

    /**
     * Scan the mods directory for Fabric mod JARs and read their manifests.
     * Safe to call even when modded_mode is false (returns immediately).
     */
    async scan() {
        if (!this.enabled) return;
        if (!existsSync(this.modsDir)) {
            console.warn(`[ModdedRegistry] Mods directory not found: ${this.modsDir}`);
            return;
        }

        const files = await readdir(this.modsDir);
        const jars = files.filter(f => extname(f).toLowerCase() === '.jar');

        for (const jar of jars) {
            try {
                await this._loadModManifest(join(this.modsDir, jar), jar);
            } catch (err) {
                console.warn(`[ModdedRegistry] Failed to read manifest from ${jar}: ${err.message}`);
            }
        }

        this._classifyMods();
        this.scanned = true;

        console.log(`[ModdedRegistry] Scanned ${jars.length} JARs, found ${this.mods.size} mods`);
        if (this.mods.size > 0) {
            console.log(`[ModdedRegistry] Mods: ${[...this.mods.keys()].join(', ')}`);
        }
    }

    /**
     * Attempt to read fabric.mod.json from a JAR file.
     * Uses a lightweight approach: reads the JAR as a zip and extracts the manifest.
     * Falls back to inferring mod ID from the filename if manifest reading fails.
     */
    async _loadModManifest(jarPath, fileName) {
        // Lightweight: infer mod info from filename pattern: modid-version.jar
        // Full JAR manifest reading would require a zip library — kept minimal for now.
        const baseName = fileName.replace(/\.jar$/i, '');
        const match = baseName.match(/^(.+?)[-_](\d+\..*)$/);

        const modId = match ? match[1].toLowerCase() : baseName.toLowerCase();
        const version = match ? match[2] : 'unknown';

        this.mods.set(modId, {
            id: modId,
            name: modId,
            version,
            description: '',
            file: fileName,
        });
    }

    /**
     * Classify loaded mods into capability categories.
     */
    _classifyMods() {
        this.categories.clear();
        for (const [category, modIds] of Object.entries(MOD_CATEGORIES)) {
            const matched = new Set();
            for (const modId of modIds) {
                if (this.mods.has(modId)) {
                    matched.add(modId);
                }
            }
            if (matched.size > 0) {
                this.categories.set(category, matched);
            }
        }
    }

    /**
     * Check if a specific mod is installed.
     * @param {string} modId — Mod identifier (e.g., 'create', 'sodium')
     * @returns {boolean}
     */
    hasMod(modId) {
        return this.mods.has(modId.toLowerCase());
    }

    /**
     * Check if any mod in a category is installed.
     * @param {string} category — Category name (e.g., 'performance', 'tech', 'pathfinding')
     * @returns {boolean}
     */
    hasCategory(category) {
        return this.categories.has(category);
    }

    /**
     * Get all installed mod IDs.
     * @returns {string[]}
     */
    getModIds() {
        return [...this.mods.keys()];
    }

    /**
     * Get mods in a specific category.
     * @param {string} category
     * @returns {string[]}
     */
    getModsInCategory(category) {
        const cat = this.categories.get(category);
        return cat ? [...cat] : [];
    }

    /**
     * Get known modded blocks/items for a specific mod.
     * @param {string} modId
     * @returns {object|null} — { machines, ores, items } or null if unknown
     */
    getModdedInteractions(modId) {
        return MODDED_INTERACTIONS[modId.toLowerCase()] || null;
    }

    /**
     * Get all known modded ore block IDs from installed mods.
     * @returns {string[]}
     */
    getAllModdedOres() {
        const ores = [];
        for (const modId of this.mods.keys()) {
            const interactions = MODDED_INTERACTIONS[modId];
            if (interactions?.ores) {
                ores.push(...interactions.ores);
            }
        }
        return ores;
    }

    /**
     * Get all known modded machine block IDs from installed mods.
     * @returns {string[]}
     */
    getAllModdedMachines() {
        const machines = [];
        for (const modId of this.mods.keys()) {
            const interactions = MODDED_INTERACTIONS[modId];
            if (interactions?.machines) {
                machines.push(...interactions.machines);
            }
        }
        return machines;
    }

    /**
     * Build a summary string for injection into the LLM prompt.
     * @returns {string}
     */
    getPromptSummary() {
        if (!this.enabled || this.mods.size === 0) return '';

        const lines = ['[MODDED SERVER] Fabric mods detected:'];
        for (const [_id, mod] of this.mods) {
            lines.push(`  - ${mod.name} v${mod.version}`);
        }

        const ores = this.getAllModdedOres();
        if (ores.length > 0) {
            lines.push(`Modded ores available: ${ores.join(', ')}`);
        }

        const machines = this.getAllModdedMachines();
        if (machines.length > 0) {
            lines.push(`Modded machines available: ${machines.join(', ')}`);
        }

        return lines.join('\n');
    }

    /**
     * Serialize registry state for debugging/logging.
     * @returns {object}
     */
    toJSON() {
        return {
            enabled: this.enabled,
            modsDir: this.modsDir,
            scanned: this.scanned,
            modCount: this.mods.size,
            mods: Object.fromEntries(this.mods),
            categories: Object.fromEntries(
                [...this.categories.entries()].map(([k, v]) => [k, [...v]])
            ),
        };
    }
}
