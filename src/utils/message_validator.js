/**
 * Validates and sanitizes user messages for safety.
 * Prevents protocol exploits, injection attacks, and abuse.
 */

const MAX_MESSAGE_LENGTH = 256;

/**
 * Validates a Discord message
 * @param {string} message - Raw message from Discord user
 * @returns {object} { valid: boolean, error?: string, sanitized?: string }
 */
export function validateDiscordMessage(message) {
    if (!message) return { valid: false, error: 'Empty message' };
    if (message.length > MAX_MESSAGE_LENGTH) {
        return { valid: false, error: `Message exceeds ${MAX_MESSAGE_LENGTH} characters` };
    }

    // Alert on suspicious patterns (but allow them for agents to handle)
    const suspiciousPatterns = [
        /[\x00-\x08\x0B-\x0C\x0E-\x1F]/g,  // Control characters
        /[\uFEFF]/g,  // BOM
    ];

    let sanitized = message;
    for (const pattern of suspiciousPatterns) {
        sanitized = sanitized.replace(pattern, '');
    }

    if (sanitized !== message) {
        console.warn('[MessageValidator] Removed control characters from Discord message');
    }

    return { valid: true, sanitized };
}

/**
 * Validates a Minecraft in-game message
 * @param {string} message - Raw message from Minecraft chat
 * @returns {object} { valid: boolean, error?: string, sanitized?: string }
 */
export function validateMinecraftMessage(message) {
    if (!message) return { valid: false, error: 'Empty message' };
    if (message.length > MAX_MESSAGE_LENGTH) {
        return { valid: false, error: `Message exceeds ${MAX_MESSAGE_LENGTH} characters` };
    }

    // Minecraft chat allows most characters; filter only dangerous ones
    const dangerousPatterns = [
        /[\x00]/g,  // Null byte (protocol exploit)
        /\n/g,      // Newlines (message splitting)
    ];

    let sanitized = message;
    for (const pattern of dangerousPatterns) {
        sanitized = sanitized.replace(pattern, ' ');
    }

    return { valid: true, sanitized };
}

/**
 * Validates a username (bot or player name)
 * @param {string} username - Username to validate
 * @returns {object} { valid: boolean, error?: string }
 */
export function validateUsername(username) {
    if (!username) return { valid: false, error: 'Username is empty' };
    if (!/^[a-zA-Z0-9_]{3,16}$/.test(username)) {
        return { valid: false, error: 'Username must be 3-16 alphanumeric chars or underscore' };
    }
    return { valid: true };
}
