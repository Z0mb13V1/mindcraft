import { Panel } from './panel.js';
import { Arbiter } from './arbiter.js';
import { EnsembleLogger } from './logger.js';
import { FeedbackCollector } from './feedback.js';

/**
 * EnsembleModel — implements the same interface as any single model class
 * (Gemini, Grok, etc.) so it can be used as a drop-in replacement for chat_model
 * in the Prompter class.
 *
 * Instead of a single LLM call, it queries a panel of models in parallel,
 * runs an arbiter to pick the best response, and returns the winning string.
 */
export class EnsembleModel {
    /**
     * @param {Object} ensembleConfig - the profile.ensemble configuration block
     * @param {Object} profile - the full bot profile (for context/name)
     */
    constructor(ensembleConfig, profile) {
        this.model_name = 'ensemble';
        this.profile = profile;

        this.panel = new Panel(
            ensembleConfig.panel,
            ensembleConfig.timeout_ms || 15000
        );
        this.arbiter = new Arbiter(ensembleConfig.arbiter || {});
        this.logger = new EnsembleLogger(profile.name);
        this.feedback = new FeedbackCollector();

        this.minResponses = ensembleConfig.min_responses || 2;
        this.logDecisions = ensembleConfig.log_decisions !== false;

        // Usage tracking compatibility (Prompter reads this after each call)
        this._lastUsage = null;

        console.log(`[Ensemble] Initialized for ${profile.name}: ${this.panel.members.length} panel members`);
    }

    /**
     * Standard model interface — called by Prompter.promptConvo().
     * Queries all panel members, arbitrates, returns winning response.
     *
     * @param {Array<{role:string, content:string}>} turns - conversation history
     * @param {string} systemMessage - the built system prompt
     * @returns {Promise<string>} - the winning response text
     */
    async sendRequest(turns, systemMessage) {
        const startTime = Date.now();

        // Query all panel members in parallel
        const proposals = await this.panel.queryAll(turns, systemMessage);

        const successful = proposals.filter(p => p.status === 'success');
        const failed = proposals.filter(p => p.status !== 'success');

        if (failed.length > 0) {
            const failSummary = failed.map(p => `${p.agentId}:${p.status}`).join(', ');
            console.log(`[Ensemble] Panel failures: ${failSummary}`);
        }

        if (successful.length < this.minResponses) {
            console.warn(`[Ensemble] Only ${successful.length}/${this.panel.members.length} responses (need ${this.minResponses})`);
            if (successful.length === 0) {
                this._lastUsage = null;
                return "I'm having trouble processing right now. Let me try again.";
            }
        }

        // Arbiter picks the winning proposal
        const winner = this.arbiter.pick(proposals);

        const totalMs = Date.now() - startTime;
        console.log(
            `[Ensemble] Decision in ${totalMs}ms: ` +
            `${successful.length}/${this.panel.members.length} responded, ` +
            `winner=${winner.agentId} (${winner.command || 'chat'}, score=${winner.score?.toFixed(2)})`
        );

        // Log decision
        if (this.logDecisions) {
            this.logger.logDecision(proposals, winner);
        }

        // Record for feedback (Phase 1 stub)
        this.feedback.recordDecision({
            winner,
            proposals,
            timestamp: Date.now()
        });

        // Aggregate usage from all successful members
        this._lastUsage = this._aggregateUsage(successful);

        return winner.response;
    }

    /**
     * Embeddings are not supported by the ensemble — the Prompter uses
     * a separate embedding model configured in the profile.
     */
    async embed(text) {
        throw new Error('Embeddings not supported by EnsembleModel. Configure a separate embedding model in the profile.');
    }

    /**
     * Sum token usage across all panel members for cost tracking.
     */
    _aggregateUsage(proposals) {
        let prompt = 0, completion = 0;
        for (const p of proposals) {
            if (p.usage) {
                prompt += p.usage.prompt_tokens || 0;
                completion += p.usage.completion_tokens || 0;
            }
        }
        if (prompt === 0 && completion === 0) return null;
        return { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion };
    }
}
