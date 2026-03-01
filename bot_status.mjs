import { readFileSync, readdirSync, statSync } from 'fs';

function readJSON(p) {
  try { return JSON.parse(readFileSync(p, 'utf8')); }
  catch { return {}; }
}

function latestLog(bot) {
  const dir = `bots/${bot}/logs`;
  try {
    const files = readdirSync(dir).filter(f => f.startsWith('conversation_')).sort().reverse();
    if (files.length) {
      const st = statSync(`${dir}/${files[0]}`);
      return { name: files[0].slice(0, 45), ts: st.mtime.toLocaleString() };
    }
  } catch {}
  return { name: 'none', ts: 'never' };
}

const now = new Date();
console.log(`Status check: ${now.toLocaleString()}\n`);

for (const bot of ['CloudGrok', 'LocalAndy']) {
  const usage = readJSON(`bots/${bot}/usage.json`);
  const mem = readJSON(`bots/${bot}/memory.json`);
  const log = latestLog(bot);
  const totals = usage.totals || {};
  const lastCall = usage.last_call ? new Date(usage.last_call) : null;
  const ageSecs = lastCall ? Math.round((now - lastCall) / 1000) : null;
  const ageStr = ageSecs != null
    ? ageSecs > 3600
      ? `${Math.round(ageSecs / 3600)}h ${Math.round((ageSecs % 3600) / 60)}m ago`
      : `${Math.round(ageSecs / 60)}m ago`
    : 'unknown';

  console.log(`=== ${bot} ===`);
  console.log(`  Last API call:    ${usage.last_call || '?'}  (${ageStr})`);
  console.log(`  Session calls:    ${totals.calls || 0}`);
  console.log(`  Total tokens:     ${(totals.total_tokens || 0).toLocaleString()}`);
  console.log(`  Self-prompt:      [state=${mem.self_prompting_state}] ${mem.self_prompt || 'none'}`);
  console.log(`  Latest log file:  ${log.ts}  ${log.name}`);
  console.log();
}

// Node process count via tasklist
import { execSync } from 'child_process';
try {
  const out = execSync('tasklist 2>nul | find /c "node.exe"', { shell: 'cmd.exe' }).toString().trim();
  console.log(`Node.exe processes running: ${out}`);
} catch {
  console.log('Node.exe process count: unavailable');
}
