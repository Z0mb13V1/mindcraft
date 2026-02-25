// Automated Discord bot message test script
// Sends test messages to the bot and checks for responses

import { Client, GatewayIntentBits } from 'discord.js';

const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN;
const BOT_DM_CHANNEL = process.env.BOT_DM_CHANNEL;

if (!BOT_TOKEN) {
    console.error('❌ DISCORD_BOT_TOKEN environment variable is required');
    process.exit(1);
}

const client = new Client({
    intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.DirectMessages]
});

async function runTest() {
    await client.login(BOT_TOKEN);
    await new Promise(resolve => setTimeout(resolve, 2000)); // Wait for ready
    const channel = await client.channels.fetch(BOT_DM_CHANNEL);
    if (!channel) {
        console.error('Test channel not found');
        process.exit(1);
    }
    const testMessage = 'Bot test message ' + Date.now();
    const sent = await channel.send(testMessage);
    console.log('Test message sent:', sent.content);
    // Listen for bot response
    channel.awaitMessages({
        filter: m => m.author.bot && m.content.includes(testMessage),
        max: 1,
        time: 5000,
        errors: ['time']
    }).then(collected => {
        console.log('Bot responded:', collected.first().content);
        process.exit(0);
    }).catch(() => {
        console.error('No bot response detected');
        process.exit(1);
    });
}

await runTest();
