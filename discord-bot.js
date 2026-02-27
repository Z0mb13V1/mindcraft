
import { Client, GatewayIntentBits, Partials } from 'discord.js';
import { io } from 'socket.io-client';
import { readFile, writeFile } from 'fs/promises';
import { readFileSync, writeFileSync } from 'fs';
import { join, dirname, resolve, sep } from 'path';
import { fileURLToPath } from 'url';
import { validateDiscordMessage } from './src/utils/message_validator.js';
import { RateLimiter } from './src/utils/rate_limiter.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROFILES_DIR = join(__dirname, 'profiles');
const ACTIVE_PROFILES = ['cloud-persistent', 'local-research'];

// ── Admin Authorization ──────────────────────────────────────
// Comma-separated Discord user IDs allowed to run destructive commands.
// If empty, all users in the channel can run all commands.
const ADMIN_USER_IDS = (process.env.DISCORD_ADMIN_IDS || '').split(',').map(s => s.trim()).filter(Boolean);

function isAdmin(userId) {
    // If no admin list is configured, restrict to nobody (fail-secure)
    if (ADMIN_USER_IDS.length === 0) return false;
    return ADMIN_USER_IDS.includes(userId);
}

// ── Profile Name Validation ──────────────────────────────────
// Only allow alphanumeric, underscore, and hyphen characters to prevent
// path traversal attacks when profile names are used in file paths.
function isValidProfileName(name) {
    return typeof name === 'string' && /^[a-zA-Z0-9_-]+$/.test(name) && name.length <= 64;
}

function safeProfilePath(name) {
    if (!isValidProfileName(name)) {
        throw new Error(`Invalid profile name: "${name}"`);
    }
    const filePath = join(PROFILES_DIR, `${name}.json`);
    const resolvedDir = resolve(PROFILES_DIR);
    const resolvedFile = resolve(filePath);
    if (!resolvedFile.startsWith(resolvedDir + sep)) {
        throw new Error(`Path traversal detected for profile: "${name}"`);
    }
    return filePath;
}

// ── Bot Groups (name → agent names) ─────────────────────────
// Reads agent names from profile JSON files at startup so the map
// stays in sync with whatever profiles are configured.
function loadProfileAgentMap() {
    const map = {};
    for (const profileName of ACTIVE_PROFILES) {
        try {
            const filePath = safeProfilePath(profileName);
            const profile = JSON.parse(readFileSync(filePath, 'utf8'));
            if (profile.name) map[profileName] = profile.name;
        } catch { /* profile may not exist yet */ }
    }
    return map;
}
const PROFILE_AGENT_MAP = loadProfileAgentMap();
const allAgentNames = Object.values(PROFILE_AGENT_MAP);
const BOT_GROUPS = {
    all:      allAgentNames.length > 0 ? allAgentNames : ['CloudGrok', 'LocalAndy'],
    cloud:    allAgentNames.filter(n => PROFILE_AGENT_MAP['cloud-persistent'] === n),
    local:    allAgentNames.filter(n => PROFILE_AGENT_MAP['local-research'] === n),
    research: allAgentNames.length > 0 ? [...allAgentNames] : ['LocalAndy', 'CloudGrok'],
};
console.log('[Boot] Profile→Agent map:', JSON.stringify(PROFILE_AGENT_MAP));

// ── Aliases (shorthand → canonical agent name) ──────────────
// Build aliases dynamically from discovered names, with static fallbacks
const cloudAgent = PROFILE_AGENT_MAP['cloud-persistent'] || 'CloudGrok';
const localAgent = PROFILE_AGENT_MAP['local-research'] || 'LocalAndy';
const AGENT_ALIASES = {
    'cloud':    cloudAgent,
    'cg':       cloudAgent,
    'grok':     cloudAgent,
    'local':    localAgent,
    'la':       localAgent,
    'andy':     localAgent,
};

/**
 * Resolve a user argument to a list of agent names.
 * Supports: exact agent names, group names, or comma-separated.
 * Returns: { agents: string[], label: string }
 */
function resolveAgents(arg) {
    if (!arg) return { agents: [], label: 'none' };

    // Check for comma-separated list
    const parts = arg.split(/[,\s]+/).map(s => s.trim()).filter(Boolean);
    const resolved = [];
    const labels = [];

    for (const part of parts) {
        const lower = part.toLowerCase();

        // Group match
        if (BOT_GROUPS[lower]) {
            resolved.push(...BOT_GROUPS[lower]);
            labels.push(`group:${lower}`);
            continue;
        }

        // Alias match
        if (AGENT_ALIASES[lower]) {
            resolved.push(AGENT_ALIASES[lower]);
            labels.push(AGENT_ALIASES[lower]);
            continue;
        }

        // Exact agent name match (case-insensitive)
        const agent = knownAgents.find(a => a.name.toLowerCase() === lower);
        if (agent) {
            resolved.push(agent.name);
            labels.push(agent.name);
            continue;
        }

        // Partial match (prefix)
        const partial = knownAgents.filter(a => a.name.toLowerCase().startsWith(lower));
        if (partial.length > 0) {
            resolved.push(...partial.map(a => a.name));
            labels.push(...partial.map(a => a.name));
            continue;
        }

        // Unknown — pass through as-is (MindServer may know it)
        resolved.push(part);
        labels.push(part);
    }

    // Deduplicate
    const unique = [...new Set(resolved)];
    return { agents: unique, label: labels.join(', ') };
}

// ── Config ──────────────────────────────────────────────────
const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN || '';
const BOT_DM_CHANNEL = process.env.BOT_DM_CHANNEL || '';
const BACKUP_CHAT_CHANNEL = process.env.BACKUP_CHAT_CHANNEL || '';
const MINDSERVER_HOST = process.env.MINDSERVER_HOST || 'mindcraft';
const MINDSERVER_PORT = process.env.MINDSERVER_PORT || 8080;

// ── Discord Client ──────────────────────────────────────────
const client = new Client({
    intents: [
        GatewayIntentBits.Guilds,
        GatewayIntentBits.GuildMessages,
        GatewayIntentBits.MessageContent,
        GatewayIntentBits.DirectMessages,
        GatewayIntentBits.DirectMessageTyping
    ],
    partials: [Partials.Channel, Partials.Message]
});

// ── State ───────────────────────────────────────────────────
let mindServerSocket = null;
let mindServerConnected = false;
let knownAgents = [];      // [{name, in_game, socket_connected, viewerPort}]
let agentStates = {};      // {agentName: {gameplay, action, inventory, nearby, ...}}
let replyChannel = null;   // cached Discord channel for fast replies
const messageLimiter = new RateLimiter(5, 60000);  // 5 messages per 60 seconds per user

// ── Help Text ───────────────────────────────────────────────
const HELP_TEXT = `**MindcraftBot -- Command Center**

**Chat with bots:**
Just type a message — goes to ALL active bots.
Target one bot: \`andy: go mine diamonds\` or \`cg: come here\`

**Aliases:** \`cloud\` / \`cg\` / \`grok\` = CloudGrok | \`local\` / \`la\` / \`andy\` = LocalAndy
**Groups:** \`all\`, \`cloud\`, \`local\`, \`research\` | Comma-separate: \`!stop cg, andy\`

**Monitoring:**
\`!status\` — Overview with health, hunger, position
\`!stats [bot]\` — Detailed gameplay stats (biome, weather, action)
\`!inv [bot]\` — Inventory contents and equipped gear
\`!nearby [bot]\` — Nearby players, bots, and mobs
\`!viewer\` — Bot camera view links (first-person POV)
\`!usage [bot|all]\` — API costs and token usage

**Controls:**
\`!start <bot|group>\` — Start bot(s)
\`!stop [bot|group]\` — Stop bot process (default: all)
\`!restart <bot|group>\` — Restart bot(s)
\`!freeze [bot|group]\` — Instant in-game freeze (no LLM)

**System:**
\`!mode [cloud|local|hybrid]\` — View or switch compute mode
\`!reconnect\` — Reconnect to MindServer
\`!ping\` — Pong`;

// ── MindServer Connection ───────────────────────────────────
function connectToMindServer() {
    const url = `http://${MINDSERVER_HOST}:${MINDSERVER_PORT}`;
    console.log(`📡 Connecting to MindServer at ${url}`);

    if (mindServerSocket) {
        mindServerSocket.removeAllListeners();
        mindServerSocket.disconnect();
    }

    mindServerSocket = io(url, {
        reconnection: true,
        reconnectionDelay: 2000,
        reconnectionDelayMax: 10000,
        reconnectionAttempts: Infinity,
        timeout: 10000
    });

    mindServerSocket.on('connect', () => {
        mindServerConnected = true;
        console.log('✅ Connected to MindServer');
        mindServerSocket.emit('listen-to-agents');
    });

    mindServerSocket.on('disconnect', (reason) => {
        mindServerConnected = false;
        console.log(`⚠️ Disconnected from MindServer: ${reason}`);
    });

    // ── Agent output → Discord ──
    mindServerSocket.on('bot-output', async (agentName, message) => {
        console.log(`[Agent ${agentName}] ${message}`);
        await sendToDiscord(`🟢 **${agentName}**: ${message}`);
    });

    mindServerSocket.on('chat-message', async (agentName, json) => {
        console.log(`[Agent Chat] ${agentName}: ${JSON.stringify(json)}`);
        if (json && json.message) {
            await sendToDiscord(`💬 **${agentName}**: ${json.message}`);
        }
    });

    mindServerSocket.on('agents-status', (agents) => {
        knownAgents = agents || [];
        const summary = agents.map(a => `${a.name}${a.in_game ? '✅' : '⬛'}`).join(', ');
        console.log(`[Agents] ${summary}`);
    });

    mindServerSocket.on('state-update', (states) => {
        if (states) agentStates = states;
    });

    mindServerSocket.on('connect_error', (error) => {
        mindServerConnected = false;
        // Only log periodically to avoid spam
        console.error(`MindServer error: ${error.message}`);
    });
}

// ── Discord → Send ──────────────────────────────────────────
async function sendToDiscord(message) {
    try {
        if (!replyChannel) {
            replyChannel = await client.channels.fetch(BOT_DM_CHANNEL);
        }
        if (replyChannel) {
            const chunks = message.match(/[\s\S]{1,1990}/g) || [message];
            for (const chunk of chunks) {
                await replyChannel.send(chunk);
            }
        }
    } catch (error) {
        console.error('Discord send error:', error.message);
        replyChannel = null; // reset cache on error
    }
}

// ── MindServer → Send ───────────────────────────────────────
// Matches what MindServer expects:
//   socket.on('send-message', (agentName, data))
//   then agent receives: socket.on('send-message', (data))
//   where data = { from: 'username', message: 'text' }
function sendToAgent(agentName, message, fromUser = 'Discord') {
    if (!mindServerSocket || !mindServerConnected) return { sent: false, reason: 'Not connected to MindServer' };

    const agent = knownAgents.find(a => a.name.toLowerCase() === agentName.toLowerCase());
    if (!agent) return { sent: false, reason: `Agent "${agentName}" not found` };
    if (!agent.in_game) return { sent: false, reason: `Agent "${agentName}" is not in-game` };

    try {
        mindServerSocket.emit('send-message', agent.name, { from: fromUser, message });
        console.log(`[→ ${agent.name}] ${fromUser}: ${message}`);
        return { sent: true, agent: agent.name };
    } catch (error) {
        return { sent: false, reason: error.message };
    }
}

function sendToAllAgents(message, fromUser = 'Discord') {
    const inGameAgents = knownAgents.filter(a => a.in_game);
    if (inGameAgents.length === 0) return { sent: false, agents: [], reason: 'No agents in-game' };

    const results = [];
    for (const agent of inGameAgents) {
        const result = sendToAgent(agent.name, message, fromUser);
        results.push(result);
    }
    return { sent: true, agents: inGameAgents.map(a => a.name), results };
}

// ── Helpers ─────────────────────────────────────────────────

// ── Mode Switching ──────────────────────────────────────────
const VALID_MODES = ['cloud', 'local', 'hybrid'];
const MODE_EMOJI = { cloud: '☁️', local: '🖥️', hybrid: '🔀' };

function readProfile(name) {
    const filePath = safeProfilePath(name);
    return JSON.parse(readFileSync(filePath, 'utf8'));
}

function writeProfile(name, data) {
    const filePath = safeProfilePath(name);
    writeFileSync(filePath, JSON.stringify(data, null, 4) + '\n');
}

async function readProfileAsync(name) {
    const filePath = safeProfilePath(name);
    const data = await readFile(filePath, 'utf8');
    return JSON.parse(data);
}

async function writeProfileAsync(name, data) {
    const filePath = safeProfilePath(name);
    await writeFile(filePath, JSON.stringify(data, null, 4) + '\n', 'utf8');
}

function getActiveMode(name) {
    try {
        const p = readProfile(name);
        return p._active_mode || 'unknown';
    } catch { return 'unreadable'; }
}

async function getActiveModeAsync(name) {
    try {
        const p = await readProfileAsync(name);
        return p._active_mode || 'unknown';
    } catch { return 'unreadable'; }
}

async function switchProfileMode(name, mode) {
    try {
        const profile = await readProfileAsync(name);
        if (!profile._modes) return { ok: false, reason: `No _modes config in ${name}.json` };
        const modeConfig = profile._modes[mode];
        if (!modeConfig) return { ok: false, reason: `Mode "${mode}" not defined for ${name}` };

        // Apply mode fields to top-level
        for (const [key, value] of Object.entries(modeConfig)) {
            if (key === 'compute_type') continue;
            profile[key] = value;
        }

        // Remove code_model if not in this mode
        if (profile.code_model && !modeConfig.code_model) {
            delete profile.code_model;
        }

        // Update compute type in conversing prompt
        if (profile.conversing && modeConfig.compute_type) {
            profile.conversing = profile.conversing.replace(
                /(?<=- Compute: )[^\n\\]+/,
                modeConfig.compute_type
            );
        }

        profile._active_mode = mode;
        await writeProfileAsync(name, profile);
        return { ok: true, compute: modeConfig.compute_type || mode };
    } catch (err) {
        return { ok: false, reason: err.message };
    }
}

async function handleModeCommand(arg, message) {
    const parts = arg.trim().split(/\s+/).filter(Boolean);

    // No args → show current modes
    if (parts.length === 0) {
        const lines = [];
        for (const name of ACTIVE_PROFILES) {
            const mode = await getActiveModeAsync(name);
            const emoji = MODE_EMOJI[mode] || '❓';
            lines.push(`• **${name}** — ${emoji} ${mode}`);
        }
        return `**Current Compute Modes:**\n${lines.join('\n')}\n\nUsage: \`!mode <cloud|local|hybrid> [profile]\``;
    }

    const mode = parts[0].toLowerCase();
    if (!VALID_MODES.includes(mode)) {
        return `❌ Invalid mode: \`${mode}\`. Valid: \`cloud\`, \`local\`, \`hybrid\``;
    }

    // Determine which profiles to switch
    const rawTargets = parts.length > 1
        ? parts.slice(1).map(p => p.toLowerCase().replace('.json', ''))
        : [...ACTIVE_PROFILES];

    // Validate all profile names before touching the filesystem
    const invalidTargets = rawTargets.filter(name => !isValidProfileName(name));
    if (invalidTargets.length > 0) {
        return `❌ Invalid profile name(s): ${invalidTargets.map(n => `\`${n}\``).join(', ')}. Profile names may only contain letters, numbers, hyphens, and underscores.`;
    }
    const targets = rawTargets;

    await message.channel.sendTyping();

    const results = [];
    for (const name of targets) {
        const result = await switchProfileMode(name, mode);  // Now async
        if (result.ok) {
            results.push(`✅ **${name}** → ${MODE_EMOJI[mode]} ${mode} (${result.compute})`);
        } else {
            results.push(`⚠️ **${name}** — ${result.reason}`);
        }
    }

    let reply = `**Mode Switch → ${mode.toUpperCase()}**\n${results.join('\n')}`;

    // Restart agents via MindServer if connected
    if (mindServerConnected) {
        reply += '\n\n🔄 Restarting agents...';
        for (const name of targets) {
            // Find the agent's in-game name from the profile
            try {
                const profile = await readProfileAsync(name);
                const agentName = profile.name || name;
                mindServerSocket.emit('restart-agent', agentName);
            } catch { /* skip */ }
        }
    } else {
        reply += '\n\n⚠️ MindServer not connected — restart agents manually or use `!reconnect` then `!restart <name>`.';
    }

    return reply;
}

// ── Agent Helpers ───────────────────────────────────────────
function getAgentStatusText() {
    if (knownAgents.length === 0) return 'No agents registered.';
    return knownAgents.map(a => {
        const status = a.in_game ? '🟢 in-game' : (a.socket_connected ? '🟡 connected' : '🔴 offline');
        return `• **${a.name}** — ${status}`;
    }).join('\n');
}

function findBestAgent() {
    return knownAgents.find(a => a.in_game) || knownAgents.find(a => a.socket_connected) || knownAgents[0];
}

function parseAgentPrefix(content) {
    // Check for "agentName: message" or "alias: message" pattern
    const colonIdx = content.indexOf(':');
    if (colonIdx > 0 && colonIdx < 30) {
        const possibleName = content.substring(0, colonIdx).trim().toLowerCase();
        const msg = content.substring(colonIdx + 1).trim();

        // Exact agent name match
        const agent = knownAgents.find(a => a.name.toLowerCase() === possibleName);
        if (agent) {
            return { agent: agent.name, message: msg };
        }

        // Alias match
        if (AGENT_ALIASES[possibleName]) {
            return { agent: AGENT_ALIASES[possibleName], message: msg };
        }
    }
    return null;
}

// ── Usage Formatting ────────────────────────────────────────
function formatAgentUsage(agentName, data) {
    if (!data || !data.totals) return `\n**${agentName}** — No data\n`;
    const t = data.totals;
    const rpm = data.rpm ?? 0;
    const tpm = data.tpm ?? 0;
    let text = `\n**${agentName}**\n`;
    text += `  Cost: **$${t.estimated_cost_usd.toFixed(4)} USD**\n`;
    text += `  Requests: **${t.calls.toLocaleString()}** | RPM: **${rpm}**\n`;
    text += `  Tokens: **${t.total_tokens.toLocaleString()}** `;
    text += `(${t.prompt_tokens.toLocaleString()} in / ${t.completion_tokens.toLocaleString()} out) | TPM: **${tpm.toLocaleString()}**\n`;

    if (data.models && Object.keys(data.models).length > 0) {
        for (const [model, m] of Object.entries(data.models)) {
            const prov = m.provider || '?';
            text += `  - \`${model}\` (${prov}): ${m.calls} calls, `;
            text += `${m.total_tokens.toLocaleString()} tokens, $${m.estimated_cost_usd.toFixed(4)}\n`;
        }
    }
    return text;
}

// ── State Display Formatters ────────────────────────────────
function formatHealth(hp) {
    if (hp == null) return '?';
    const hearts = Math.ceil(hp / 2);
    return `${'❤️'.repeat(Math.min(hearts, 10))} ${hp}/20`;
}

function formatHunger(hunger) {
    if (hunger == null) return '?';
    const drums = Math.ceil(hunger / 2);
    return `${'🍗'.repeat(Math.min(drums, 10))} ${hunger}/20`;
}

function formatPos(pos) {
    if (!pos) return 'Unknown';
    return `${Math.round(pos.x)}, ${Math.round(pos.y)}, ${Math.round(pos.z)}`;
}

function formatAgentStats(name, state) {
    if (!state || state.error) return `**${name}** — No data available`;
    const gp = state.gameplay || {};
    const act = state.action || {};
    const surr = state.surroundings || {};
    let text = `**${name}**\n`;
    text += `${formatHealth(gp.health)} | ${formatHunger(gp.hunger)}\n`;
    text += `📍 ${formatPos(gp.position)} (${gp.dimension || '?'})\n`;
    text += `🌿 ${gp.biome || '?'} | ${gp.weather || '?'} | ${gp.timeLabel || '?'}\n`;
    text += `⚡ ${act.current || (act.isIdle ? 'Idle' : '?')}\n`;
    text += `🧱 Standing on: ${surr.below || '?'}`;
    return text;
}

function formatAgentInventory(name, state) {
    if (!state || state.error) return `**${name}** — No data available`;
    const inv = state.inventory || {};
    const equip = inv.equipment || {};
    let text = `**${name} — Inventory** (${inv.stacksUsed || 0}/${inv.totalSlots || 36} slots)\n`;

    // Equipment
    const slots = [
        ['⛑️', equip.helmet], ['👕', equip.chestplate],
        ['👖', equip.leggings], ['👢', equip.boots], ['🗡️', equip.mainHand]
    ];
    const equipped = slots.filter(([, v]) => v).map(([e, v]) => `${e} ${v}`);
    if (equipped.length > 0) text += `**Equipped:** ${equipped.join(' | ')}\n`;

    // Items
    const counts = inv.counts || {};
    const entries = Object.entries(counts).sort((a, b) => b[1] - a[1]);
    if (entries.length === 0) {
        text += '*(empty)*';
    } else {
        text += entries.map(([item, count]) => `\`${item}\` x${count}`).join(', ');
    }
    return text;
}

function formatAgentNearby(name, state) {
    if (!state || state.error) return `**${name}** — No data available`;
    const nearby = state.nearby || {};
    let text = `**${name} — Nearby**\n`;
    const humans = nearby.humanPlayers || [];
    const bots = nearby.botPlayers || [];
    const entities = nearby.entityTypes || [];
    text += `👤 Players: ${humans.length > 0 ? humans.join(', ') : 'none'}\n`;
    text += `🤖 Bots: ${bots.length > 0 ? bots.join(', ') : 'none'}\n`;
    text += `🐾 Entities: ${entities.length > 0 ? entities.join(', ') : 'none'}`;
    return text;
}

// ── Discord Events ──────────────────────────────────────────
client.on('ready', () => {
    console.log(`🤖 Logged in as ${client.user.tag}`);
    console.log(`📋 Channels: DM=${BOT_DM_CHANNEL}, Backup=${BACKUP_CHAT_CHANNEL}`);
});

client.on('messageCreate', async (message) => {
    if (message.author.bot) return;

    const isTarget = message.channelId === BOT_DM_CHANNEL || message.channelId === BACKUP_CHAT_CHANNEL;
    if (!isTarget) return;

    const content = message.content.trim();
    const lower = content.toLowerCase();
    console.log(`[Discord] ${message.author.username}: ${content}`);

    // ── Rate Limiting ──
    const rateCheck = messageLimiter.checkLimit(message.author.id);
    if (!rateCheck.allowed) {
        await message.reply(`⏱️ Rate limited. Please wait ${rateCheck.retryAfterSeconds}s before sending another message.`);
        return;
    }

    try {
        // ── Natural language triggers ──
        if (lower === 'what can you do' || lower === 'what can you do?' || lower === 'help' || lower === '!help') {
            await message.reply(HELP_TEXT);
            return;
        }

        // ── Commands ──
        if (content.startsWith('!')) {
            const parts = content.split(/\s+/);
            const cmd = parts[0].toLowerCase();
            let arg = parts.slice(1).join(' ');

            switch (cmd) {
                case '!ping':
                    await message.reply('🏓 Pong!');
                    return;

                case '!status': {
                    const ms = mindServerConnected ? '✅ MindServer connected' : '❌ MindServer disconnected';
                    const agentCount = knownAgents.length;
                    const inGame = knownAgents.filter(a => a.in_game).length;
                    let reply = `${ms}\n📊 **${agentCount}** agents registered, **${inGame}** in-game\n\n`;
                    for (const agent of knownAgents) {
                        const status = agent.in_game ? '🟢 in-game' : (agent.socket_connected ? '🟡 connected' : '🔴 offline');
                        reply += `• **${agent.name}** — ${status}`;
                        const st = agentStates[agent.name];
                        if (agent.in_game && st && st.gameplay) {
                            const gp = st.gameplay;
                            reply += ` | ❤️${gp.health || '?'}  🍗${gp.hunger || '?'}  📍${formatPos(gp.position)}`;
                        }
                        reply += '\n';
                    }
                    await message.reply(reply);
                    return;
                }

                case '!agents':
                    await message.reply(`**Agent Status:**\n${getAgentStatusText()}`);
                    return;

                case '!reconnect':
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    await message.reply('🔄 Reconnecting to MindServer...');
                    connectToMindServer();
                    return;

                case '!start': {
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    if (!arg) { await message.reply('Usage: `!start <name|group>` — Groups: `all`, `gemini`, `grok`, `1`, `2`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const { agents: startTargets } = resolveAgents(arg);
                    for (const name of startTargets) mindServerSocket.emit('start-agent', name);
                    await message.reply(`▶️ Starting **${startTargets.join(', ')}**...`);
                    setTimeout(async () => { await sendToDiscord(`**Agent Status:**\n${getAgentStatusText()}`); }, 5000);
                    return;
                }

                case '!stop': {
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const stopArg = arg || 'all';
                    const { agents: stopTargets } = resolveAgents(stopArg);
                    for (const name of stopTargets) mindServerSocket.emit('stop-agent', name);
                    await message.reply(`⏹️ Stopping **${stopTargets.join(', ')}**...`);
                    setTimeout(async () => { await sendToDiscord(`**Agent Status:**\n${getAgentStatusText()}`); }, 5000);
                    return;
                }

                case '!freeze': {
                    // Sends "freeze" as an in-game chat message to bots.
                    // The hardcoded intercept in agent.js catches "freeze" and
                    // calls actions.stop() + shut_up — no LLM involved.
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const freezeArg = arg || 'all';
                    const { agents: freezeTargets } = resolveAgents(freezeArg);
                    const inGame = freezeTargets.filter(n => knownAgents.find(a => a.name === n && a.in_game));
                    if (inGame.length === 0) {
                        await message.reply('❌ No matching agents are in-game.');
                        return;
                    }
                    for (const name of inGame) {
                        sendToAgent(name, 'freeze', message.author.username);
                    }
                    await message.reply(`🧊 Froze **${inGame.join(', ')}** — they will stop all actions immediately.`);
                    return;
                }

                case '!restart': {
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    if (!arg) { await message.reply('Usage: `!restart <name|group>` — Groups: `all`, `gemini`, `grok`, `1`, `2`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const { agents: restartTargets } = resolveAgents(arg);
                    for (const name of restartTargets) mindServerSocket.emit('restart-agent', name);
                    await message.reply(`🔄 Restarting **${restartTargets.join(', ')}**...`);
                    setTimeout(async () => { await sendToDiscord(`**Agent Status:**\n${getAgentStatusText()}`); }, 8000);
                    return;
                }

                case '!startall':
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    for (const name of BOT_GROUPS.all) mindServerSocket.emit('start-agent', name);
                    await message.reply(`▶️ Starting all agents: **${BOT_GROUPS.all.join(', ')}**...`);
                    setTimeout(async () => { await sendToDiscord(`**Agent Status:**\n${getAgentStatusText()}`); }, 5000);
                    return;

                case '!stopall':
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    mindServerSocket.emit('stop-all-agents');
                    await message.reply('⏹️ Stopping all agents...');
                    setTimeout(async () => { await sendToDiscord(`**Agent Status:**\n${getAgentStatusText()}`); }, 5000);
                    return;

                case '!mode': {
                    if (!isAdmin(message.author.id)) { await message.reply('⛔ This command requires admin privileges.'); return; }
                    const modeResult = await handleModeCommand(arg, message);
                    await message.reply(modeResult);
                    return;
                }

                case '!usage': {
                    if (!mindServerConnected) { await message.reply('MindServer not connected.'); return; }
                    await message.channel.sendTyping();

                    if (!arg || arg.toLowerCase() === 'all') {
                        let replied = false;
                        const timeout = setTimeout(async () => {
                            if (!replied) { replied = true; await message.reply('⏱️ Usage request timed out. Agents may be busy.'); }
                        }, 10000);
                        mindServerSocket.emit('get-all-usage', async (results) => {
                            if (replied) return;
                            replied = true;
                            clearTimeout(timeout);
                            if (!results || Object.keys(results).length === 0) {
                                await message.reply('No usage data available. Are any agents in-game?');
                                return;
                            }
                            let reply = '**API Usage Summary**\n';
                            let grandTotal = 0;
                            for (const [name, data] of Object.entries(results)) {
                                if (!data) continue;
                                grandTotal += data.totals?.estimated_cost_usd || 0;
                                reply += formatAgentUsage(name, data);
                            }
                            reply += `\n**Grand Total: $${grandTotal.toFixed(4)}**`;
                            await message.reply(reply);
                        });
                    } else {
                        const { agents: usageTargets } = resolveAgents(arg);
                        const target = usageTargets[0];
                        if (!target) { await message.reply(`Agent "${arg}" not found.`); return; }
                        let replied = false;
                        const timeout = setTimeout(async () => {
                            if (!replied) { replied = true; await message.reply('⏱️ Usage request timed out.'); }
                        }, 10000);
                        mindServerSocket.emit('get-agent-usage', target, async (response) => {
                            if (replied) return;
                            replied = true;
                            clearTimeout(timeout);
                            if (response.error) { await message.reply(`Error: ${response.error}`); return; }
                            if (!response.usage) { await message.reply(`No usage data for **${target}**.`); return; }
                            const reply = '**API Usage Report**\n' + formatAgentUsage(target, response.usage);
                            await message.reply(reply);
                        });
                    }
                    return;
                }

                case '!stats': {
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    if (!arg) {
                        // Show all agents
                        const lines = [];
                        for (const agent of knownAgents) {
                            if (agent.in_game && agentStates[agent.name]) {
                                lines.push(formatAgentStats(agent.name, agentStates[agent.name]));
                            } else {
                                lines.push(`**${agent.name}** — ${agent.in_game ? 'no state data' : 'offline'}`);
                            }
                        }
                        await message.reply(lines.join('\n\n') || 'No agents registered.');
                    } else {
                        const { agents: targets } = resolveAgents(arg);
                        const lines = targets.map(n => formatAgentStats(n, agentStates[n]));
                        await message.reply(lines.join('\n\n') || 'Agent not found.');
                    }
                    return;
                }

                case '!inv':
                case '!inventory': {
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    if (!arg) {
                        const lines = [];
                        for (const agent of knownAgents) {
                            if (agent.in_game && agentStates[agent.name]) {
                                lines.push(formatAgentInventory(agent.name, agentStates[agent.name]));
                            }
                        }
                        await message.reply(lines.join('\n\n') || 'No in-game agents.');
                    } else {
                        const { agents: targets } = resolveAgents(arg);
                        const lines = targets.map(n => formatAgentInventory(n, agentStates[n]));
                        await message.reply(lines.join('\n\n') || 'Agent not found.');
                    }
                    return;
                }

                case '!nearby': {
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    if (!arg) {
                        const lines = [];
                        for (const agent of knownAgents) {
                            if (agent.in_game && agentStates[agent.name]) {
                                lines.push(formatAgentNearby(agent.name, agentStates[agent.name]));
                            }
                        }
                        await message.reply(lines.join('\n\n') || 'No in-game agents.');
                    } else {
                        const { agents: targets } = resolveAgents(arg);
                        const lines = targets.map(n => formatAgentNearby(n, agentStates[n]));
                        await message.reply(lines.join('\n\n') || 'Agent not found.');
                    }
                    return;
                }

                case '!viewer': {
                    const lines = [];
                    for (const agent of knownAgents) {
                        if (agent.viewerPort) {
                            lines.push(`**${agent.name}**: http://${process.env.PUBLIC_HOST || 'localhost'}:${agent.viewerPort}`);
                        }
                    }
                    await message.reply(lines.length > 0
                        ? `**Bot Camera Views:**\n${lines.join('\n')}`
                        : 'No viewer ports active. Vision may be disabled.');
                    return;
                }

                case '!ui':
                case '!local':
                case '!mindserver':
                    await sendToDiscord('🖥️ **MindServer Backup UI**: http://localhost:8080\nOpen in browser for agent dashboard/viewer (docker-compose up mindcraft).');
                    return;

                default:
                    await message.reply(`Unknown command: \`${cmd}\`. Type \`!help\` for commands.`);
                    return;
            }
        }

        // ── Chat relay to agent ──
        if (!mindServerConnected) {
            await message.reply('🔌 MindServer is offline. Type `!reconnect` to retry.');
            return;
        }

        // Validate message
        const validation = validateDiscordMessage(content);
        if (!validation.valid) {
            await message.reply(`⚠️ Invalid message: ${validation.error}`);
            return;
        }
        const cleanContent = validation.sanitized;

        await message.channel.sendTyping();

        // Check for "agentName: message" or "alias: message" prefix
        const parsed = parseAgentPrefix(cleanContent);

        if (parsed) {
            // Targeted: send to one specific agent
            const result = sendToAgent(parsed.agent, parsed.message, message.author.username);
            if (result.sent) {
                await message.reply(`📨 **${result.agent}** received your message. Waiting for response...`);
            } else {
                await message.reply(`⚠️ ${result.reason}`);
            }
        } else {
            // No prefix: broadcast to ALL in-game agents
            const result = sendToAllAgents(cleanContent, message.author.username);
            if (result.sent) {
                await message.reply(`📨 Sent to **${result.agents.join(', ')}**. Waiting for responses...`);
            } else {
                await message.reply(`⚠️ ${result.reason || 'No agents available. Check `!agents` or `!start <name>`.'}`);
            }
        }

    } catch (error) {
        console.error('Message handler error:', error.message);
        try { await message.reply('❌ Something went wrong.'); } catch (e) { /* ignore */ }
    }
});

client.on('error', (error) => {
    console.error('Discord client error:', error.message);
});

// ── Startup ─────────────────────────────────────────────────
async function start() {
    console.log('🚀 Starting MindcraftBot...');
    console.log(`   MindServer: ${MINDSERVER_HOST}:${MINDSERVER_PORT}`);

    try {
        await client.login(BOT_TOKEN);
    } catch (error) {
        console.error('❌ Discord login failed:', error.message);
        process.exit(1);
    }

    connectToMindServer();
    console.log('✅ MindcraftBot running');
}

start().catch(err => { console.error('Fatal:', err); process.exit(1); });

// ── Graceful Shutdown ───────────────────────────────────────
const shutdown = async (signal) => {
    console.log(`\n🛑 ${signal} received, shutting down...`);
    if (mindServerSocket) mindServerSocket.disconnect();
    await client.destroy();
    process.exit(0);
};
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
