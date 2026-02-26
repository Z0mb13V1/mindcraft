# Hybrid Research Rig — Setup Checklist

## What This Is

Two Minecraft AI bots in the same world:

| Bot | Name | Compute | Model | When |
|-----|------|---------|-------|------|
| Local | `LocalResearch_1` | RTX 3090 (Ollama) | sweaterdog/andy-4 | On-demand |
| Cloud | `CloudPersistent_1` | Gemini + Grok ensemble | 4-panel voting | 24/7 on EC2 |

Both connect to the same Minecraft server (local or EC2 via Tailscale).
The `start.ps1` launcher controls which combination runs.

---

## Prerequisites

- [ ] Windows 11 desktop with Docker Desktop installed and running
- [ ] PowerShell 5.1+ (comes with Windows)
- [ ] Git configured with SSH key for GitHub
- [ ] API keys: `GEMINI_API_KEY`, `XAI_API_KEY` in `.env` or `keys.json`
- [ ] NVIDIA GPU (RTX 3090 recommended for local bot)

---

## Phase 1 — Local Inference Setup

- [ ] **1.** Run the one-click Ollama setup:
  ```powershell
  .\setup-litellm.ps1
  ```
  This installs Ollama, pulls `sweaterdog/andy-4`, and optionally starts LiteLLM.

- [ ] **2.** Verify Ollama is running:
  ```powershell
  ollama list
  # Should show: sweaterdog/andy-4
  ```

- [ ] **3.** (Optional) Pull a larger model for higher quality:
  ```powershell
  .\setup-litellm.ps1 -PullLarge
  # Auto-selects based on VRAM: qwen2.5:32b (~24GB) or llama3.1:70b (~48GB)
  ```

---

## Phase 2 — Verify Profiles

- [ ] **4.** Confirm `profiles/local-research.json` exists:
  ```powershell
  Get-Content profiles\local-research.json | ConvertFrom-Json | Select name, model
  # name: LocalResearch_1, model: {api: ollama, model: sweaterdog/andy-4, ...}
  ```

- [ ] **5.** Confirm `profiles/cloud-persistent.json` exists:
  ```powershell
  Get-Content profiles\cloud-persistent.json | ConvertFrom-Json | Select name, ensemble
  # name: CloudPersistent_1, ensemble: {panel: [...], ...}
  ```

- [ ] **6.** Confirm API keys are set (for cloud bot):
  ```powershell
  # Either in .env:
  Get-Content .env | Select-String "GEMINI_API_KEY"
  # Or in keys.json:
  Get-Content keys.json | ConvertFrom-Json | Select gemini
  ```

---

## Phase 3 — Local Bot Test

- [ ] **7.** Start the local bot:
  ```powershell
  .\start.ps1 local
  ```
  (Starts: Minecraft server + Mindcraft with LocalResearch_1)

- [ ] **8.** Open the MindServer UI: http://localhost:8080/

- [ ] **9.** Open bot camera: http://localhost:3000/

- [ ] **10.** Join `localhost:25565` in Minecraft client and chat:
  ```
  LocalResearch_1, who are you?
  ```

- [ ] **11.** Verify the bot responds (Ollama inference working)

- [ ] **12.** Stop:
  ```powershell
  .\start.ps1 stop
  ```

---

## Phase 4 — Cloud Bot Test

- [ ] **13.** Start the cloud bot:
  ```powershell
  .\start.ps1 cloud
  ```
  (Starts: Minecraft server + Mindcraft with CloudPersistent_1)

- [ ] **14.** Join and chat:
  ```
  CloudPersistent_1, who are you?
  ```

- [ ] **15.** Verify ensemble decisions are logged:
  ```powershell
  Get-Content bots\CloudPersistent_1\ensemble_log.json | ConvertFrom-Json | Select -Last 3
  ```

- [ ] **16.** Stop:
  ```powershell
  .\start.ps1 stop
  ```

---

## Phase 5 — Both Bots Together

- [ ] **17.** Start both bots:
  ```powershell
  .\start.ps1 both
  ```
  (Starts: Minecraft + LocalResearch_1 + CloudPersistent_1)

- [ ] **18.** Join and observe both bots in the same world

- [ ] **19.** Test coordination — ask one bot about the other:
  ```
  LocalResearch_1, coordinate with CloudPersistent_1 to collect wood
  ```

- [ ] **20.** Verify both bots respond independently

- [ ] **21.** Stop:
  ```powershell
  .\start.ps1 stop
  ```

---

## Phase 6 — Experiment Framework

- [ ] **22.** Create an experiment:
  ```powershell
  .\experiments\new-experiment.ps1 -Name "first-test" -Description "Initial baseline" -Mode both -DurationMinutes 10
  ```

- [ ] **23.** Run the experiment (auto-starts bots, waits, collects logs):
  ```powershell
  .\experiments\start-experiment.ps1 -ExperimentDir .\experiments\<date>_first-test -Goal "Collect 64 wood logs"
  ```

- [ ] **24.** Analyze results:
  ```powershell
  .\experiments\analyze.ps1 -ExperimentDir .\experiments\<date>_first-test -Open
  ```

---

## Phase 7 — Tailscale (Connect to EC2 World)

Only needed if you want the local bot to join the persistent EC2 world instead of a local server.

- [ ] **25.** Install Tailscale on Windows: https://tailscale.com/download/windows

- [ ] **26.** Install on EC2 (via Instance Connect):
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --ssh
  tailscale ip -4   # note the EC2 Tailscale IP
  ```

- [ ] **27.** Verify connectivity:
  ```powershell
  ping <ec2-tailscale-ip>
  Test-NetConnection -ComputerName <ec2-tailscale-ip> -Port 25565
  ```

- [ ] **28.** Connect local bot to EC2 world:
  ```powershell
  .\start.ps1 local -McHost <ec2-tailscale-ip>
  ```
  Both bots are now in the same EC2 Minecraft world.

See [TAILSCALE.md](TAILSCALE.md) for detailed setup and troubleshooting.

---

## Quick Reference

```powershell
# Start modes
.\start.ps1 local                    # Local bot only (Ollama)
.\start.ps1 cloud                    # Cloud ensemble bot only
.\start.ps1 both                     # Both bots in same world
.\start.ps1 both -Detach             # Both in background
.\start.ps1 local -McHost 100.x.x.x # Local bot → EC2 world via Tailscale
.\start.ps1 stop                     # Stop everything

# Experiment workflow
.\experiments\new-experiment.ps1 -Name "test" -Mode both
.\experiments\start-experiment.ps1 -ExperimentDir .\experiments\<dir> -Goal "Mine diamonds"
.\experiments\analyze.ps1 -ExperimentDir .\experiments\<dir> -Open

# World management
.\experiments\backup-world.ps1 -Target .\backups\my-backup
.\experiments\restore-world.ps1 -BackupDir .\backups\my-backup

# Logs
docker compose logs -f mindcraft          # Bot activity
docker compose logs -f minecraft-server   # MC server
```
