const settings = {
    "minecraft_version": "auto", // or specific version like "1.21.6"
    "host": "54.152.239.117", // EC2 public IP (local dev) — Docker overrides via SETTINGS_JSON
    "port": 25565, // set to -1 to automatically scan for open ports
    "auth": "offline", // or "microsoft"

    // the mindserver manages all agents and hosts the UI
    "mindserver_port": 8080,
    "mindserver_host_public": false, // true binds to 0.0.0.0 (all interfaces, required for Docker multi-container setups); false binds to localhost only
    "mindserver_url": "http://54.152.239.117:8080", // connect to a remote MindServer (e.g. "http://54.152.239.117:8080"). When set, no local MindServer is started — agents register themselves on the remote one.
    "auto_open_ui": true, // opens UI in browser on startup

    "base_profile": "assistant", // survival, assistant, creative, or god_mode
    "profiles": [
        "./profiles/local-research.json",
        // "./profiles/ensemble.json",
        // "./profiles/cloud-persistent.json",
        // "./profiles/gemini.json",
        // "./profiles/gemini2.json",
        // "./profiles/grok.json",

        // using more than 1 profile requires you to /msg each bot indivually
        // individual profiles override values from the base profile
    ],

    "load_memory": true, // load memory from previous session
    "init_message": "", // empty = use hardcoded "Hello world! I am [name]" (bypasses LLM, avoids andy-4 hallucination)
    "only_chat_with": [], // users that the bots listen to and send general messages to. if empty it will chat publicly

    "speak": false,
    // allows all bots to speak through text-to-speech.
    // specify speech model inside each profile with format: {provider}/{model}/{voice}.
    // if set to "system" it will use basic system text-to-speech.
    // Works on windows and mac, but linux requires you to install the espeak package through your package manager eg: `apt install espeak` `pacman -S espeak`.

    "chat_ingame": true, // bot responses are shown in minecraft chat
    "language": "en", // translate to/from this language. Supports these language names: https://cloud.google.com/translate/docs/languages
    "render_bot_view": true, // show bot's view in browser at localhost:3000, 3001...\n

    "allow_insecure_coding": false, // allows newAction command and model can write/run code on your computer. enable at own risk
    "allow_vision": false, // allows vision model to interpret screenshots as inputs (enabled via SETTINGS_JSON in Docker with LIBGL_ALWAYS_SOFTWARE=1)
    "blocked_actions" : ["!newAction", "!checkBlueprint", "!checkBlueprintLevel", "!getBlueprint", "!getBlueprintLevel"] , // commands to disable and remove from docs. Ex: ["!setMode"]
    "code_timeout_mins": -1, // minutes code is allowed to run. -1 for no timeout
    "relevant_docs_count": -1, // number of relevant code function docs to select for prompting. -1 for all

    "max_messages": 100, // max number of messages to keep in context
    "num_examples": 2, // number of examples to give to the model
    "max_commands": 15, // max number of commands that can be used in consecutive responses. -1 for no limit
    "show_command_syntax": "shortened", // "full", "shortened", or "none"
    "narrate_behavior": false, // chat simple automatic actions ('Picking up item!')
    "chat_bot_messages": false, // publicly chat messages to other bots

    "spawn_timeout": 30, // num seconds allowed for the bot to spawn before throwing error. Increase when spawning takes a while.
    "block_place_delay": 0, // delay between placing blocks (ms) if using newAction. helps avoid bot being kicked by anti-cheat mechanisms on servers.

    "log_all_prompts": true, // log ALL prompts to file

};

/**
 * Recursively strips prototype-polluting keys from an object.
 * Prevents __proto__, constructor, and prototype injection at any depth.
 */
function deepSanitize(obj) {
    const BLOCKED_KEYS = new Set(['__proto__', 'constructor', 'prototype']);
    if (obj === null || typeof obj !== 'object') return obj;
    if (Array.isArray(obj)) return obj.map(item => deepSanitize(item));
    const sanitized = {};
    for (const [key, value] of Object.entries(obj)) {
        if (BLOCKED_KEYS.has(key)) continue;
        sanitized[key] = (typeof value === 'object' && value !== null)
            ? deepSanitize(value)
            : value;
    }
    return sanitized;
}

if (process.env.SETTINGS_JSON) {
    try {
        const parsed = JSON.parse(process.env.SETTINGS_JSON);
        const safe = deepSanitize(parsed);
        Object.assign(settings, safe);
    } catch (err) {
        console.error("Failed to parse SETTINGS_JSON:", err);
    }
}

export { deepSanitize };
export default settings;
