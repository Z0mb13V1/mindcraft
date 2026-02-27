# Production Deployment Guide

How to deploy the Mindcraft research rig for weeks-long unattended operation.

---

## Deployment Modes

| Mode | Where | Script | Best For |
|------|-------|--------|----------|
| **Local only** | Your desktop | `.\start.ps1 local` | Development, testing, free inference |
| **Cloud only** | Your desktop | `.\start.ps1 cloud` | Cloud ensemble testing |
| **Both bots** | Your desktop | `.\start.ps1 both` | Full research rig |
| **EC2 cloud** | AWS EC2 | `.\deploy-to-aws.ps1` | 24/7 persistent cloud bot |
| **Hybrid** | Desktop + EC2 | Start local + Tailscale | Best of both worlds |

---

## Local Desktop Deployment

### Prerequisites
- Windows 11 with Docker Desktop
- NVIDIA GPU (RTX 3090 recommended) for local inference
- Ollama installed: `.\setup-litellm.ps1`

### Start
```powershell
.\full-hybrid-setup.ps1        # One-time setup (checks everything)
.\start.ps1 both -Detach       # Launch both bots
.\start.ps1 status             # Verify health
```

### 24/7 Considerations
- Docker Desktop must remain running (Settings > General > Start at login)
- Windows power plan: **High Performance** (prevents sleep)
- Log rotation: configured at 10-100MB per service (docker-compose.yml)
- restart: unless-stopped ensures bots survive crashes
- Cost: ~$2-5/day for cloud API calls; local inference is free

---

## AWS EC2 Deployment

### One-Command Deploy

```powershell
# Deploy to your existing EC2 instance
.\deploy-to-aws.ps1

# Or specify an instance
.\deploy-to-aws.ps1 -InstanceId i-07340d0ddc3ac2bc5

# Just check status
.\deploy-to-aws.ps1 -StatusOnly

# Start a stopped instance
.\deploy-to-aws.ps1 -StartOnly
```

### What It Does
1. Verifies AWS CLI credentials
2. Starts the EC2 instance if stopped
3. Uploads your .env (API keys) via SSM
4. Installs Docker and Docker Compose if needed
5. Clones/updates the repo
6. Runs `docker compose up -d`
7. Returns connection info

### Manual EC2 Setup (if script fails)

Connect via EC2 Instance Connect (browser), then:

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu
sudo systemctl enable docker

# Clone repo
git clone https://github.com/Z0mb13V1/mindcraft-0.1.3.git ~/mindcraft
cd ~/mindcraft

# Create .env with API keys
cat > .env << 'EOF'
GEMINI_API_KEY=your-key
XAI_API_KEY=your-key
DISCORD_BOT_TOKEN=your-token
BOT_DM_CHANNEL=your-channel-id
BACKUP_CHAT_CHANNEL=your-channel-id
DISCORD_ADMIN_IDS=your-discord-user-id
EOF

# Start services
docker compose -f docker-compose.aws.yml up -d

# Check status
docker compose -f docker-compose.aws.yml ps
docker compose -f docker-compose.aws.yml logs -f mindcraft
```

### EC2 Instance Sizing

| Instance | vCPU | RAM | Cost/mo | Good For |
|----------|------|-----|---------|----------|
| t3.small | 2 | 2GB | ~$15 | MC server only |
| t3.medium | 2 | 4GB | ~$30 | MC + 1 bot |
| t3.large | 2 | 8GB | ~$60 | MC + ensemble bot + Discord |
| t3.xlarge | 4 | 16GB | ~$120 | Everything with headroom |

Recommended: **t3.medium** for CloudGrok bot (API calls are the bottleneck, not CPU).

### Security Group Rules

| Port | Source | Purpose |
|------|--------|---------|
| 22 | Your IP | SSH access |
| 25565 | 0.0.0.0/0 (or Tailscale) | Minecraft server |
| 8080 | Your IP | MindServer UI |
| 3000-3003 | Your IP | Bot cameras |

---

## Hybrid Deployment (Local + EC2)

The most powerful configuration: local RTX 3090 bot + cloud ensemble bot on EC2, both in the same Minecraft world.

### Setup

```powershell
# 1. Deploy cloud bot to EC2
.\deploy-to-aws.ps1

# 2. Set up Tailscale VPN
.\tailscale-setup.ps1 -Ec2Ip <ec2-public-ip>

# 3. Install Tailscale on EC2 (via Instance Connect)
# curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --ssh

# 4. Re-run with EC2 Tailscale IP
.\tailscale-setup.ps1 -Ec2Ip <ec2-tailscale-ip>

# 5. Start local bot pointing to EC2 Minecraft server
.\start.ps1 local -McHost <ec2-tailscale-ip> -Detach
```

### Architecture

```
Desktop (RTX 3090)          Tailscale VPN           AWS EC2 (t3.medium)
┌──────────────────┐        ═══════════════        ┌──────────────────┐
│ Ollama           │                               │ MC Server :25565 │
│ LocalAndy        │────── 100.x.x.x ──────────── │ CloudGrok        │
│ MindServer :8080 │       (encrypted)             │ Discord Bot      │
│ Docker           │                               │ ChromaDB         │
└──────────────────┘                               └──────────────────┘
```

Both bots share one Minecraft world on EC2. Local bot uses free GPU inference; cloud bot uses API ensemble.

---

## Monitoring

### Health Checks

```powershell
.\start.ps1 status              # Local container health + endpoints
.\deploy-to-aws.ps1 -StatusOnly # EC2 instance status
```

### Discord Monitoring

The Discord bot provides remote visibility:
- `!status` — MindServer connection + agent status
- `!agents` — List all agents with in-game status
- `!usage all` — API cost breakdown
- Start/stop/restart bots remotely

### Logs

```powershell
# Local
docker compose logs -f mindcraft          # Bot activity
docker compose logs -f minecraft-server   # MC server
docker compose logs -f discord-bot        # Discord bot

# EC2 (via SSH/Tailscale)
ssh ubuntu@<tailscale-ip> 'cd ~/mindcraft && docker compose logs --tail 100 mindcraft'
```

### Discord Webhook Notifications

Set `BACKUP_WEBHOOK_URL` in `.env` to receive operational notifications:
- Bot start/stop events
- A/B test progress updates
- Crash alerts (from container restart)

---

## Cost Management

### API Costs (estimated daily)

| Model | Input | Output | Daily (typical) |
|-------|-------|--------|-----------------|
| Gemini 2.5 Pro | Free tier | Free tier | ~$0-2 |
| Gemini 2.5 Flash | Free tier | Free tier | ~$0-1 |
| Grok Fast | $5/M | $25/M | ~$1-3 |
| Grok Code | $5/M | $25/M | ~$0.50-1 |
| **Ensemble total** | | | **~$2-5/day** |
| Ollama (local) | Free | Free | $0 |

### EC2 Costs

- t3.medium: ~$1/day ($30/month)
- Savings: Use Spot Instances for 60-70% discount
- Or: Stop instance when not running experiments

### Cost Monitoring

```powershell
# Via Discord
!usage all

# Via experiment analysis
.\experiments\analyze.ps1 -ExperimentDir <dir>
# Outputs cost_per_command and total cost
```

---

## Disaster Recovery

### World Backups

```powershell
# Manual backup
.\experiments\backup-world.ps1 -Target .\backups\manual-save

# EC2: S3 automatic backups (docker-compose.aws.yml)
# - Runs daily at 3 AM UTC
# - 7-day retention in s3://mindcraft-world-backups-*
```

### Restore

```powershell
.\experiments\restore-world.ps1 -BackupDir .\backups\manual-save
```

### If Something Goes Wrong

| Problem | Recovery |
|---------|----------|
| Bot crashes | `restart: unless-stopped` auto-recovers. Check logs. |
| MC server crashes | Auto-restarts. World data persists in volume. |
| EC2 instance stops | `.\deploy-to-aws.ps1 -StartOnly` |
| API keys expire | Update `.env`, run `docker compose restart mindcraft` |
| Disk full | Logs rotate automatically. Clear old experiments. |
| ChromaDB corruption | Delete chromadb volume, bot rebuilds memory over time |
| Network partition | Tailscale auto-reconnects. Docker services restart. |

---

## Maintenance Schedule

For weeks-long operation:

| Frequency | Task |
|-----------|------|
| Daily | Check `!status` via Discord |
| Weekly | Review `!usage all` for cost tracking |
| Weekly | Clear completed experiments: `rm -r experiments/20*` (keep scripts) |
| Monthly | Update Docker images: `docker compose pull` |
| Monthly | Update Ollama models: `ollama pull sweaterdog/andy-4` |
| As needed | Rotate API keys in `.env` |
