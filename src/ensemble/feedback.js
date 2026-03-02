import { ChromaClient } from 'chromadb';

const COLLECTION_NAME = 'ensemble_memory';
const CHROMADB_URL = process.env.CHROMADB_URL || 'http://localhost:8000';

/** Ensure embedding is a flat array of numbers */
function flattenEmbedding(raw) {
    if (!raw) return null;
    // Already a flat number array
    if (Array.isArray(raw) && (raw.length === 0 || typeof raw[0] === 'number')) return raw;
    // Array of objects with values (e.g. [{values:[...]}])
    if (Array.isArray(raw) && raw[0]?.values) return raw[0].values;
    // Object with values
    if (raw.values && Array.isArray(raw.values)) return raw.values;
    // Object with embedding.values
    if (raw.embedding?.values) return raw.embedding.values;
    return null;
}

export class FeedbackCollector {
    constructor() {
        this._client = null;
        this._collection = null;
        this._ready = false;
        this._embedFn = null;
        this._decisionCount = 0;
        this._lastDecisionId = null;
        this._initAsync();
    }

    setEmbeddingModel(model) {
        this._embedFn = async (text) => {
            const raw = await model.embed(text);
            return flattenEmbedding(raw);
        };
    }

    async _initAsync() {
        try {
            this._client = new ChromaClient({ path: CHROMADB_URL });
            this._collection = await this._client.getOrCreateCollection({
                name: COLLECTION_NAME,
                metadata: { 'hnsw:space': 'cosine' }
            });
            this._ready = true;
            console.log(`[Feedback] ChromaDB ready at ${CHROMADB_URL}, collection: ${COLLECTION_NAME}`);
        } catch (err) {
            console.warn(`[Feedback] ChromaDB unavailable (${err.message}). Running without vector memory.`);
            this._ready = false;
        }
    }

    async recordDecision(decision) {
        if (!this._ready || !this._embedFn) return;

        // Hoist variables so the catch block can access them for retry
        let id = null;
        let cleanEmb = null;
        let text = '';
        let meta = null;

        try {
            const { winner, proposals, situationText } = decision;
            text = situationText || '';
            if (text.trim().length < 5) return;

            const embedding = await this._embedFn(text.slice(0, 512));
            if (!embedding || !Array.isArray(embedding) || embedding.length === 0) {
                console.warn('[Feedback] Invalid embedding, skipping storage');
                return;
            }
            // Ensure all values are numbers
            cleanEmb = embedding.map(v => Number(v));
            if (cleanEmb.some(v => !isFinite(v))) {
                console.warn('[Feedback] Embedding contains non-finite values, skipping');
                return;
            }

            this._decisionCount++;
            const ts = Date.now();
            id = 'dec_' + ts + '_' + this._decisionCount;
            this._lastDecisionId = id;

            const successful = proposals.filter(p => p.status === 'success');
            const rawCmd = winner.command;
            const rawScore = winner.score;

            meta = {
                winner_id: String(winner.agentId || 'unknown'),
                winner_command: (rawCmd && typeof rawCmd === 'string') ? rawCmd : '',
                winner_score: (typeof rawScore === 'number' && isFinite(rawScore)) ? rawScore : 0,
                win_reason: String(winner.winReason || 'highest_score'),
                panel_size: Number(proposals.length),
                responders: Number(successful.length),
                timestamp: Number(ts),
                outcome: 'pending'
            };

            await this._collection.add({
                ids: [id],
                embeddings: [cleanEmb],
                documents: [text.slice(0, 512)],
                metadatas: [meta]
            });
            console.log('[Feedback] Decision stored in ChromaDB:', id);
        } catch (err) {
            if (err.message?.includes('already exists')) {
                // Skip duplicate IDs
            } else if (err.message?.includes('dimension') || err.message?.includes('shape') || err.message?.includes('mismatch')) {
                // Dimension mismatch: delete and recreate collection
                console.warn('[Feedback] Embedding dimension mismatch, recreating collection');
                try {
                    if (!this._client) throw new Error('ChromaDB client is null');
                    await this._client.deleteCollection({ name: COLLECTION_NAME });
                    this._collection = await this._client.createCollection({
                        name: COLLECTION_NAME,
                        metadata: { 'hnsw:space': 'cosine' }
                    });
                    // Retry the add
                    await this._collection.add({
                        ids: [id],
                        embeddings: [cleanEmb],
                        documents: [text.slice(0, 512)],
                        metadatas: [meta]
                    });
                    console.log('[Feedback] Decision stored after collection recreation:', id);
                } catch (retryErr) {
                    console.warn('[Feedback] Failed to recreate collection and store decision:', retryErr.message);
                }
            } else {
                console.warn('[Feedback] Failed to record decision:', err.message);
            }
        }
    }

    async recordOutcome(outcome, details) {
        if (!this._ready || !this._lastDecisionId) return;
        try {
            await this._collection.update({
                ids: [this._lastDecisionId],
                metadatas: [{ outcome: String(outcome), outcome_detail: String(details || '').slice(0, 200) }]
            });
        } catch (err) {
            console.warn('[Feedback] Failed to update outcome:', err.message);
        }
    }

    async getSimilar(situationText, topK) {
        if (!this._ready || !this._embedFn) return [];
        if (!situationText || situationText.trim().length < 5) return [];
        try {
            const k = topK || 3;
            const embedding = await this._embedFn(situationText.slice(0, 512));
            if (!embedding || !Array.isArray(embedding)) return [];
            const cleanEmb = embedding.map(v => Number(v));

            const results = await this._collection.query({
                queryEmbeddings: [cleanEmb],
                nResults: Math.min(k, 10),
                include: ['documents', 'metadatas', 'distances']
            });

            const docs = results.documents?.[0] || [];
            const metas = results.metadatas?.[0] || [];
            const dists = results.distances?.[0] || [];

            return docs.map((doc, i) => ({
                document: doc,
                metadata: metas[i] || {},
                similarity: 1 - (dists[i] || 0)
            })).filter(r => r.similarity > 0.6);
        } catch (err) {
            console.warn('[Feedback] Failed to query similar:', err.message);
            return [];
        }
    }

    get isReady() { return this._ready; }
}
