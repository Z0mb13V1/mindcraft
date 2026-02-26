# Hybrid Research Rig — Complete Guide

## What This Is

Two AI-powered Minecraft bots collaborating in the same persistent world:

| Bot | In-Game Name | Compute | Model(s) | Cost |
|-----|-------------|---------|-----------|------|
| **Local** | `LocalResearch_1` | Your RTX 3090 via Ollama | sweaterdog/andy-4 (8B) | Free |
| **Cloud** | `CloudPersistent_1` | Gemini + Grok ensemble | 4-panel voting + arbiter | ~$2-5/day |

Both bots share one Minecraft server. A heuristic arbiter + optional LLM judge picks the best action from 4 cloud models every tick. Full ensemble decision logging for research analysis.

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Windows 11 Desktop                                              │
│                                                                  │
│  Docker Compose                      Ollama (native Windows)     │
│  ┌──────────────┐                    ┌─────────────────────┐     │
│  │ MC Server    │◄───────────────────│ host.docker.internal│     │
│  │ :25565       │    ┌──────────┐    │ :11434              │     │
│  ├──────────────┤    │ Mindcraft│    │                     │     │
│  │ LocalRes_1   │◄───│ Agent    │───►│ sweaterdog/andy-4   │     │
│  │ CloudPers_1  │    │ :8080    │    └─────────────────────┘     │
│  ├──────────────┤    └──────────┘                                │
│  │ Discord Bot  │         │           Cloud APIs                 │
│  │ ChromaDB     │         │           ┌─────────────────┐        │
│  └──────────────┘         ├──────────►│ Gemini 2.5 Pro  │        │
│                           ├──────────►│ Gemini 2.5 Flash│        │
│                           ├──────────►│ Grok Fast       │        │
│                           └──────────►│ Grok Code       │        │
│                                       └─────────────────┘        │
└──────────────────────────────────────────────────────────────────┘
```

---

## Run This Now — 12-Step Quickstart

> **Goal**: From current state → `.\start.ps1 both` working with two bots collaborating + full research logging.

### Step 1 — Run Master Setup

```powershell
.\full-hybrid-setup.ps1
```

This checks Docker, GPU, Ollama, API keys, profiles, builds the Docker image, and creates directories. Fix any `[FAIL]` items before continuing.

### Step 2 — Set API Keys

If not already set, add to `.env` (or `keys.json`):

```env
GEMINI_API_KEY=your-gemini-key-here
XAI_API_KEY=your-xai-key-here
```

Optional (premium tier):
```env
ANTHROPIC_API_KEY=your-anthropic-key-here
```

### Step 3 — Test Local Bot Solo

```powershell
.\start.ps1 local -Detach
```

Wait for the health check to show green, then join `localhost:25565` in Minecraft and type:
```
LocalResearch_1, who are you?
```
Verify the bot responds (Ollama inference working). Stop when done:
```powershell
.\start.ps1 stop
```

### Step 4 — Test Cloud Bot Solo

```powershell
.\start.ps1 cloud -Detach
```

Join and chat:
```
CloudPersistent_1, who are you?
```
Verify ensemble decisions are logged:
```powershell
Get-Content bots\CloudPersistent_1\ensemble_log.json | ConvertFrom-Json | Select -Last 1
```
Stop:
```powershell
.\start.ps1 stop
```

### Step 5 — Launch Both Bots Together

```powershell
.\start.ps1 both -Detach
```

Join `localhost:25565`. Both bots are in the same world. Test coordination:
```
LocalResearch_1, coordinate with CloudPersistent_1 to collect wood
```

### Step 6 — Check Status

```powershell
.\start.ps1 status
```

Shows container health, endpoint reachability, Ollama models, GPU utilization.

### Step 7 — Monitor Logs

```powershell
docker compose logs -f mindcraft              # All bot activity
docker compose logs -f minecraft-server       # MC server events
```

### Step 8 — Run Your First Experiment

```powershell
# Create experiment directory
.\experiments\new-experiment.ps1 -Name "wood-collection" -Description "Baseline: collect 64 wood logs" -Mode both -DurationMinutes 15

# Run it (auto-starts bots, injects goal, waits, collects logs)
.\experiments\start-experiment.ps1 -ExperimentDir .\experiments\2026-02-25_wood-collection -Goal "Collect 64 oak logs as fast as possible"
```

### Step 9 — Analyze Results

```powershell
.\experiments\analyze.ps1 -ExperimentDir .\experiments\2026-02-25_wood-collection -Open
```

Outputs: ensemble agreement %, latency P50/P99, commands/minute, error rate, command diversity, coordination score, cost analysis. Results saved to `results/summary.json`.

### Step 10 — (Optional) Enable Discord Bot

Add `DISCORD_BOT_TOKEN` to `.env`, then:
```powershell
.\start.ps1 both -Detach -WithDiscord
```

Control bots from Discord: `!mc tell lr collect wood` or `!mc tell all stop`.

### Step 11 — (Optional) Enable LiteLLM Proxy

For unified logging, caching, and retry across all models:
```powershell
.\start.ps1 both -Detach -WithLiteLLM
```
Dashboard at http://localhost:4000/. Config: `services/litellm/litellm_config.yaml`.

### Step 12 — Stop Everything

```powershell
.\start.ps1 stop
```
Gracefully disconnects agents before shutting down containers. Sends Discord webhook if configured.

---

## Start Modes Reference

```powershell
.\start.ps1 local                        # Local bot only (RTX 3090 + Ollama)
.\start.ps1 cloud                        # Cloud ensemble only (Gemini + Grok)
.\start.ps1 both                         # Both bots together
.\start.ps1 both -Detach                 # Background mode
.\start.ps1 both -Detach -Build          # Rebuild Docker image first
.\start.ps1 both -Detach -WithDiscord    # Include Discord bot
.\start.ps1 both -Detach -WithLiteLLM    # Include LiteLLM proxy
.\start.ps1 local -McHost 100.x.x.x     # Local bot → EC2 world via Tailscale
.\start.ps1 status                       # Health check dashboard
.\start.ps1 stop                         # Graceful shutdown
```

---

## Experiment Workflow

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ new-experiment│───►│start-experiment│──►│   (bots run)  │──►│   analyze    │
│  Creates dir  │    │ Snapshot world│    │  Timer waits  │    │ Parse logs   │
│  metadata.json│    │ Launch bots   │    │  Collect logs │    │ Compute stats│
│  Subfolders   │    │ Inject goal   │    │  Re-snapshot  │    │ summary.json │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

### Create

```powershell
.\experiments\new-experiment.ps1 `
    -Name "diamond-race" `
    -Description "Both bots race to find diamonds" `
    -Mode both `
    -DurationMinutes 30 `
    -Profiles @("local-research.json", "cloud-persistent.json")
```

### Run

```powershell
.\experiments\start-experiment.ps1 `
    -ExperimentDir .\experiments\2026-02-25_diamond-race `
    -Goal "Find and mine diamonds as fast as possible. Coordinate with the other bot."
```

Options:
- `-NoWorldSnapshot` — skip before/after world snapshots (faster)
- `-NoBotTimer` — don't auto-stop; you control when to end

### Analyze

```powershell
.\experiments\analyze.ps1 `
    -ExperimentDir .\experiments\2026-02-25_diamond-race `
    -Open
```

**Research metrics computed:**

| Metric | Description |
|--------|-------------|
| `agreement_pct` | How often ensemble panel members agreed |
| `judge_rate_pct` | How often the LLM judge was invoked |
| `latency_p50` / `latency_p99` | Response time percentiles (ms) |
| `commands_per_minute` | Bot action throughput |
| `error_rate_pct` | % of errors in conversation logs |
| `command_diversity` | Unique command types / total commands |
| `coordination_score` | Mentions of other bot / total messages |
| `survival_score` | 1 - (deaths / total messages) |
| `cost_per_command` | API cost efficiency ($/command) |
| `deaths` | Total death events detected |
| `tokens_per_decision` | Average tokens consumed per ensemble decision |
| `efficiency_score` | (commands * survival%) / cost — overall value metric |

**Output formats**: `summary.json`, `summary.txt`, `metrics.csv` (one row per bot, spreadsheet-ready)

### A/B Testing

Run multiple trials across model variants with automatic world restore between runs:

```powershell
$variants = @(
    @{ Name = "andy-4-local";   Mode = "local"; Profile = "local-research.json" },
    @{ Name = "gemini-cloud";   Mode = "cloud"; Profile = "cloud-persistent.json" }
)
.\experiments\run-ab-test.ps1 `
    -TestName "local-vs-cloud" `
    -Variants $variants `
    -TrialsPerVariant 5 `
    -DurationMinutes 15 `
    -Goal "Collect 64 wood logs"
```

Outputs: comparison table with mean +/- stddev per metric, `results.csv`, `comparison.csv`, `full-results.json`. Discord webhook notifications for each completed trial.

### World Snapshots

```powershell
# Manual backup
.\experiments\backup-world.ps1 -Target .\backups\my-save

# Restore from backup
.\experiments\restore-world.ps1 -BackupDir .\backups\my-save
```

---

## Bot Profiles

### LocalResearch_1 (`profiles/local-research.json`)
- **Model**: `sweaterdog/andy-4` via Ollama (free, runs on your GPU)
- **Fallback**: `gemini-2.5-flash` (cloud, if Ollama fails)
- **Cooldown**: 1500ms
- **Modes**: `local` (default), `local-32b` (qwen2.5:32b), `cloud`, `hybrid`
- **Role**: Research, exploration, rapid iteration

### CloudPersistent_1 (`profiles/cloud-persistent.json`)
- **Architecture**: 4-panel ensemble with heuristic arbiter + LLM judge
- **Panel**: Gemini 2.5 Pro, Gemini 2.5 Flash, Grok Fast, Grok Code
- **Arbiter**: Heuristic scoring → LLM judge tiebreak (margin < 0.08)
- **Cooldown**: 3000ms
- **Role**: Persistent survival, base maintenance, 24/7 operation

### Ensemble_1 (`profiles/ensemble.json`)
- Same ensemble architecture as CloudPersistent_1
- Alternative name for standalone deployment

---

## Tailscale — Connect to EC2 World

Want the local bot on your desktop to join the persistent Minecraft world running on EC2?

```powershell
# 1. Install Tailscale on Windows
winget install Tailscale.Tailscale
# Sign in via the system tray icon

# 2. Get your Tailscale IP
tailscale ip -4  # → 100.x.x.x

# 3. On EC2 (via Instance Connect browser console):
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
tailscale ip -4  # → 100.y.y.y

# 4. Add security group rule: TCP 25565 from 100.64.0.0/10 (Tailscale CGNAT)

# 5. Test connectivity
Test-NetConnection -ComputerName 100.y.y.y -Port 25565

# 6. Launch local bot → EC2 world
.\start.ps1 local -McHost 100.y.y.y -Detach
```

Both bots now share the EC2 world. See [TAILSCALE.md](TAILSCALE.md) for detailed setup and troubleshooting.

---

## Discord Bot Integration

The Discord bot (MindcraftBot) lets you control bots remotely:

```
!mc tell lr collect wood          # Tell LocalResearch_1 to collect wood
!mc tell cp build a house         # Tell CloudPersistent_1 to build
!mc tell all come here            # Tell all bots
!mc tell ens stop                 # Tell Ensemble_1 to stop

!mc start cloud                   # Start cloud bot
!mc stop all                      # Stop all bots
!mc restart lr                    # Restart local bot
!mc status                        # Check bot status
```

**Aliases**: `lr` = LocalResearch_1, `cp` = CloudPersistent_1, `ens` = Ensemble_1, `local` = LocalResearch_1, `cloud` = CloudPersistent_1

**Groups**: `!mc tell research ...` (LR + CP), `!mc tell ensemble ...` (Ensemble_1)

---

## LiteLLM Proxy (Optional)

Unified API gateway with retry, caching, and logging for all models.

**Config**: `services/litellm/litellm_config.yaml`

**Features**:
- Local models via Ollama (`host.docker.internal:11434`)
- Cloud model routing (Gemini, Grok, Claude, OpenAI — uncomment as needed)
- 3 retries with 5s backoff, 60s cooldown for unhealthy models
- Response caching (5-minute TTL)
- Master key authentication

**Tiers** (uncomment in config to enable):
| Tier | Models | Cost |
|------|--------|------|
| Free | sweaterdog/andy-4, qwen2.5:32b, llama3.1:8b | $0 (local GPU) |
| Standard | Gemini 2.5 Pro/Flash, Grok Fast/Code | ~$2-5/day |
| Premium | Claude Sonnet 4.6, Haiku 4.5 | ~$3-15/M tokens |
| Enterprise | GPT-4o | ~$5-15/M tokens |

---

## Reliability Features

Designed for weeks-long unattended operation:

- **restart: unless-stopped** on mindcraft + discord-bot containers
- **Health checks** with 5 retries and 90s startup grace period
- **JSON-file logging** with 10MB rotation (no unbounded disk growth)
- **LiteLLM retries**: 3 attempts with 5s backoff per failed API call
- **Model cooldown**: 60s quarantine after 3 consecutive failures
- **Response caching**: Deduplicates identical prompts within 5 minutes
- **Graceful shutdown**: Agents disconnect cleanly before container teardown
- **Discord webhooks**: Start/stop notifications for monitoring
- **RCON enabled**: Experiment scripts can pause/resume MC saves for clean world snapshots

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `full-hybrid-setup.ps1` shows FAIL | Fix each failure, re-run the script |
| Docker Desktop not running | Start Docker Desktop, wait for engine ready |
| Ollama not responding | Run `.\setup-litellm.ps1` or start manually: `ollama serve` |
| Bot doesn't respond in-game | Check `docker compose logs -f mindcraft` for errors |
| Cloud bot API errors | Verify API keys in `.env`: `GEMINI_API_KEY`, `XAI_API_KEY` |
| Ensemble log empty | Bot hasn't received any messages yet — chat to it |
| Port 25565 in use | Stop any existing Minecraft servers |
| Health check timeout | Increase Docker Desktop memory (Settings → Resources → 8GB+) |
| World snapshot fails | Verify RCON: `docker exec minecraft-server rcon-cli save-hold` |
| Discord bot offline | Check `DISCORD_BOT_TOKEN` in `.env` |

---

## File Map

```
mindcraft-0.1.3/
├── start.ps1                    # Main launcher (local/cloud/both/stop/status)
├── full-hybrid-setup.ps1        # One-time master setup (8 checks)
├── setup-litellm.ps1            # Ollama + LiteLLM installer
├── deploy-to-aws.ps1            # One-command EC2 deployment
├── tailscale-setup.ps1          # Tailscale VPN automation (Windows 11)
├── docker-compose.yml           # All services with Compose profiles
├── .env                         # API keys + config (gitignored)
├── keys.json                    # Alternative API key storage (gitignored)
├── profiles/
│   ├── local-research.json      # LocalResearch_1 — Ollama on RTX 3090
│   ├── cloud-persistent.json    # CloudPersistent_1 — 4-panel ensemble
│   └── ensemble.json            # Ensemble_1 — standalone ensemble
├── src/ensemble/
│   ├── controller.js            # EnsembleModel class (sendRequest interface)
│   ├── panel.js                 # Parallel model querying
│   ├── arbiter.js               # Heuristic scoring + majority voting
│   ├── logger.js                # Decision log writer
│   └── feedback.js              # Outcome feedback (Phase 3)
├── services/
│   ├── litellm/litellm_config.yaml  # LiteLLM proxy config
│   └── discord-bot/discord-bot.js   # Discord command bot
├── experiments/
│   ├── new-experiment.ps1       # Create experiment directory
│   ├── start-experiment.ps1     # Run experiment (snapshot → launch → collect)
│   ├── run-ab-test.ps1          # Multi-variant A/B testing with stats
│   ├── backup-world.ps1         # World backup via RCON
│   ├── restore-world.ps1        # World restore
│   └── analyze.ps1              # Parse logs → research metrics + CSV
├── docs/
│   ├── RESEARCH-RIG.md          # This file
│   ├── PRODUCTION-DEPLOYMENT.md # EC2/hybrid deployment guide
│   └── TAILSCALE.md             # VPN setup for EC2 connectivity
└── bots/                        # Runtime bot data (gitignored)
    ├── LocalResearch_1/
    ├── CloudPersistent_1/
    └── Ensemble_1/
```
