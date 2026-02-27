import { Panel } from './panel.js';
import { Arbiter } from './arbiter.js';
import { LLMJudge } from './judge.js';
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
    static prefix = 'ensemble';

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
        this.judge = ensembleConfig.judge !== false
            ? new LLMJudge(ensembleConfig.judge || {})
            : null;
        this.logger = new EnsembleLogger(profile.name);
        this.feedback = new FeedbackCollector();

        this.minResponses = ensembleConfig.min_responses || 2;
        this.logDecisions = ensembleConfig.log_decisions !== false;

        // Usage tracking compatibility (Prompter reads this after each call)
        this._lastUsage = null;
        this._lastUsageByModel = null;

        console.log(`[Ensemble] Initialized for ${profile.name}: ${this.panel.members.length} panel members`);
    }

    /**
     * Phase 3: inject the shared embedding model into FeedbackCollector.
     * Called by Prompter after both chat_model and embedding_model are ready.
     */
    setEmbeddingModel(embeddingModel) {
        this.feedback.setEmbeddingModel(embeddingModel);
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

        // Phase 3: retrieve similar past experiences to augment context
        let augmentedSystem = systemMessage;
        if (this.feedback.isReady) {
            const situationText = turns.filter(t => t.role === 'user').slice(-2)
                .map(t => t.content).join(' ');
            const experiences = await this.feedback.getSimilar(situationText, 3);
            if (experiences.length > 0) {
                const memBlock = experiences.map(e => {
                    const m = e.metadata;
                    const outcome = m.outcome && m.outcome !== 'pending' ? ` (outcome: ${m.outcome})` : '';
                    return `- Situation: "${e.document.slice(0, 120)}" → action: ${m.winner_command || 'chat'}${outcome}`;
                }).join('\n');
                augmentedSystem = systemMessage + `\n\n[PAST EXPERIENCE - similar situations]\n${memBlock}`;
                console.log(`[Ensemble] Injected ${experiences.length} past experience(s) into context`);
            }
        }

        // Query all panel members in parallel
        const proposals = await this.panel.queryAll(turns, augmentedSystem);

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

        // Heuristic arbiter — always runs first
        let winner = this.arbiter.pick(proposals);
        let judgeUsed = false;

        // Phase 2: LLM judge fallback when heuristic confidence is low
        if (this.judge && this.arbiter.isLowConfidence() && successful.length >= 2) {
            console.log(`[Ensemble] Low confidence (margin=${this.arbiter._lastConfidence.toFixed(3)}), consulting LLM judge...`);
            try {
                const judgeId = await this.judge.judge(successful, systemMessage, turns);
                if (judgeId) {
                    const judgeWinner = successful.find(p => p.agentId === judgeId);
                    if (judgeWinner) {
                        judgeWinner.winReason = 'llm_judge';
                        winner = judgeWinner;
                        judgeUsed = true;
                        console.log(`[Ensemble] Judge overruled heuristic: winner=${judgeId}`);
                    }
                }
            } catch (err) {
                console.warn(`[Ensemble] Judge error, keeping heuristic winner: ${err.message}`);
            }
        }

        const totalMs = Date.now() - startTime;
        console.log(
            `[Ensemble] Decision in ${totalMs}ms: ` +
            `${successful.length}/${this.panel.members.length} responded, ` +
            `winner=${winner.agentId} (${winner.command || 'chat'}, score=${winner.score?.toFixed(2)})` +
            (judgeUsed ? ' [judge]' : '')
        );

        // Log decision
        if (this.logDecisions) {
            this.logger.logDecision(proposals, winner);
        }

        // Phase 3: Record decision in ChromaDB for continuous learning
        const situationText = turns.filter(t => t.role === 'user').slice(-2)
            .map(t => t.content).join(' ');
        this.feedback.recordDecision({
            winner,
            proposals,
            timestamp: Date.now(),
            situationText
        });

        // Aggregate usage from all successful members
        this._lastUsage = this._aggregateUsage(successful);
        this._lastUsageByModel = this._buildUsageBreakdown(successful);

        return winner.response;
    }

    /**
     * Embeddings are not supported by the ensemble — the Prompter uses
     * a separate embedding model configured in the profile.
     */
    async embed(_text) {
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

    _buildUsageBreakdown(proposals) {
        const breakdown = [];
        for (const p of proposals) {
            if (!p.usage) continue;
            breakdown.push({
                modelName: p.modelName || 'unknown',
                provider: p.provider || 'unknown',
                usage: p.usage
            });
        }
        return breakdown.length > 0 ? breakdown : null;
    }
}
