/**
 * Simple in-memory rate limiter to prevent abuse
 */

export class RateLimiter {
    constructor(maxRequests = 5, windowMs = 60000) {
        this.maxRequests = maxRequests;  // Max requests per window
        this.windowMs = windowMs;         // Time window in milliseconds
        this.requests = new Map();        // userId → [timestamps]
    }

    /**
     * Check if a user has exceeded rate limit
     * @param {string} userId - Discord user ID
     * @returns {object} { allowed: boolean, retryAfterSeconds?: number }
     */
    checkLimit(userId) {
        const now = Date.now();
        const userRequests = this.requests.get(userId) || [];

        // Remove old requests outside the window
        const recentRequests = userRequests.filter(ts => now - ts < this.windowMs);

        if (recentRequests.length >= this.maxRequests) {
            // Rate limited
            const oldestRequest = recentRequests[0];
            const retryAfterMs = oldestRequest + this.windowMs - now;
            const retryAfterSeconds = Math.ceil(retryAfterMs / 1000);
            return { allowed: false, retryAfterSeconds };
        }

        // Allow and record
        recentRequests.push(now);
        this.requests.set(userId, recentRequests);
        return { allowed: true };
    }

    /**
     * Reset limits for a user (useful for admins)
     */
    reset(userId) {
        this.requests.delete(userId);
    }

    /**
     * Get current stats for a user
     */
    getStats(userId) {
        const now = Date.now();
        const requests = this.requests.get(userId) || [];
        const recentRequests = requests.filter(ts => now - ts < this.windowMs);
        return {
            current: recentRequests.length,
            max: this.maxRequests,
            windowSeconds: this.windowMs / 1000,
        };
    }
}
