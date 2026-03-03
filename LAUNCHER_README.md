# DragonSlayer Single-Click Launcher v4.0

One double-click to launch the entire DragonSlayer autonomous Ender Dragon speedrun bot on your RTX 3090.

## What It Does (Automatically)

| Step | Action |
|------|--------|
| 0 | Pre-flight: validates Node 20, npm, Ollama, NVIDIA GPU, CUDA, profile, `.env` |
| 1 | Starts Ollama server if not already running (with health-poll progress bar) |
| 2 | Pulls `sweaterdog/andy-4:q8_0` + `nomic-embed-text` + `llava` if missing |
| 3 | (Optional) Starts a local Paper 1.21.x MC server with EULA prompt |
| 4 | Launches DragonSlayer bot with **timestamped, colorized** live log output |
| 5 | Opens MindServer HUD in your default browser (`http://localhost:8080`) |
| 6 | **Sends `!beatMinecraft`** to start the dragon run (prompt or auto) |
| 7 | Shows a status dashboard with PID, server, model at a glance |
| 8 | Event loop: crash detection + press any key → graceful shutdown with session duration |
| 9 | **GitHub PR workflow**: commit changes, push to fork, create/update PR to upstream |

## Quick Start

### Option A: Double-Click (Easiest)

1. Double-click **`DragonSlayer.bat`** in the `mindcraft-0.1.3` folder
2. That's it. Everything happens automatically.

### Option B: PowerShell Direct

```powershell
cd "C:\Users\Name\Mindcraft\mindcraft-0.1.3"
.\DragonSlayer-Launcher.ps1
```

If you get an execution policy error:
```powershell
powershell -ExecutionPolicy Bypass -File .\DragonSlayer-Launcher.ps1
```

### Option C: Convert to .EXE (PS2EXE)

Turn the script into a standalone `.exe` you can pin to your taskbar:

```powershell
# 1. Install PS2EXE (one-time, from an elevated or user-scope shell)
Install-Module -Name ps2exe -Scope CurrentUser -Force

# 2. Convert to .exe (run from the mindcraft-0.1.3 folder)
cd "C:\Users\<YourName>\path\to\mindcraft-0.1.3"
Invoke-PS2EXE -InputFile  .\DragonSlayer-Launcher.ps1 `
              -OutputFile .\DragonSlayer.exe `
              -Title       "DragonSlayer Launcher" `
              -Description "Mindcraft DragonSlayer Autonomous Bot Launcher" `
              -Company     "Mindcraft Research" `
              -Version     "4.0.0" `
              -NoConsole:$false `
              -RequireAdmin:$false

# Optional: add a custom icon (.ico file in the same folder)
#   -IconFile .\dragon.ico

# 3. Done! Double-click DragonSlayer.exe or pin it to your taskbar.
#    Copy the whole folder to another machine and it just works.
```

The resulting `DragonSlayer.exe`:
- **No external dependencies** — PowerShell is built into Windows 10/11
- **No admin rights** required
- Double-click from anywhere, pin to Start Menu or Taskbar
- Portable: copy the whole folder to another machine and it just works

> **Tray icon / minimize-to-tray**: PS2EXE does not support tray icons natively.
> Options for tray-icon support:
> - [AutoHotkey](https://www.autohotkey.com/) — wrap the .exe in an AHK script with `Menu, Tray` commands
> - WPF wrapper — create a lightweight C# WPF app that hosts the launcher process
> - [Winsw](https://github.com/winsw/winsw) — run as a Windows Service (headless, no tray icon needed)

## Prerequisites

| Requirement | Version | Link |
|------------|---------|------|
| Windows | 10 or 11 | — |
| Node.js | v18+ (v20 LTS recommended; v24+ may cause issues) | https://nodejs.org/ |
| Ollama | Latest (with CUDA support) | https://ollama.com/download/windows |
| NVIDIA Driver | Latest Game Ready | https://www.nvidia.com/drivers |
| RTX 3090 | With working CUDA | — |
| Minecraft Server | Running on target host:port | Your EC2 or local server |
| GitHub CLI (`gh`) | Latest (for PR workflow) | https://cli.github.com/ |

## Configuration

Edit the `CONFIG` block at the top of `DragonSlayer-Launcher.ps1`:

```powershell
# ── Core ──
$PROFILE_PATH     = "./profiles/dragon-slayer.json"
$BOT_NAME         = "DragonSlayer"        # must match profile "name" field
$OLLAMA_MODELS    = @("sweaterdog/andy-4:q8_0", "nomic-embed-text", "llava")
$OLLAMA_PORT      = 11434                 # Ollama API port
$MINDSERVER_PORT  = 8080                  # MindServer HUD port
$MC_HOST          = "localhost"           # MC server host
$MC_PORT          = 42069                 # MC server port

# ── Paper server (optional) ──
$PAPER_JAR        = ""                    # Full path to paper-*.jar (blank = skip)
$PAPER_DIR        = ""                    # Server working directory
$PAPER_PORT       = 25565                 # Server port
$PAPER_RAM        = "4G"                  # Max heap (-Xmx)

# ── Auto-!beatMinecraft ──
$AUTO_BEAT_MC     = $false                # $true = send without prompting
$BEAT_MC_DELAY    = 15                    # Seconds to wait for bot to connect

# ── Cosmetics ──
$HUD_OPEN_DELAY   = 8                    # Seconds to poll before opening HUD
$LOG_TIMESTAMP    = $true                 # Prefix bot output with HH:mm:ss
```

### `!beatMinecraft` Auto-Send

After the bot starts, the launcher sends `!beatMinecraft` via Socket.IO to the MindServer. By default it prompts you — press Enter or type `Y` to confirm. To skip the prompt entirely:

```powershell
$AUTO_BEAT_MC = $true
```

The command is delivered via a temp `.mjs` file using the project's `socket.io-client` (no global installs needed). If MindServer isn't ready, it retries for 8 seconds then falls back gracefully with instructions to send manually.

### GitHub PR Workflow

After shutdown (only if the bot was actually launched), the launcher offers to commit your changes and create a Pull Request to upstream. Powered by the [`gh` CLI](https://cli.github.com/).

**Prerequisites:**
- `gh` CLI installed and authenticated (`gh auth login`)
- Git remotes configured: `fork` → your public fork, `upstream` → `mindcraft-bots/mindcraft`

**What it does (step by step):**
1. Checks `gh auth status` and `git status`
2. **Derives your GitHub username** from the `fork` remote URL (no hardcoded usernames)
3. Shows changed files with color-coded status
4. **Offers to create a feature branch** if you're on a protected branch (main/master/develop)
5. Prompts: "Submit as PR?" (Y/N, default N)
6. If yes: prompts for commit message, **confirms before `git add -A`** (warns about staging scope)
7. Commits, then **re-captures diff stats** so the PR body is accurate (not stale)
8. Pushes to your `fork` remote
9. Creates a new PR to upstream (or detects existing open PR via owner-qualified `--head` ref)
10. Optionally offers to merge (squash) — **skips `--delete-branch` for protected branches**

**Configuration:**
```powershell
$ENABLE_PR_WORKFLOW = $true                   # Set $false to disable entirely
$PR_FORK_REMOTE    = "fork"                   # Git remote name for your public fork
$PR_TARGET_REPO    = "mindcraft-bots/mindcraft"  # Upstream owner/repo
$PR_BASE_BRANCH    = "develop"                # Target branch for PRs
$PR_PROTECTED      = @('main', 'master', 'develop')  # Branches safe from --delete-branch
```

**To disable:** Set `$ENABLE_PR_WORKFLOW = $false` in the config block.

**v4.0 improvements over v3.1:**
- Fork owner derived dynamically from git remote (no hardcoded GitHub username)
- Feature branch creation when working on main/master/develop
- Staging confirmation before `git add -A` (prevents accidental secret exposure)
- PR body uses post-commit diff stats (not stale pre-commit status)
- `$LASTEXITCODE` captured before piping (PS 5.1 compatibility)
- `--delete-branch` skipped for protected branches (won't delete main)
- Owner-qualified `--head` ref for reliable cross-repo PR detection
- PR workflow only runs if bot was actually launched (skips on pre-flight failure)

### Enable Local Paper Server

1. Download Paper from https://papermc.io/downloads
2. Put the jar in a folder (e.g., `C:\MCServer\paper-1.21.11.jar`)
3. Edit the launcher config:
   ```powershell
   $PAPER_JAR  = "C:\MCServer\paper-1.21.11.jar"
   $PAPER_DIR  = "C:\MCServer"
   $PAPER_RAM  = "4G"
   ```
4. On first run, the launcher prompts you to accept the Minecraft EULA
5. Update `settings.js` to point to your local server:
   ```js
   "host": "localhost",
   "port": 25565,
   ```

## Log Color Coding

The live bot output is colorized by keyword for quick scanning:

| Color | Keywords |
|-------|----------|
| **Red** | error, exception, FATAL, ECONNREFUSED |
| **Yellow** | warn, deprecated |
| **Magenta** | dragon, ender, beat minecraft, victory, progression |
| **Green** | connected, ready, started, logged in, spawned |
| **Blue** | nether, blaze, stronghold, portal, fortress |
| **Teal** | diamond, iron, craft, smelt, enchant, bucket |
| **Gray** | Everything else |

Timestamps (when `$LOG_TIMESTAMP = $true`): `  14:32:07 BOT | Crafting iron pickaxe...`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Ollama not installed" | Install from https://ollama.com/download/windows |
| "Node.js not found" | Install from https://nodejs.org/ (v20 LTS) |
| "Node.js v24+" warning | Downgrade to v20 LTS — v24+ may cause compatibility issues |
| Model pull fails | Run manually: `ollama pull sweaterdog/andy-4:q8_0` |
| Bot can't connect to MC | Ensure server is running on the configured host:port |
| "npm install failed" | Delete `node_modules/` + `package-lock.json`, re-run launcher |
| Script won't run | Use the `.bat` file or: `powershell -ExecutionPolicy Bypass -File .\DragonSlayer-Launcher.ps1` |
| CUDA not detected | Update NVIDIA drivers, restart, verify with `nvidia-smi` |
| Bot crashes immediately | Check logs in `bots/DragonSlayer/` |
| `!beatMinecraft` not sent | MindServer may not be ready; send from HUD chat or in-game |
| "socket.io-client not found" | Run `npm install` to restore dependencies |
| Paper EULA rejected | Re-run launcher and accept, or manually create `eula.txt` with `eula=true` |
| PR workflow skipped | Install `gh` CLI and run `gh auth login` |
| PR creation fails | Ensure `fork` remote points to your public fork on GitHub |
| "Not a git repository" | Ensure the launcher is inside the cloned mindcraft repo |

## File Layout

```
mindcraft-0.1.3/
├── DragonSlayer.bat              ← Double-click this
├── DragonSlayer-Launcher.ps1     ← The engine (PowerShell, v4.0)
├── DragonSlayer.exe              ← (after PS2EXE conversion)
├── LAUNCHER_README.md            ← This file
├── docs/                         ← Research docs, Notebook LLM exports, mod pack notes
│   └── index.md                  ← Docs table of contents
├── main.js
├── settings.js
├── profiles/
│   └── dragon-slayer.json
├── bots/
│   └── DragonSlayer/             ← Bot state & logs
└── ...
```
