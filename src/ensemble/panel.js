import { selectAPI, createModel } from '../models/_model_map.js';
import { containsCommand } from '../agent/commands/index.js';

/**
 * @typedef {Object} Proposal
 * @property {string} agentId - Panel member ID (e.g., "gemini_a")
 * @property {string} modelName - Model name (e.g., "gemini-2.5-pro")
 * @property {string} response - Raw response string from the model
 * @property {string|null} command - Extracted command (e.g., "!attackEntity") or null
 * @property {string} preCommandText - Text before the first command
 * @property {number} latencyMs - Time taken for this model's response
 * @property {string} status - "success" | "error" | "timeout"
 * @property {string|null} error - Error message if status !== "success"
 * @property {number|null} score - Set by Arbiter
 */

export class Panel {
    /**
     * @param {Array<{id: string, model: string}>} memberConfigs - panel member definitions
     * @param {number} timeoutMs - per-model timeout in ms (default 15000)
     */
    constructor(memberConfigs, timeoutMs = 15000) {
        this.timeoutMs = timeoutMs;
        this.members = [];

        for (const config of memberConfigs) {
            try {
                const profile = selectAPI(config.model);
                const model = createModel(profile);
                this.members.push({
                    id: config.id,
                    model: model,
                    modelName: config.model
                });
                console.log(`[Ensemble Panel] Loaded: ${config.id} → ${config.model}`);
            } catch (err) {
                console.error(`[Ensemble Panel] Failed to load ${config.id} (${config.model}): ${err.message}`);
            }
        }

        if (this.members.length === 0) {
            throw new Error('[Ensemble Panel] No panel members loaded. Check profile.ensemble.panel config.');
        }

        console.log(`[Ensemble Panel] Ready: ${this.members.length} members, ${this.timeoutMs}ms timeout`);
    }

    /**
     * Query all panel members in parallel with timeout.
     * Uses Promise.allSettled — one failure won't block others.
     *
     * @param {Array} turns - conversation turns [{role, content}]
     * @param {string} systemMessage - the system prompt
     * @returns {Promise<Proposal[]>} - all proposals (includes failures)
     */
    async queryAll(turns, systemMessage) {
        const promises = this.members.map(member => this._queryMember(member, turns, systemMessage));
        const results = await Promise.allSettled(promises);

        return results.map((result, i) => {
            if (result.status === 'fulfilled') {
                return result.value;
            }
            // Promise rejected (shouldn't happen since _queryMember catches, but just in case)
            return {
                agentId: this.members[i].id,
                modelName: this.members[i].modelName,
                response: '',
                command: null,
                preCommandText: '',
                latencyMs: this.timeoutMs,
                status: 'error',
                error: result.reason?.message || 'Unknown error',
                score: null
            };
        });
    }

    /**
     * Query a single panel member with timeout protection.
     * @param {Object} member - {id, model, modelName}
     * @param {Array} turns
     * @param {string} systemMessage
     * @returns {Promise<Proposal>}
     */
    async _queryMember(member, turns, systemMessage) {
        const startTime = Date.now();

        const timeoutPromise = new Promise((_, reject) =>
            setTimeout(() => reject(new Error('timeout')), this.timeoutMs)
        );

        try {
            const response = await Promise.race([
                member.model.sendRequest(turns, systemMessage),
                timeoutPromise
            ]);

            const latencyMs = Date.now() - startTime;
            const responseStr = typeof response === 'string' ? response : String(response || '');
            const command = containsCommand(responseStr);

            // Extract text before the command (pre-command reasoning)
            let preCommandText = '';
            if (command) {
                const cmdIndex = responseStr.indexOf(command);
                if (cmdIndex > 0) {
                    preCommandText = responseStr.slice(0, cmdIndex).trim();
                }
            }

            return {
                agentId: member.id,
                modelName: member.modelName,
                response: responseStr,
                command: command,
                preCommandText: preCommandText,
                latencyMs: latencyMs,
                status: 'success',
                error: null,
                score: null
            };
        } catch (err) {
            const latencyMs = Date.now() - startTime;
            const isTimeout = err.message === 'timeout';

            return {
                agentId: member.id,
                modelName: member.modelName,
                response: '',
                command: null,
                preCommandText: '',
                latencyMs: latencyMs,
                status: isTimeout ? 'timeout' : 'error',
                error: err.message,
                score: null
            };
        }
    }
}
