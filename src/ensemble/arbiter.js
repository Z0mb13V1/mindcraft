import { commandExists } from '../agent/commands/index.js';

export class Arbiter {
    /**
     * @param {Object} config
     * @param {string} config.strategy - "heuristic" (Phase 1) or "llm_judge" (Phase 2)
     * @param {number} config.majority_bonus - score boost for majority command (default 0.2)
     * @param {number} config.latency_penalty_per_sec - penalty per second of latency (default 0.02)
     */
    constructor(config = {}) {
        this.strategy = config.strategy || 'heuristic';
        this.majorityBonus = config.majority_bonus ?? 0.2;
        this.latencyPenalty = config.latency_penalty_per_sec ?? 0.02;
        this._confidenceThreshold = config.confidence_threshold ?? 0.08;
        this._lastConfidence = 1.0;  // set after each pick()
    }

    /**
     * Confidence threshold for triggering LLM judge.
     * If top 2 scores are within this margin, it's "low confidence".
     */
    get confidenceThreshold() {
        return this._confidenceThreshold ?? 0.08;
    }

    /**
     * Pick the best proposal from the panel's responses.
     * Also sets `this._lastConfidence` for the controller to check.
     * @param {Proposal[]} proposals - all proposals (may include failures)
     * @returns {Proposal} - the winning proposal with `score` and `winReason` set
     */
    pick(proposals) {
        const successful = proposals.filter(p => p.status === 'success');

        if (successful.length === 0) {
            return {
                agentId: 'none',
                modelName: 'none',
                response: "I'm having trouble thinking right now. Let me try again in a moment.",
                command: null,
                commandArgs: null,
                preCommandText: '',
                latencyMs: 0,
                status: 'error',
                error: 'All panel members failed',
                score: 0,
                winReason: 'fallback'
            };
        }

        // Score each proposal
        for (const p of successful) {
            p.score = this._scoreProposal(p);
        }

        // Find majority command and apply bonus
        const majorityCommand = this._findMajorityCommand(successful);
        if (majorityCommand) {
            for (const p of successful) {
                if (p.command === majorityCommand) {
                    p.score += this.majorityBonus;
                }
            }
        }

        // Apply latency penalty (tiebreaker)
        for (const p of successful) {
            p.score -= this.latencyPenalty * (p.latencyMs / 1000);
        }

        // Sort: highest score first, then fastest (lowest latency)
        successful.sort((a, b) => {
            if (Math.abs(b.score - a.score) > 0.001) return b.score - a.score;
            return a.latencyMs - b.latencyMs;
        });

        const winner = successful[0];
        winner.winReason = majorityCommand && winner.command === majorityCommand
            ? 'majority+highest_score'
            : 'highest_score';

        // Compute confidence: margin between top 2 scores
        this._lastConfidence = successful.length >= 2
            ? successful[0].score - successful[1].score
            : 1.0;

        return winner;
    }

    /**
     * Returns true if the last pick() result had low confidence
     * and an LLM judge should be consulted.
     */
    isLowConfidence() {
        return this._lastConfidence < this._confidenceThreshold;
    }

    /**
     * Compute heuristic score for a proposal.
     * @param {Proposal} proposal
     * @returns {number} score between 0.0 and ~1.0
     */
    _scoreProposal(proposal) {
        let score = 0;
        const r = proposal.response || '';

        // Non-empty response
        if (r.trim().length > 0) score += 0.10;

        // Contains a command
        if (proposal.command) score += 0.25;

        // Command exists in the game's registry
        if (proposal.command && commandExists(proposal.command)) score += 0.15;

        // No hallucination markers
        const hallucinations = ['(FROM OTHER BOT)', 'My brain disconnected', 'Error:'];
        if (!hallucinations.some(h => r.includes(h))) score += 0.15;

        // Reasonable length (not too short, not too long)
        if (r.length > 5 && r.length < 2000) score += 0.10;

        // Not a tab-only or whitespace-only response
        if (r.trim().length > 1) score += 0.10;

        // Has pre-command reasoning text (shows the model "thought")
        if (proposal.preCommandText && proposal.preCommandText.trim().length > 0) score += 0.05;

        // Response contains actual content words (not just a command)
        if (r.replace(/![a-zA-Z]+\(.*?\)/g, '').trim().length > 3) score += 0.10;

        return score;
    }

    /**
     * Find the command that appears most among proposals.
     * @param {Proposal[]} proposals - successful proposals only
     * @returns {string|null} majority command or null
     */
    _findMajorityCommand(proposals) {
        const commands = proposals.map(p => p.command).filter(Boolean);
        if (commands.length === 0) return null;

        const counts = {};
        for (const c of commands) {
            counts[c] = (counts[c] || 0) + 1;
        }

        const sorted = Object.entries(counts).sort((a, b) => b[1] - a[1]);
        // Majority: top command appears more than once AND strictly more than runner-up
        if (sorted[0][1] > 1 && (sorted.length === 1 || sorted[0][1] > sorted[1][1])) {
            return sorted[0][0];
        }
        return null;
    }
}
