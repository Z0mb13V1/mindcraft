<#
.SYNOPSIS
    DragonSlayer One-Click Launcher for Mindcraft v4.0
    RTX 3090 / CUDA Ollama / Windows 10-11
.DESCRIPTION
    Production-ready launcher that:
      0. Validates every prerequisite (Node 20, npm, Ollama, CUDA GPU, profile)
      1. Starts Ollama daemon if not already running
      2. Pulls required models (andy-4 q8_0 + nomic-embed-text + llava)
      3. (Optional) Starts a local Paper 1.21.x MC server with EULA prompt
      4. Launches DragonSlayer bot with live timestamped colorized log output
      5. Opens the MindServer HUD in the default browser
      6. (Optional) Sends !beatMinecraft via Socket.IO to start the dragon run
      7. Monitors for crash/keypress, then tears down everything gracefully
      8. (Optional) GitHub PR workflow: commit, push to fork, create/update PR
         - Derives fork owner dynamically from git remote URL
         - Feature branch creation when on a protected branch
         - Staging confirmation before git add -A
         - Safe merge (skips --delete-branch for protected branches)
.NOTES
    Author  : Mindcraft Research Rig
    Version : 4.0.0
    Date    : 2025-07-18
    License : MIT
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
#  CONFIG  —  Edit these values to match your environment
# ═══════════════════════════════════════════════════════════════════════════════
$SCRIPT_DIR       = $PSScriptRoot                           # Folder this .ps1 lives in
$MINDCRAFT_DIR    = $SCRIPT_DIR                             # Project root (same folder)
$PROFILE_PATH     = "./profiles/dragon-slayer.json"         # Bot profile (relative)
$BOT_NAME         = "DragonSlayer"                          # Must match profile "name"
$OLLAMA_MODELS    = @(                                      # Models to ensure are pulled
    "sweaterdog/andy-4:q8_0"
    "nomic-embed-text"
    "llava"
)
$OLLAMA_PORT      = 11434                                   # Ollama API port
$MINDSERVER_PORT  = 8080                                    # MindServer HUD port
$MINDSERVER_URL   = "http://localhost:$MINDSERVER_PORT"
$MC_HOST          = "localhost"                              # Minecraft server host
$MC_PORT          = 42069                                   # Minecraft server port

# ── Paper server (optional — leave blank to skip) ──
$PAPER_JAR        = ""                                      # Full path to paper-*.jar
$PAPER_DIR        = ""                                      # Server working directory
$PAPER_PORT       = 25565                                   # Server port
$PAPER_RAM        = "4G"                                    # Max heap (-Xmx)

# ── Auto-!beatMinecraft ──
$AUTO_BEAT_MC     = $false                                  # $true = send without prompting
$BEAT_MC_DELAY    = 15                                      # Seconds to wait after bot start

# ── Cosmetics ──
$HUD_OPEN_DELAY   = 8                                       # Seconds to poll before opening HUD
$LOG_TIMESTAMP    = $true                                   # Prefix bot output with HH:mm:ss

# ── GitHub PR workflow (requires `gh` CLI authenticated) ──
$ENABLE_PR_WORKFLOW = $true                                 # Offer PR submission on shutdown
$PR_FORK_REMOTE    = "fork"                                 # Git remote pointing to your public fork
$PR_TARGET_REPO    = "mindcraft-bots/mindcraft"             # Upstream repo (owner/name)
$PR_BASE_BRANCH    = "develop"                              # Target branch for PRs
$PR_PROTECTED      = @('main', 'master', 'develop')          # Branches that --delete-branch skips

# ═══════════════════════════════════════════════════════════════════════════════
#  STATE VARIABLES  (do not edit)
# ═══════════════════════════════════════════════════════════════════════════════
$script:OllamaStartedByUs = $false
$script:BotProcess         = $null
$script:PaperProcess       = $null
$script:LaunchTime         = $null
$script:StepCounter        = 0

# ═══════════════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Banner {
    $dragon = @"

       ___                              ____  __
      / _ \ _ __ __ _  __ _  ___  _ __ / ___|| | __ _ _   _  ___ _ __
     / / \ \ '__/ _`  |/ _`  |/ _ \| '_ \\___ \| |/ _`  | | | |/ _ \ '__|
    / /_/ / | | (_| | (_| | (_) | | | |___) | | (_| | |_| |  __/ |
   /_____/|_|  \__,_|\__, |\___/|_| |_|____/|_|\__,_|\__, |\___|_|
                      |___/                            |___/
"@
    Write-Host ""
    Write-Host $dragon -ForegroundColor Red

    $sub = @"
    +===============================================================+
    |  Mindcraft Autonomous Ender-Dragon Speedrun  -  Launcher v4   |
    |  GPU: NVIDIA GeForce RTX 3090  -  Model: andy-4 q8_0         |
    +===============================================================+
"@
    Write-Host $sub -ForegroundColor DarkRed
    Write-Host ""
}

function Write-Section ([string]$title) {
    $script:StepCounter++
    $n = $script:StepCounter
    Write-Host ""
    Write-Host "  -- Step $n : $title -----------------------------------------------" -ForegroundColor White
}

function Write-Step  ([string]$msg) { Write-Host "  [*] $msg" -ForegroundColor Cyan }
function Write-Ok    ([string]$msg) { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn  ([string]$msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Err   ([string]$msg) { Write-Host "  [-] $msg" -ForegroundColor Red }
function Write-Info  ([string]$msg) { Write-Host "      $msg" -ForegroundColor DarkGray }

function Write-ProgressBar ([string]$label, [int]$pct) {
    $pct    = [math]::Max(0, [math]::Min(100, $pct))
    $filled = [math]::Floor($pct / 2)
    $empty  = 50 - $filled
    $bar    = ([char]0x2588).ToString() * $filled + ([char]0x2591).ToString() * $empty
    Write-Host "`r  [$bar] $($pct.ToString().PadLeft(3))%  $label    " -NoNewline -ForegroundColor Magenta
}

function Write-ProgressDone { Write-Host "" }   # newline after a progress bar

function Write-Box ([string[]]$lines, [ConsoleColor]$color = 'Yellow') {
    $maxLen = ($lines | Measure-Object -Property Length -Maximum).Maximum
    $w = $maxLen + 4
    $top = "+" + ("-" * $w) + "+"
    $bot = "+" + ("-" * $w) + "+"
    Write-Host "  $top" -ForegroundColor $color
    foreach ($l in $lines) {
        $pad = ' ' * ($maxLen - $l.Length)
        Write-Host "  |  $l$pad  |" -ForegroundColor $color
    }
    Write-Host "  $bot" -ForegroundColor $color
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 0 — PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════
function Test-Prerequisites {
    Write-Section "Pre-Flight Checks"
    $pass = $true

    # ── Node.js ──
    $nodeVer = $null
    try { $nodeVer = (node --version 2>$null) } catch {}
    if (-not $nodeVer) {
        Write-Err "Node.js not found!"
        Write-Info "Install Node.js v20 LTS  ->  https://nodejs.org/"
        $pass = $false
    } else {
        $major = [int]($nodeVer -replace '^v','').Split('.')[0]
        if ($major -lt 18) {
            Write-Err "Node.js $nodeVer is too old (need v18+). Get v20 LTS: https://nodejs.org/"
            $pass = $false
        } elseif ($major -ge 24) {
            Write-Warn "Node.js $nodeVer  (v24+ may have compatibility issues; v20 LTS recommended)"
        } else {
            Write-Ok "Node.js $nodeVer"
        }
    }

    # ── npm ──
    $npmVer = $null
    try { $npmVer = (npm --version 2>$null) } catch {}
    if (-not $npmVer) {
        Write-Err "npm not found! Reinstall Node.js: https://nodejs.org/"
        $pass = $false
    } else {
        Write-Ok "npm v$npmVer"
    }

    # ── Ollama ──
    $ollamaCmd = $null
    try { $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue } catch {}
    if (-not $ollamaCmd) {
        Write-Err "Ollama not installed!"
        Write-Info "Download  ->  https://ollama.com/download/windows"
        $pass = $false
    } else {
        Write-Ok "Ollama: $($ollamaCmd.Source)"
    }

    # ── NVIDIA GPU ──
    try {
        $gpuInfo = nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null
        if ($gpuInfo) {
            Write-Ok "GPU: $($gpuInfo.Trim())"
        } else { throw "no output" }
    } catch {
        Write-Warn "nvidia-smi not found -- CUDA acceleration may be unavailable"
        Write-Info "Get drivers  ->  https://www.nvidia.com/drivers"
    }

    # ── CUDA version ──
    try {
        $cudaLine = (nvidia-smi 2>$null) | Select-String "CUDA Version"
        if ($cudaLine) {
            $cudaVer = ($cudaLine.ToString() -replace '.*CUDA Version:\s*','').Trim(' |')
            Write-Ok "CUDA $cudaVer"
        }
    } catch {}

    # ── Mindcraft project ──
    $pkgJson = Join-Path $MINDCRAFT_DIR "package.json"
    if (-not (Test-Path $pkgJson)) {
        Write-Err "Mindcraft project not found at: $MINDCRAFT_DIR"
        Write-Info "Place this script inside the mindcraft-0.1.3/ folder."
        $pass = $false
    } else {
        Write-Ok "Mindcraft project root OK"
    }

    # ── .env / keys ──
    $envFile  = Join-Path $MINDCRAFT_DIR ".env"
    $keysFile = Join-Path $MINDCRAFT_DIR "keys.json"
    if (Test-Path $envFile) {
        Write-Ok ".env present"
    } elseif (Test-Path $keysFile) {
        Write-Ok "keys.json present (no .env)"
    } else {
        Write-Info "No .env or keys.json -- API keys must come from environment variables"
    }

    # ── node_modules ──
    $nmDir = Join-Path $MINDCRAFT_DIR "node_modules"
    if (-not (Test-Path $nmDir)) {
        Write-Warn "node_modules/ missing -- installing dependencies..."
        Push-Location $MINDCRAFT_DIR
        try {
            $out = npm install 2>&1
            $out | ForEach-Object { Write-Info $_ }
            if ($LASTEXITCODE -ne 0) { throw "npm install exited with code $LASTEXITCODE" }
            Write-Ok "npm install succeeded"
        } catch {
            Write-Err "npm install failed: $_"
            Write-Info "Try deleting node_modules/ and package-lock.json, then run: npm install"
            Pop-Location
            $pass = $false
        }
        Pop-Location
    } else {
        Write-Ok "node_modules/ present"
    }

    # ── Bot profile ──
    $profileFull = Join-Path $MINDCRAFT_DIR ($PROFILE_PATH -replace '^\.\/', '')
    if (-not (Test-Path $profileFull)) {
        Write-Err "Profile not found: $profileFull"
        Write-Info "Expected: $PROFILE_PATH"
        $pass = $false
    } else {
        Write-Ok "Profile: $PROFILE_PATH"
    }

    if ($pass) {
        Write-Host ""
        Write-Ok "All pre-flight checks passed!"
    }
    return $pass
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — START OLLAMA
# ═══════════════════════════════════════════════════════════════════════════════
function Start-OllamaServer {
    Write-Section "Ollama Server"
    $baseUrl = "http://localhost:$OLLAMA_PORT"

    # Already running?
    $running = $false
    try {
        $r = Invoke-WebRequest -Uri "$baseUrl/api/tags" -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $running = $true }
    } catch {}

    if ($running) {
        Write-Ok "Ollama already running on :$OLLAMA_PORT"
        return $true
    }

    Write-Step "Starting Ollama daemon..."
    $ollamaExe = (Get-Command ollama).Source
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName               = $ollamaExe
    $si.Arguments              = "serve"
    $si.UseShellExecute        = $false
    $si.CreateNoWindow         = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($si)
    $script:OllamaStartedByUs = $true

    # Poll until healthy
    $ready = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri "$baseUrl/api/tags" -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
        Write-ProgressBar "Ollama starting..." ([math]::Min(95, $i * 2 + 5))
    }
    Write-ProgressDone

    if ($ready) {
        Write-Ok "Ollama started (PID $($proc.Id))"
        return $true
    }

    Write-Err "Ollama did not become healthy within 20 s"
    Write-Info "Try running 'ollama serve' in another terminal, then re-launch."
    return $false
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 2 — PULL MODELS
# ═══════════════════════════════════════════════════════════════════════════════
function Install-OllamaModels {
    Write-Section "Ollama Models"
    $baseUrl = "http://localhost:$OLLAMA_PORT"

    # Fetch installed list once
    $installed = @()
    try {
        $json = (Invoke-WebRequest -Uri "$baseUrl/api/tags" -TimeoutSec 10).Content |
                    ConvertFrom-Json
        $installed = $json.models | ForEach-Object { $_.name }
    } catch {
        Write-Warn "Could not query installed models: $_"
    }

    $total = $OLLAMA_MODELS.Count
    $idx   = 0
    foreach ($model in $OLLAMA_MODELS) {
        $idx++
        $tag = "[$idx/$total]"

        # Match: exact, with :latest suffix, or prefix match
        $found = $false
        foreach ($inst in $installed) {
            if ($inst -eq $model -or $inst -eq "${model}:latest" -or $inst.StartsWith("${model}:")) {
                $found = $true; break
            }
        }

        if ($found) {
            Write-Ok "$tag $model  (ready)"
            continue
        }

        Write-Step "$tag Pulling $model -- first run downloads the full model..."
        try {
            $p = Start-Process -FilePath "ollama" -ArgumentList "pull $model" `
                 -NoNewWindow -PassThru -Wait
            if ($p.ExitCode -eq 0) {
                Write-Ok "$tag $model  (pulled)"
            } else {
                Write-Err "$tag Pull failed (exit $($p.ExitCode)). Try: ollama pull $model"
                return $false
            }
        } catch {
            Write-Err "$tag Error pulling ${model}: $_"
            return $false
        }
    }
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 3 (OPTIONAL) — LOCAL PAPER MC SERVER
# ═══════════════════════════════════════════════════════════════════════════════
function Start-LocalPaperServer {
    # Skip entirely when no jar configured
    if (-not $PAPER_JAR -or -not (Test-Path $PAPER_JAR)) { return }

    Write-Section "Local Paper MC Server"
    Write-Box @(
        "Paper 1.21.x server JAR detected!"
        "Start it for local testing?  (Y/N)"
    ) Yellow

    $choice = Read-Host "  Start local server? [y/N]"
    if ($choice -notmatch '^[Yy]') {
        Write-Info "Skipped local Paper server."
        return
    }

    # Java check
    Write-Step "Checking Java..."
    try {
        $javaOut = java -version 2>&1
        $javaVer = ($javaOut | Select-Object -First 1).ToString()
        Write-Ok "Java: $javaVer"
    } catch {
        Write-Err "Java not found! Paper MC requires Java 21+."
        Write-Info "Download  ->  https://adoptium.net/"
        return
    }

    $serverDir = if ($PAPER_DIR) { $PAPER_DIR } else { Split-Path $PAPER_JAR -Parent }

    # EULA
    $eulaFile = Join-Path $serverDir "eula.txt"
    $eulaOk = $false
    if ((Test-Path $eulaFile) -and ((Get-Content $eulaFile -Raw) -match 'eula=true')) {
        $eulaOk = $true
    }
    if (-not $eulaOk) {
        Write-Warn "Minecraft EULA has not been accepted."
        Write-Info "Review: https://aka.ms/MinecraftEULA"
        $accept = Read-Host "  Accept EULA? [y/N]"
        if ($accept -match '^[Yy]') {
            "eula=true" | Set-Content -Path $eulaFile -Encoding UTF8
            Write-Ok "EULA accepted"
        } else {
            Write-Warn "Cannot start server without accepting the EULA."
            return
        }
    }

    Write-Step "Starting Paper on port $PAPER_PORT (Xmx=$PAPER_RAM)..."
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName               = "java"
    $si.Arguments              = "-Xms1G -Xmx$PAPER_RAM -jar `"$PAPER_JAR`" --port $PAPER_PORT --nogui"
    $si.WorkingDirectory       = $serverDir
    $si.UseShellExecute        = $false
    $si.CreateNoWindow         = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError  = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($si)
        $script:PaperProcess = $proc
        Write-Ok "Paper starting (PID $($proc.Id)) on :$PAPER_PORT"
        Write-Info "Server needs ~30 s to fully load. The bot auto-retries connections."
        Start-Sleep -Seconds 3
    } catch {
        Write-Warn "Failed to start Paper: $_"
        Write-Warn "Continuing without local server."
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 4 — START THE BOT
# ═══════════════════════════════════════════════════════════════════════════════
function Start-MindcraftBot {
    Write-Section "DragonSlayer Bot"
    Write-Step "Launching: node main.js --profiles $PROFILE_PATH"

    Push-Location $MINDCRAFT_DIR
    $nodeExe = (Get-Command node).Source

    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName               = $nodeExe
    $si.Arguments              = "main.js --profiles $PROFILE_PATH"
    $si.WorkingDirectory       = $MINDCRAFT_DIR
    $si.UseShellExecute        = $false
    $si.CreateNoWindow         = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError  = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $si
    $proc.EnableRaisingEvents = $true

    # ── Colorized async log handlers ──
    $useTs = $LOG_TIMESTAMP
    $outputAction = {
        if ([string]::IsNullOrEmpty($EventArgs.Data)) { return }
        $line = $EventArgs.Data
        $prefix = if ($Event.MessageData) { (Get-Date).ToString("HH:mm:ss ") } else { "" }
        $tag = "  ${prefix}BOT | "

        $color = switch -Regex ($line) {
            'error|Error|ERROR|exception|Exception|FATAL|ECONNREFUSED'  { 'Red';      break }
            'warn|Warn|WARN|deprecated'                                 { 'Yellow';   break }
            'dragon|Dragon|DRAGON|ender|Ender|beat\s*minecraft'         { 'Magenta';  break }
            'victory|Victory|VICTORY|completed|progression'             { 'Magenta';  break }
            'connected|ready|started|logged.in|spawned|Logged in'       { 'Green';    break }
            'nether|blaze|stronghold|portal|end.portal|fortress'        { 'Blue';     break }
            'diamond|iron|craft|smelt|enchant|bucket'                   { 'DarkCyan'; break }
            default                                                      { 'Gray' }
        }
        Write-Host "$tag$line" -ForegroundColor $color
    }

    $errorAction = {
        if ([string]::IsNullOrEmpty($EventArgs.Data)) { return }
        $prefix = if ($Event.MessageData) { (Get-Date).ToString("HH:mm:ss ") } else { "" }
        Write-Host "  ${prefix}BOT | $($EventArgs.Data)" -ForegroundColor DarkYellow
    }

    Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived `
        -Action $outputAction -MessageData $useTs | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived `
        -Action $errorAction -MessageData $useTs | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $script:BotProcess = $proc
    $script:LaunchTime = Get-Date
    Pop-Location

    Write-Ok "Bot launched (PID $($proc.Id))"
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 5 — OPEN HUD IN BROWSER
# ═══════════════════════════════════════════════════════════════════════════════
function Open-MindServerHUD {
    Write-Section "MindServer HUD"
    Write-Step "Waiting for $MINDSERVER_URL ..."

    $ready    = $false
    $maxPolls = $HUD_OPEN_DELAY * 2   # poll every 500ms
    for ($i = 0; $i -lt $maxPolls; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri $MINDSERVER_URL -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($r.StatusCode -eq 200) { $ready = $true; break }
        } catch {}
        Write-ProgressBar "MindServer..." ([math]::Min(95, [math]::Floor(($i+1) / $maxPolls * 100)))
    }
    Write-ProgressDone

    if ($ready) {
        Start-Process $MINDSERVER_URL
        Write-Ok "HUD opened in browser: $MINDSERVER_URL"
    } else {
        Write-Warn "MindServer not responding yet."
        Write-Info "Open manually when ready: $MINDSERVER_URL"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  STEP 6 — SEND !beatMinecraft VIA SOCKET.IO
# ═══════════════════════════════════════════════════════════════════════════════
function Send-BeatMinecraftCommand {
    param([bool]$SkipPrompt = $false)

    Write-Section "Dragon Run Command"

    if (-not $SkipPrompt) {
        Write-Box @(
            "Send !beatMinecraft to start the dragon run?"
            "(The bot must be connected to the MC server)"
        ) Magenta

        $choice = Read-Host "  Send !beatMinecraft? [Y/n]"
        if ($choice -match '^[Nn]') {
            Write-Info "Skipped. Send manually from the HUD or in-game chat."
            return
        }
    } else {
        Write-Step "AUTO_BEAT_MC is enabled -- will send automatically."
    }

    # Wait for bot to finish joining the server
    Write-Step "Waiting $BEAT_MC_DELAY s for bot to connect to Minecraft..."
    for ($i = 0; $i -lt $BEAT_MC_DELAY; $i++) {
        Start-Sleep -Seconds 1
        Write-ProgressBar "Bot connecting..." ([math]::Floor(($i + 1) / $BEAT_MC_DELAY * 100))
    }
    Write-ProgressDone

    # Verify socket.io-client is available in node_modules
    $nmSocket = Join-Path $MINDCRAFT_DIR "node_modules" "socket.io-client"
    if (-not (Test-Path $nmSocket)) {
        Write-Warn "socket.io-client not found in node_modules/."
        Write-Info "Run 'npm install' then retry, or send the command from the HUD."
        return
    }

    # Write a temp .mjs file to avoid shell-quoting issues
    $nodeExe = (Get-Command node).Source
    $tempJs  = Join-Path $env:TEMP "ds_beat_mc_$PID.mjs"
    $jsCode  = @"
import { io } from 'socket.io-client';
const url  = 'http://localhost:$MINDSERVER_PORT';
const bot  = '$BOT_NAME';
const cmd  = '!beatMinecraft';
const sock = io(url, { reconnection: false, timeout: 5000 });
sock.on('connect', () => {
    sock.emit('send-message', bot, { from: 'ADMIN', message: cmd });
    console.log('Sent ' + cmd + ' to ' + bot + ' via ' + url);
    setTimeout(() => process.exit(0), 600);
});
sock.on('connect_error', (e) => {
    console.error('Connection failed: ' + e.message);
    process.exit(1);
});
setTimeout(() => { console.error('Timeout connecting to MindServer'); process.exit(1); }, 8000);
"@
    # Save any pre-existing NODE_PATH so we can restore it after
    $origNodePath = $env:NODE_PATH
    try {
        $jsCode | Set-Content -Path $tempJs -Encoding UTF8 -Force

        # Run with the project's node_modules on the resolve path
        $env:NODE_PATH = Join-Path $MINDCRAFT_DIR "node_modules"
        $result = & $nodeExe $tempJs 2>&1
        $code   = $LASTEXITCODE

        if ($code -eq 0) {
            Write-Ok "!beatMinecraft sent to $BOT_NAME -- dragon run initiated!"
            $msg = ($result | Out-String).Trim()
            if ($msg) { Write-Info $msg }
        } else {
            Write-Warn "Could not send !beatMinecraft automatically (exit $code)."
            $msg = ($result | Out-String).Trim()
            if ($msg) { Write-Info $msg }
            Write-Info "Send it manually from the HUD chat box or type in Minecraft."
        }
    } catch {
        Write-Warn "Failed to send command: $_"
        Write-Info "Send !beatMinecraft manually from the HUD or in-game chat."
    } finally {
        Remove-Item $tempJs -Force -ErrorAction SilentlyContinue
        # Restore original NODE_PATH (or remove if there wasn't one)
        if ($origNodePath) { $env:NODE_PATH = $origNodePath }
        else { Remove-Item Env:\NODE_PATH -ErrorAction SilentlyContinue }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  GITHUB PR WORKFLOW  —  commit, push to fork, create/update PR to upstream
# ═══════════════════════════════════════════════════════════════════════════════
function Submit-PullRequest {
    if (-not $ENABLE_PR_WORKFLOW) { return }

    Write-Host ""
    Write-Host "  ===========================================================" -ForegroundColor Cyan
    Write-Host "      GITHUB PR WORKFLOW  (v4.0)" -ForegroundColor Cyan
    Write-Host "  ===========================================================" -ForegroundColor Cyan
    Write-Host ""

    # ── 0. Check for gh CLI ──
    if (-not (Get-Command "gh" -ErrorAction SilentlyContinue)) {
        Write-Warn "gh CLI not found -- skipping PR workflow."
        Write-Info "Install: https://cli.github.com/"
        return
    }

    # ── 1. Check gh authentication (capture exit code before piping) ──
    $authRaw  = & gh auth status 2>&1
    $authCode = $LASTEXITCODE
    if ($authCode -ne 0) {
        Write-Warn "gh is not authenticated -- skipping PR workflow."
        Write-Info "Run: gh auth login"
        return
    }

    # ── 2. Check for git ──
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        Write-Warn "git not found -- skipping PR workflow."
        return
    }

    # ── 3. Check we're inside a git repo ──
    Push-Location $MINDCRAFT_DIR
    try {
        $null = & git rev-parse --git-dir 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Not a git repository -- skipping PR workflow."
            return
        }

        # ── 4. Derive fork owner from remote URL (replaces hardcoded username) ──
        $forkUrl   = (& git remote get-url $PR_FORK_REMOTE 2>&1).Trim()
        $forkOwner = $null
        # Matches: git@github.com:Owner/repo  or  https://github.com/Owner/repo
        if ($forkUrl -match 'github\.com[:/]([^/]+)/') {
            $forkOwner = $Matches[1]
            Write-Ok "Fork owner: $forkOwner (from '$PR_FORK_REMOTE' remote)"
        } else {
            Write-Warn "Could not parse fork owner from remote '$PR_FORK_REMOTE'."
            Write-Info "Remote URL: $forkUrl"
            $forkOwner = Read-Host "  Enter your GitHub username"
            if ([string]::IsNullOrWhiteSpace($forkOwner)) {
                Write-Err "Cannot create cross-repo PR without fork owner. Aborting."
                return
            }
        }

        # ── 5. Check for uncommitted changes ──
        $status = & git status --porcelain 2>&1
        $branch = (& git branch --show-current 2>&1).Trim()
        $changedCount = ($status | Where-Object { $_ -match '\S' }).Count

        if ($changedCount -eq 0) {
            Write-Info "Working tree is clean -- nothing to commit."
            Write-Host ""

            # Still offer to push existing commits / create PR
            $aheadCount = 0
            try {
                $aheadRaw  = & git rev-list --count "${PR_FORK_REMOTE}/${branch}..HEAD" 2>&1
                $aheadCode = $LASTEXITCODE
                if ($aheadCode -eq 0) { $aheadCount = [int]$aheadRaw }
            } catch {}

            if ($aheadCount -eq 0) {
                Write-Ok "Branch '$branch' is up to date with $PR_FORK_REMOTE. No PR needed."
                return
            }
            Write-Info "$aheadCount unpushed commit(s) on '$branch'."
        } else {
            Write-Info "$changedCount file(s) with uncommitted changes on branch '$branch':"
            Write-Host ""
            # Show a compact status summary (max 15 lines)
            $statusLines = $status | Select-Object -First 15
            foreach ($line in $statusLines) {
                $code = $line.Substring(0, 2)
                $file = $line.Substring(3)
                $color = switch -Regex ($code) {
                    '^\?\?' { 'DarkYellow' }   # untracked
                    '^M'    { 'Yellow' }        # modified
                    '^A'    { 'Green' }         # added
                    '^D'    { 'Red' }           # deleted
                    '^R'    { 'Cyan' }          # renamed
                    default { 'Gray' }
                }
                Write-Host "    $code $file" -ForegroundColor $color
            }
            if ($changedCount -gt 15) {
                Write-Host "    ... and $($changedCount - 15) more" -ForegroundColor DarkGray
            }
            Write-Host ""
        }

        # ── 6. Feature branch option (when on a protected branch with changes) ──
        if ($branch -in $PR_PROTECTED -and $changedCount -gt 0) {
            Write-Warn "You are on '$branch' (a protected branch)."
            Write-Info "Creating a feature branch is recommended for clean PRs."
            Write-Host ""
            Write-Host "  Enter a feature branch name, or press Enter to stay on '$branch':" -ForegroundColor Cyan
            $featureName = Read-Host "  Branch"
            if (-not [string]::IsNullOrWhiteSpace($featureName)) {
                $featureName = $featureName.Trim() -replace '\s+', '-'
                $branchRaw  = & git checkout -b $featureName 2>&1
                $branchCode = $LASTEXITCODE
                if ($branchCode -ne 0) {
                    Write-Err "Failed to create branch '$featureName': $($branchRaw | Out-String)"
                    return
                }
                $branch = $featureName
                Write-Ok "Switched to new branch: $branch"
            }
        }

        # ── 7. Prompt: submit PR? ──
        Write-Host "  Submit these changes as a Pull Request to $PR_TARGET_REPO?" -ForegroundColor Cyan
        Write-Host "  [Y] Yes  [N] No  (default: N)" -ForegroundColor DarkGray
        Write-Host ""
        $prChoice = Read-Host "  PR workflow"
        if ($prChoice -notmatch '^[Yy]') {
            Write-Info "PR workflow skipped."
            return
        }

        # ── 8. Commit if there are uncommitted changes ──
        if ($changedCount -gt 0) {
            Write-Host ""
            Write-Host "  Enter commit message (or press Enter for default):" -ForegroundColor Cyan
            $defaultMsg = "DragonSlayer session update $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            Write-Host "  Default: $defaultMsg" -ForegroundColor DarkGray
            $commitMsg = Read-Host "  Message"
            if ([string]::IsNullOrWhiteSpace($commitMsg)) { $commitMsg = $defaultMsg }

            # Warn before git add -A — user should verify .gitignore covers secrets
            Write-Warn "'git add -A' will stage ALL changes (including untracked files)."
            Write-Info "Ensure .env, keys.json, etc. are in .gitignore before proceeding."
            Write-Host "  Proceed with staging? [Y/n]" -ForegroundColor Cyan
            $stageChoice = Read-Host "  Stage"
            if ($stageChoice -match '^[Nn]') {
                Write-Info "Staging cancelled. Stage files manually with 'git add', then re-run."
                return
            }

            Write-Step "Staging all changes..."
            & git add -A 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "git add failed."
                return
            }
            Write-Ok "Staged"

            Write-Step "Committing: $commitMsg"
            & git commit -m $commitMsg 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Err "git commit failed."
                return
            }
            Write-Ok "Committed"

            # Re-capture file diff after commit so PR body is accurate (not stale)
            $status = & git diff --stat HEAD~1 2>&1
        }

        # ── 9. Push to fork remote (capture exit code before piping) ──
        Write-Step "Pushing '$branch' to remote '$PR_FORK_REMOTE'..."
        $pushRaw    = & git push $PR_FORK_REMOTE $branch 2>&1
        $pushCode   = $LASTEXITCODE
        $pushOutput = $pushRaw | Out-String
        if ($pushCode -ne 0) {
            Write-Err "git push failed:"
            Write-Host "    $pushOutput" -ForegroundColor Red
            return
        }
        Write-Ok "Pushed to $PR_FORK_REMOTE/$branch"

        # ── 10. Check for existing PR (owner-qualified --head ref) ──
        Write-Step "Checking for existing PR..."
        $headRef     = "${forkOwner}:${branch}"
        $existingRaw = & gh pr list --repo $PR_TARGET_REPO --head $headRef --state open --json number,title,url 2>&1
        $existingCode = $LASTEXITCODE
        $existingStr  = $existingRaw | Out-String
        $prList = @()
        try { $prList = $existingStr | ConvertFrom-Json } catch {}

        if ($prList.Count -gt 0) {
            $pr = $prList[0]
            Write-Ok "Existing PR #$($pr.number): $($pr.title)"
            Write-Info "URL: $($pr.url)"
            Write-Info "Push updated the PR automatically (commits added to existing branch)."
        } else {
            # ── 11. Create new PR ──
            Write-Step "Creating new Pull Request..."
            Write-Host ""
            Write-Host "  Enter PR title (or press Enter for default):" -ForegroundColor Cyan
            $defaultTitle = "DragonSlayer: $branch updates"
            Write-Host "  Default: $defaultTitle" -ForegroundColor DarkGray
            $prTitle = Read-Host "  Title"
            if ([string]::IsNullOrWhiteSpace($prTitle)) { $prTitle = $defaultTitle }

            # Build PR body with post-commit diff stats (not stale pre-commit status)
            $statusText = $status | Out-String
            $prBody = @"
## Changes

Pushed from DragonSlayer Launcher v4.0 PR workflow.

**Branch:** ``$branch``
**Date:** $(Get-Date -Format 'yyyy-MM-dd HH:mm UTC')
**Machine:** $env:COMPUTERNAME

### Files changed
``````
$statusText
``````

---
*Auto-generated by DragonSlayer-Launcher.ps1 v4.0 PR workflow*
"@

            $createArgs = @(
                "pr", "create",
                "--repo", $PR_TARGET_REPO,
                "--base", $PR_BASE_BRANCH,
                "--head", $headRef,
                "--title", $prTitle,
                "--body", $prBody
            )
            $createRaw    = & gh @createArgs 2>&1
            $createCode   = $LASTEXITCODE
            $createOutput = $createRaw | Out-String
            if ($createCode -ne 0) {
                Write-Err "PR creation failed:"
                Write-Host "    $createOutput" -ForegroundColor Red
                return
            }
            # gh pr create returns the URL
            $prUrl = $createOutput.Trim()
            Write-Ok "PR created: $prUrl"
        }

        # ── 12. Optional: merge the PR (safe: skip --delete-branch for protected) ──
        Write-Host ""
        Write-Host "  Merge the PR now? (requires write access to $PR_TARGET_REPO)" -ForegroundColor Cyan
        Write-Host "  [Y] Yes  [N] No  (default: N)" -ForegroundColor DarkGray
        $mergeChoice = Read-Host "  Merge"
        if ($mergeChoice -match '^[Yy]') {
            Write-Step "Merging PR..."
            $mergeArgs = @("pr", "merge", "--repo", $PR_TARGET_REPO, "--squash")
            if ($branch -notin $PR_PROTECTED) {
                $mergeArgs += "--delete-branch"
            } else {
                Write-Info "Skipping --delete-branch (protected branch: $branch)"
            }
            $mergeRaw    = & gh @mergeArgs 2>&1
            $mergeCode   = $LASTEXITCODE
            $mergeOutput = $mergeRaw | Out-String
            if ($mergeCode -eq 0) {
                Write-Ok "PR merged successfully!"
            } else {
                Write-Warn "Merge failed (you may not have write access):"
                Write-Host "    $mergeOutput" -ForegroundColor Yellow
            }
        } else {
            Write-Info "PR left open for review."
        }

    } finally {
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  GRACEFUL SHUTDOWN
# ═══════════════════════════════════════════════════════════════════════════════
function Stop-Everything {
    Write-Host ""
    Write-Host "  ===========================================================" -ForegroundColor Yellow
    Write-Host "      SHUTTING DOWN DRAGONSLAYER..." -ForegroundColor Yellow
    Write-Host "  ===========================================================" -ForegroundColor Yellow

    # Session duration
    if ($script:LaunchTime) {
        $dur = (Get-Date) - $script:LaunchTime
        Write-Info ("Session duration: {0:hh\:mm\:ss}" -f $dur)
    }

    # 1) Kill bot process tree  (taskkill /T works on PS 5.1; .Kill($true) needs .NET 5+)
    if ($script:BotProcess -and -not $script:BotProcess.HasExited) {
        $bPid = $script:BotProcess.Id
        Write-Step "Stopping bot (PID $bPid)..."
        try {
            # taskkill /T = kill entire process tree (works on all Windows PS versions)
            $null = & taskkill /F /T /PID $bPid 2>&1
        } catch {
            try { $script:BotProcess.Kill() } catch {}
        }
        try { $script:BotProcess.WaitForExit(5000) } catch {}
        Write-Ok "Bot stopped"
    }

    # 2) Kill Paper server
    if ($script:PaperProcess -and -not $script:PaperProcess.HasExited) {
        $pPid = $script:PaperProcess.Id
        Write-Step "Stopping Paper server (PID $pPid)..."
        try {
            $null = & taskkill /F /T /PID $pPid 2>&1
        } catch {
            try { $script:PaperProcess.Kill() } catch {}
        }
        try { $script:PaperProcess.WaitForExit(5000) } catch {}
        Write-Ok "Paper stopped"
    }

    # 3) Stop Ollama only if we started it
    if ($script:OllamaStartedByUs) {
        Write-Step "Stopping Ollama (we started it)..."
        try {
            Get-Process -Name "ollama*" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Get-Process -Name "ollama_llama_server" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Ok "Ollama stopped"
        } catch {
            Write-Warn "Ollama cleanup: $_"
        }
    } else {
        Write-Info "Ollama was already running -- leaving it alone."
    }

    # 4) Unregister all process events
    Get-EventSubscriber -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceObject -is [System.Diagnostics.Process] } |
        Unregister-Event -ErrorAction SilentlyContinue

    # 5) Orphan sweep -- kill stray node processes tied to mindcraft
    $orphans = Get-Process -Name "node" -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" `
                            -ErrorAction SilentlyContinue).CommandLine
                $cmd -and ($cmd -match 'mindcraft|main\.js')
            } catch { $false }
        }
    if ($orphans) {
        Write-Step "Cleaning $($orphans.Count) orphaned node process(es)..."
        $orphans | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Ok "Orphans cleaned"
    }

    Write-Host ""
    Write-Ok "All services stopped. Session ended."
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════
try {
    $Host.UI.RawUI.WindowTitle = "DragonSlayer v4.0 -- Mindcraft Launcher"
    Clear-Host
    Write-Banner

    # -- 0. Pre-flight --
    if (-not (Test-Prerequisites)) {
        Write-Host ""
        Write-Err "Pre-flight failed. Fix the errors above and try again."
        Write-Host ""
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }

    # -- 1. Ollama --
    if (-not (Start-OllamaServer)) {
        Write-Err "Cannot continue without Ollama."
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }

    # -- 2. Models --
    if (-not (Install-OllamaModels)) {
        Write-Err "Cannot continue without required models."
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }

    # -- 3. Optional Paper server --
    Start-LocalPaperServer

    # -- 4. Bot --
    if (-not (Start-MindcraftBot)) {
        Write-Err "Bot launch failed."
        Stop-Everything
        Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }

    # -- 5. HUD --
    Open-MindServerHUD

    # -- 6. !beatMinecraft --
    Send-BeatMinecraftCommand -SkipPrompt $AUTO_BEAT_MC

    # ── STATUS DASHBOARD  (pad + truncate to exactly 45 chars for alignment) ──
    function Fit([string]$s, [int]$w = 45) {
        if ($s.Length -gt $w) { return $s.Substring(0, $w - 1) + [char]0x2026 }  # ellipsis
        return $s.PadRight($w)
    }
    $hudStr    = "http://localhost:$MINDSERVER_PORT"
    $serverStr = "${MC_HOST}:$MC_PORT"
    $pidStr    = "$($script:BotProcess.Id)"
    $modelStr  = "sweaterdog/andy-4:q8_0  (RTX 3090 CUDA)"

    Write-Host ""
    Write-Host "  +==============================================================+" -ForegroundColor Green
    Write-Host "  |                                                              |" -ForegroundColor Green
    Write-Host "  |   DRAGONSLAYER IS RUNNING                                    |" -ForegroundColor Green
    Write-Host "  |                                                              |" -ForegroundColor Green
    Write-Host "  |   HUD      $(Fit $hudStr)|" -ForegroundColor Green
    Write-Host "  |   Server   $(Fit $serverStr)|" -ForegroundColor Green
    Write-Host "  |   Model    $(Fit $modelStr)|" -ForegroundColor Green
    Write-Host "  |   Profile  $(Fit $PROFILE_PATH)|" -ForegroundColor Green
    Write-Host "  |   PID      $(Fit $pidStr)|" -ForegroundColor Green
    Write-Host "  |                                                              |" -ForegroundColor Green
    Write-Host "  |   >>> PRESS ANY KEY TO SHUT DOWN <<<                         |" -ForegroundColor Green
    Write-Host "  |                                                              |" -ForegroundColor Green
    Write-Host "  +==============================================================+" -ForegroundColor Green
    Write-Host ""

    # ── Event loop: watch for keypress or crash ──
    while ($true) {
        # Bot crashed?
        if ($script:BotProcess -and $script:BotProcess.HasExited) {
            $ec = $script:BotProcess.ExitCode
            Write-Host ""
            if ($ec -eq 0) {
                Write-Ok "Bot exited normally (code 0)."
            } else {
                Write-Err "Bot crashed! Exit code: $ec"
                Write-Info "Check logs: bots/$BOT_NAME/"
            }
            break
        }

        # Keypress?
        if ([Console]::KeyAvailable) {
            $null = [Console]::ReadKey($true)
            Write-Host ""
            Write-Info "Keypress detected -- shutting down..."
            break
        }

        Start-Sleep -Milliseconds 250
    }

} catch {
    Write-Host ""
    Write-Err "Fatal: $_"
    Write-Err $_.ScriptStackTrace
} finally {
    Stop-Everything

    # ── Offer GitHub PR workflow after shutdown (only if bot actually launched) ──
    if ($script:LaunchTime) {
        try { Submit-PullRequest } catch {
            Write-Warn "PR workflow error: $_"
        }
    } else {
        Write-Info "Bot never launched -- skipping PR workflow."
    }

    Write-Host "  Press any key to close..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch {}
}
