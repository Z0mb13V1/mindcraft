import { selectAPI, createModel } from '../models/_model_map.js';

/**
 * LLM-as-Judge: when the heuristic arbiter has low confidence,
 * a fast judge model reviews all proposals and picks the best one.
 */
export class LLMJudge {
    /**
     * @param {Object} config
     * @param {string} config.model - model name to use as judge (e.g. "gemini-2.5-flash")
     * @param {number} config.timeout_ms - max ms to wait for judge (default 10000)
     */
    constructor(config = {}) {
        this.modelName = config.model || 'gemini-2.5-flash';
        this.timeoutMs = config.timeout_ms || 10000;
        this._model = null;
    }

    _getModel() {
        if (!this._model) {
            const profile = selectAPI(this.modelName);
            this._model = createModel(profile);
        }
        return this._model;
    }

    /**
     * Ask the judge to pick the best proposal.
     * @param {Proposal[]} proposals - successful proposals only
     * @param {string} systemMessage - the original system prompt (abbreviated)
     * @param {Array} turns - last few conversation turns for context
     * @returns {Promise<string|null>} winning agentId, or null if judge fails
     */
    async judge(proposals, systemMessage, turns) {
        if (proposals.length === 0) return null;
        if (proposals.length === 1) return proposals[0].agentId;

        const model = this._getModel();

        // Build a concise judgment prompt
        const lastUserMsg = [...turns].reverse().find(t => t.role === 'user')?.content || '';

        const proposalText = proposals.map((p, i) =>
            `[${p.agentId}] (${p.modelName})\n${p.response}`
        ).join('\n\n---\n\n');

        const judgeSystem = [
            'You are an expert judge evaluating Minecraft bot AI responses.',
            'Pick the SINGLE best response for the current game situation.',
            'Consider: command correctness, relevance to context, clarity, and safety.',
            'Respond with ONLY the agent ID (e.g. "gemini_a"). No explanation.'
        ].join('\n');

        const judgePrompt = [
            `Current situation: ${lastUserMsg.slice(0, 300)}`,
            '',
            'Responses to evaluate:',
            proposalText,
            '',
            `Valid agent IDs: ${proposals.map(p => p.agentId).join(', ')}`,
            'Which response is best? Reply with only the agent ID.'
        ].join('\n');

        const judgeTurns = [{ role: 'user', content: judgePrompt }];

        try {
            const result = await Promise.race([
                model.sendRequest(judgeTurns, judgeSystem),
                new Promise((_, reject) =>
                    setTimeout(() => reject(new Error('judge timeout')), this.timeoutMs)
                )
            ]);

            // Parse: extract first matching agent ID from the response
            const validIds = proposals.map(p => p.agentId);
            for (const id of validIds) {
                if (result.includes(id)) return id;
            }

            console.warn(`[Judge] Could not parse agent ID from response: "${result.slice(0, 100)}"`);
            return null;
        } catch (err) {
            console.warn(`[Judge] Failed: ${err.message}`);
            return null;
        }
    }
}
