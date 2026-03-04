import { writeFile, readFile, mkdir } from 'fs/promises';
import { existsSync } from 'fs';
import path from 'path';

const MAX_ENTRIES = 500;
const TRIM_TO = 400;

export class EnsembleLogger {
    constructor(agentName) {
        this.agentName = agentName;
        this.dir = `./bots/${agentName}`;
        this.filePath = path.join(this.dir, 'ensemble_log.json');
        this.decisionCount = 0;

        this._ready = !existsSync(this.dir)
            ? mkdir(this.dir, { recursive: true })
            : Promise.resolve();
    }

    async logDecision(allProposals, winner) {
        this.decisionCount++;

        const successful = allProposals.filter(p => p.status === 'success');
        const commands = successful.map(p => p.command).filter(Boolean);
        const uniqueCommands = [...new Set(commands)];
        const agreement = uniqueCommands.length <= 1 && commands.length > 0
            ? 1.0
            : commands.length > 0
                ? Math.max(...uniqueCommands.map(c => commands.filter(x => x === c).length)) / commands.length
                : 0;

        const entry = {
            timestamp: new Date().toISOString(),
            decision_id: this.decisionCount,
            proposals: allProposals.map(p => ({
                agent_id: p.agentId,
                model: p.modelName,
                status: p.status,
                command: p.command || null,
                pre_text: p.preCommandText ? p.preCommandText.slice(0, 100) : '',
                score: p.score ?? null,
                latency_ms: p.latencyMs,
                error: p.error || null
            })),
            winner: winner ? {
                agent_id: winner.agentId,
                command: winner.command,
                score: winner.score,
                reason: winner.winReason || 'highest_score'
            } : null,
            majority_command: this._findMajority(commands),
            panel_agreement: Math.round(agreement * 100) / 100
        };

        await this._ready;
        let log = await this._readLog();
        log.push(entry);

        if (log.length > MAX_ENTRIES) {
            log = log.slice(log.length - TRIM_TO);
        }

        try {
            await writeFile(this.filePath, JSON.stringify(log, null, 2));
        } catch (err) {
            console.error(`[Ensemble] Failed to write log: ${err.message}`);
        }
    }

    async getStats() {
        const log = await this._readLog();
        const wins = {};
        let totalLatency = 0;
        let latencyCount = 0;

        for (const entry of log) {
            if (entry.winner?.agent_id) {
                wins[entry.winner.agent_id] = (wins[entry.winner.agent_id] || 0) + 1;
            }
            for (const p of entry.proposals) {
                if (p.status === 'success' && p.latency_ms) {
                    totalLatency += p.latency_ms;
                    latencyCount++;
                }
            }
        }

        return {
            total_decisions: log.length,
            per_member_wins: wins,
            avg_latency_ms: latencyCount > 0 ? Math.round(totalLatency / latencyCount) : 0
        };
    }

    async _readLog() {
        try {
            const raw = await readFile(this.filePath, 'utf8');
            return JSON.parse(raw);
        } catch {
            // file missing or corrupted — start fresh
        }
        return [];
    }

    _findMajority(commands) {
        if (commands.length === 0) return null;
        const counts = {};
        for (const c of commands) {
            counts[c] = (counts[c] || 0) + 1;
        }
        const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1]);
        return sorted[0][1] > 1 ? sorted[0][0] : null;
    }
}
