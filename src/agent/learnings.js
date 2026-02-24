import { writeFileSync, readFileSync, mkdirSync, existsSync } from 'fs';
import path from 'path';

const MAX_ENTRIES = 100;

export class Learnings {
    constructor(agentName) {
        this.agentName = agentName;
        this.filePath = `./bots/${agentName}/learnings.json`;
        this.entries = [];
        this._dirty = false;
    }

    load() {
        try {
            if (!existsSync(this.filePath)) return;
            const raw = readFileSync(this.filePath, 'utf8');
            this.entries = JSON.parse(raw);
            if (!Array.isArray(this.entries)) this.entries = [];
            console.log(`[Learnings] Loaded ${this.entries.length} entries for ${this.agentName}`);
        } catch (err) {
            console.error(`[Learnings] Failed to load for ${this.agentName}:`, err.message);
            this.entries = [];
        }
    }

    save() {
        if (!this._dirty) return;
        try {
            const dir = path.dirname(this.filePath);
            mkdirSync(dir, { recursive: true });
            writeFileSync(this.filePath, JSON.stringify(this.entries, null, 2));
            this._dirty = false;
        } catch (err) {
            console.error(`[Learnings] Save failed for ${this.agentName}:`, err.message);
        }
    }

    record(command, context, outcome) {
        this.entries.push({
            command,
            context: context.substring(0, 100),
            outcome, // 'success' or 'fail'
            timestamp: new Date().toISOString(),
        });

        // Prune oldest if over limit
        if (this.entries.length > MAX_ENTRIES) {
            this.entries = this.entries.slice(-MAX_ENTRIES);
        }

        this._dirty = true;
    }

    getRecentSummary(count = 10) {
        const recent = this.entries.slice(-count);
        if (recent.length === 0) return '';
        return recent.map(e => {
            const icon = e.outcome === 'success' ? '+' : '-';
            return `[${icon}] ${e.command}: ${e.context}`;
        }).join('\n');
    }

    getStats() {
        const total = this.entries.length;
        const successes = this.entries.filter(e => e.outcome === 'success').length;
        const failures = total - successes;
        return { total, successes, failures };
    }
}
