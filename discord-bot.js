/* eslint-env node */
import { Client, GatewayIntentBits, Partials } from 'discord.js';
import { io } from 'socket.io-client';
import { readFile, writeFile } from 'fs/promises';
import { readFileSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { validateDiscordMessage } from './src/utils/message_validator.js';
import { RateLimiter } from './src/utils/rate_limiter.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROFILES_DIR = join(__dirname, 'profiles');
const ACTIVE_PROFILES = ['gemini', 'grok'];

// ── Bot Groups (name → agent names) ─────────────────────────
// Profile filename → in-game agent name mapping
const PROFILE_AGENT_MAP = {
    gemini: 'Gemini_1',
    grok: 'Grok_1'
};
const BOT_GROUPS = {
    all:    ['Gemini_1', 'Grok_1'],
    gemini: ['Gemini_1'],
    grok:   ['Grok_1'],
    cloud:  ['Gemini_1', 'Grok_1'],
};

// ── Aliases (shorthand → canonical agent name) ──────────────
const AGENT_ALIASES = {
    'gemini': 'Gemini_1',
    'gi':     'Gemini_1',
    'grok':   'Grok_1',
    'gk':     'Grok_1',
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
let replyChannel = null;   // cached Discord channel for fast replies
const messageLimiter = new RateLimiter(5, 60000);  // 5 messages per 60 seconds per user

// ── Help Text ───────────────────────────────────────────────
const HELP_TEXT = `**MindcraftBot -- Command Center**

**Talk to agents:**
Just type a message and it goes to ALL active bots.
Prefix with a name/alias to target one: \`gi: go mine diamonds\`

**Aliases:**
\`gemini\` / \`gi\` = Gemini_1  |  \`grok\` / \`gk\` = Grok_1

**Commands:**
\`!help\` -- Show this message
\`!status\` -- MindServer connection + agent overview
\`!agents\` -- List all agents with status
\`!mode [cloud|local|hybrid] [profile]\` -- View or switch compute mode
\`!usage [agent|all]\` -- Show API usage stats and costs
\`!ping\` -- Pong
\`!reconnect\` -- Reconnect to MindServer
\`!start <name|alias|group>\` -- Start agent(s)
\`!stop <name|alias|group>\` -- Stop agent(s)
\`!restart <name|alias|group>\` -- Restart agent(s)
\`!startall\` -- Start all agents
\`!stopall\` -- Stop all agents

!ui | !local | !mindserver -- View MindServer backup UI (http://localhost:8080)

**Groups:** \`all\`, \`gemini\`, \`grok\`, \`cloud\`
You can also comma-separate: \`!stop Gemini_1, Grok_1\`

**What can I do?**
- Send chat messages to one or all agents
- Use aliases: \`gi: mine\` or \`gk: come here\`
- Command agents (mine, build, explore, etc.)
- Monitor agent output and responses live
- Start/stop/restart agents by name, alias, or group
- Switch between cloud/local/hybrid compute modes`;

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
    const filePath = join(PROFILES_DIR, `${name}.json`);
    return JSON.parse(readFileSync(filePath, 'utf8'));
}

function writeProfile(name, data) {
    const filePath = join(PROFILES_DIR, `${name}.json`);
    writeFileSync(filePath, JSON.stringify(data, null, 4) + '\n');
}

async function readProfileAsync(name) {
    const filePath = join(PROFILES_DIR, `${name}.json`);
    const data = await readFile(filePath, 'utf8');
    return JSON.parse(data);
}

async function writeProfileAsync(name, data) {
    const filePath = join(PROFILES_DIR, `${name}.json`);
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
    const targets = parts.length > 1
        ? parts.slice(1).map(p => p.toLowerCase().replace('.json', ''))
        : [...ACTIVE_PROFILES];

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
                    await message.reply(`${ms}\n📊 **${agentCount}** agents registered, **${inGame}** in-game\n\n${getAgentStatusText()}`);
                    return;
                }

                case '!agents':
                    await message.reply(`**Agent Status:**\n${getAgentStatusText()}`);
                    return;

                case '!reconnect':
                    await message.reply('🔄 Reconnecting to MindServer...');
                    connectToMindServer();
                    return;

                case '!start': {
                    if (!arg) { await message.reply('Usage: `!start <name|group>` — Groups: `all`, `gemini`, `grok`, `1`, `2`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const { agents: startTargets } = resolveAgents(arg);
                    for (const name of startTargets) mindServerSocket.emit('start-agent', name);
                    await message.reply(`▶️ Starting **${startTargets.join(', ')}**...`);
                    return;
                }

                case '!stop': {
                    if (!arg) { await message.reply('Usage: `!stop <name|group>` — Groups: `all`, `gemini`, `grok`, `1`, `2`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const { agents: stopTargets } = resolveAgents(arg);
                    for (const name of stopTargets) mindServerSocket.emit('stop-agent', name);
                    await message.reply(`⏹️ Stopping **${stopTargets.join(', ')}**...`);
                    return;
                }

                case '!restart': {
                    if (!arg) { await message.reply('Usage: `!restart <name|group>` — Groups: `all`, `gemini`, `grok`, `1`, `2`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    const { agents: restartTargets } = resolveAgents(arg);
                    for (const name of restartTargets) mindServerSocket.emit('restart-agent', name);
                    await message.reply(`🔄 Restarting **${restartTargets.join(', ')}**...`);
                    return;
                }

                case '!startall':
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    for (const name of BOT_GROUPS.all) mindServerSocket.emit('start-agent', name);
                    await message.reply(`▶️ Starting all agents: **${BOT_GROUPS.all.join(', ')}**...`);
                    return;

                case '!stopall':
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    mindServerSocket.emit('stop-all-agents');
                    await message.reply('⏹️ Stopping all agents...');
                    return;

                case '!mode': {
                    const modeResult = await handleModeCommand(arg, message);
                    await message.reply(modeResult);
                    return;
                }

                case '!usage': {
                    if (!mindServerConnected) { await message.reply('MindServer not connected.'); return; }
                    await message.channel.sendTyping();

                    if (arg && arg.toLowerCase() === '[agent|all]') arg = 'all';

                    if (!arg || arg.toLowerCase() === 'all') {
                        mindServerSocket.emit('get-all-usage', async (results) => {
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
                        mindServerSocket.emit('get-agent-usage', target, async (response) => {
                            if (response.error) { await message.reply(`Error: ${response.error}`); return; }
                            if (!response.usage) { await message.reply(`No usage data for **${target}**.`); return; }
                            const reply = '**API Usage Report**\n' + formatAgentUsage(target, response.usage);
                            await message.reply(reply);
                        });
                    }
                    return;
                }

                case '!ui':
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
