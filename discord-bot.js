/* eslint-env node */
import { Client, GatewayIntentBits, Partials } from 'discord.js';
import { io } from 'socket.io-client';
import { readFileSync, writeFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROFILES_DIR = join(__dirname, 'profiles');
const ACTIVE_PROFILES = ['gemini', 'gemini2', 'grok'];

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

// ── Help Text ───────────────────────────────────────────────
const HELP_TEXT = `🤖 **MindcraftBot — Command Center**

**Talk to agents:**
Just type a message and I'll send it to the first in-game agent.
Prefix with agent name to target: \`Gemini_1: go mine diamonds\`

**Commands:**
\`!help\` — Show this message
\`!status\` — MindServer connection + agent overview
\`!agents\` — List all agents with status
\`!mode [cloud|local|hybrid] [profile]\` — View or switch compute mode
\`!ping\` — Pong
\`!reconnect\` — Reconnect to MindServer
\`!start <name>\` — Start an agent
\`!stop <name>\` — Stop an agent
\`!restart <name>\` — Restart an agent
\`!stopall\` — Stop all agents

**What can I do?**
• Check on your Minecraft AI bots anytime
• Send chat messages to agents in-game
• Command agents (mine, build, explore, etc.)
• Monitor agent output and responses live
• Start/stop/restart agents remotely
• Switch between cloud/local/hybrid compute modes
• Track which agents are online`;

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

function getActiveMode(name) {
    try {
        const p = readProfile(name);
        return p._active_mode || 'unknown';
    } catch { return 'unreadable'; }
}

function switchProfileMode(name, mode) {
    const profile = readProfile(name);
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
    writeProfile(name, profile);
    return { ok: true, compute: modeConfig.compute_type || mode };
}

async function handleModeCommand(arg, message) {
    const parts = arg.trim().split(/\s+/).filter(Boolean);

    // No args → show current modes
    if (parts.length === 0) {
        const lines = ACTIVE_PROFILES.map(name => {
            const mode = getActiveMode(name);
            const emoji = MODE_EMOJI[mode] || '❓';
            return `• **${name}** — ${emoji} ${mode}`;
        });
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
        try {
            const result = switchProfileMode(name, mode);
            if (result.ok) {
                results.push(`✅ **${name}** → ${MODE_EMOJI[mode]} ${mode} (${result.compute})`);
            } else {
                results.push(`⚠️ **${name}** — ${result.reason}`);
            }
        } catch (err) {
            results.push(`❌ **${name}** — ${err.message}`);
        }
    }

    let reply = `**Mode Switch → ${mode.toUpperCase()}**\n${results.join('\n')}`;

    // Restart agents via MindServer if connected
    if (mindServerConnected) {
        reply += '\n\n🔄 Restarting agents...';
        for (const name of targets) {
            // Find the agent's in-game name from the profile
            try {
                const profile = readProfile(name);
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
    // Check for "agentName: message" pattern
    const colonIdx = content.indexOf(':');
    if (colonIdx > 0 && colonIdx < 30) {
        const possibleName = content.substring(0, colonIdx).trim().toLowerCase();
        const agent = knownAgents.find(a => a.name.toLowerCase() === possibleName);
        if (agent) {
            return { agent: agent.name, message: content.substring(colonIdx + 1).trim() };
        }
    }
    return null;
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
            const arg = parts.slice(1).join(' ');

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

                case '!start':
                    if (!arg) { await message.reply('Usage: `!start <agent_name>`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    mindServerSocket.emit('start-agent', arg);
                    await message.reply(`▶️ Starting agent **${arg}**...`);
                    return;

                case '!stop':
                    if (!arg) { await message.reply('Usage: `!stop <agent_name>`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    mindServerSocket.emit('stop-agent', arg);
                    await message.reply(`⏹️ Stopping agent **${arg}**...`);
                    return;

                case '!restart':
                    if (!arg) { await message.reply('Usage: `!restart <agent_name>`'); return; }
                    if (!mindServerConnected) { await message.reply('❌ MindServer not connected.'); return; }
                    mindServerSocket.emit('restart-agent', arg);
                    await message.reply(`🔄 Restarting agent **${arg}**...`);
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

        await message.channel.sendTyping();

        // Check for "agentName: message" prefix
        const parsed = parseAgentPrefix(content);
        let targetAgent, msgToSend;

        if (parsed) {
            targetAgent = parsed.agent;
            msgToSend = parsed.message;
        } else {
            const best = findBestAgent();
            if (!best) {
                await message.reply('⚠️ No agents available. Check `!agents` or `!start <name>`.');
                return;
            }
            targetAgent = best.name;
            msgToSend = content;
        }

        const result = sendToAgent(targetAgent, msgToSend, message.author.username);

        if (result.sent) {
            await message.reply(`📨 **${result.agent}** received your message. Waiting for response...`);
        } else {
            await message.reply(`⚠️ ${result.reason}`);
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
