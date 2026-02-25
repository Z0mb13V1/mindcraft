/**
 * Phase 1 stub — records ensemble decision outcomes.
 * Phase 3 will connect this to ChromaDB for vector memory / continuous learning.
 */
export class FeedbackCollector {
    constructor() {
        this.pending = null;
    }

    /**
     * Called after arbitration — record which decision was made.
     * @param {Object} decision - { winner, proposals, timestamp }
     */
    recordDecision(decision) {
        this.pending = decision;
    }

    /**
     * Called after action execution — record what happened.
     * @param {string} outcome - "success" | "fail"
     * @param {string} details - execution result text
     */
    recordOutcome(outcome, details) {
        if (this.pending) {
            const winnerId = this.pending.winner?.agentId || 'unknown';
            const command = this.pending.winner?.command || 'none';
            console.log(`[Ensemble Feedback] ${winnerId} → ${command} → ${outcome}`);
            this.pending = null;
        }
    }
}
