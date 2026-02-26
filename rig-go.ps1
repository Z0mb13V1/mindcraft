<#
.SYNOPSIS
    The ultimate one-command launcher for the Mindcraft hybrid research rig.

.DESCRIPTION
    rig-go.ps1 is the single entry-point that handles EVERYTHING:

      1. Navigate to repo
      2. Git pull (SSH — no auth prompt)
      3. Verify Ollama is responding + sweaterdog/andy-4 is loaded
      4. Validate both profile JSON files (parse + name check)
      5. Validate docker-compose.yml (docker compose config)
      6. Delegate to full-rig-launch.ps1 (8-check master launcher)
      7. Fallback: if full-rig-launch.ps1 is missing, launch directly
      8. Wait 60s, display container status
      9. Send Discord webhook: "Rig launched: LocalAndy & CloudGrok online"
     10. Print connection info (Minecraft, UI, cameras)
     11. Offer experiment start (interactive prompt)
     12. Tail live logs until Ctrl+C

    Designed for PowerShell 5.1+ on Windows. Safe string handling
    (no subexpression bugs), heavy commenting, colored output,
    actionable recovery commands on every failure.

.PARAMETER SkipPull
    Skip the git pull step (useful offline or if already up-to-date).

.PARAMETER Build
    Force-rebuild the mindcraft Docker image before launching.
    Passed through to full-rig-launch.ps1 as -Build.

.PARAMETER SkipNameUpdate
    Skip the bot-name rename step inside full-rig-launch.ps1.

.PARAMETER NoExperiment
    Skip the "Run a test experiment?" prompt and go straight to logs.

.PARAMETER NoLogs
    Exit after launch (don't tail logs). Useful in CI or scripts.

.EXAMPLE
    .\rig-go.ps1                        # Full flow
    .\rig-go.ps1 -SkipPull              # Skip git pull
    .\rig-go.ps1 -Build                 # Rebuild image first
    .\rig-go.ps1 -NoExperiment -NoLogs  # Launch only, no prompts
#>
param(
    [switch]$SkipPull,
    [switch]$Build,
    [switch]$SkipNameUpdate,
    [switch]$NoExperiment,
    [switch]$NoLogs
)

$ErrorActionPreference = 'Continue'

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
$RepoPath     = $PSScriptRoot                      # Script lives in the repo root
$LocalName    = 'LocalAndy'
$CloudName    = 'CloudGrok'
$LocalProfile = 'profiles\local-research.json'
$CloudProfile = 'profiles\cloud-persistent.json'
$EC2_IP       = '54.152.239.117'                   # For connection info display

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS — colored output + counters
# ─────────────────────────────────────────────────────────────────────────────
$script:pass = 0
$script:fail = 0
$script:warn = 0

function Write-Step {
    param([string]$Num, [string]$Label)
    Write-Host ''
    Write-Host ('=== [' + $Num + '] ' + $Label + ' ===') -ForegroundColor Cyan
}

function Write-OK {
    param([string]$m)
    Write-Host ('  [OK]   ' + $m) -ForegroundColor Green
    $script:pass++
}

function Write-Warn {
    param([string]$m)
    Write-Host ('  [WARN] ' + $m) -ForegroundColor Yellow
    $script:warn++
}

function Write-Fail {
    param([string]$m)
    Write-Host ('  [FAIL] ' + $m) -ForegroundColor Red
    $script:fail++
}

function Write-Info {
    param([string]$m)
    Write-Host ('         ' + $m) -ForegroundColor DarkGray
}

function Write-Recovery {
    param([string]$m)
    Write-Host ('  FIX:   ' + $m) -ForegroundColor Yellow
}

# Send a Discord webhook notification (best-effort, never blocks launch).
function Send-DiscordWebhook {
    param([string]$Message, [string]$Color)
    $url = $env:BACKUP_WEBHOOK_URL
    if (-not $url) {
        # Also try loading from .env if not already in env
        if (Test-Path (Join-Path $RepoPath '.env')) {
            $envLine = Get-Content (Join-Path $RepoPath '.env') |
                Where-Object { $_ -match '^\s*BACKUP_WEBHOOK_URL\s*=' } |
                Select-Object -First 1
            if ($envLine -match '=\s*(.+)\s*$') {
                $url = $Matches[1].Trim().Trim('"').Trim("'")
            }
        }
    }
    if (-not $url) { return }
    try {
        $body = @{
            embeds = @(
                @{
                    title       = 'Mindcraft Rig'
                    description = $Message
                    color       = if ($Color -eq 'red') { 15548997 } elseif ($Color -eq 'yellow') { 16776960 } else { 5763719 }
                    timestamp   = (Get-Date -Format 'o')
                    footer      = @{ text = 'rig-go.ps1' }
                }
            )
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 | Out-Null
    } catch {
        # Non-critical — don't break launch for a webhook failure
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ''
Write-Host '  +========================================================+' -ForegroundColor Magenta
Write-Host '  |                                                        |' -ForegroundColor Magenta
Write-Host '  |       MINDCRAFT HYBRID RIG  --  ONE-COMMAND LAUNCH     |' -ForegroundColor Magenta
Write-Host '  |                                                        |' -ForegroundColor Magenta
Write-Host ('  |   ' + $LocalName.PadRight(14) + ' (RTX 3090 + Ollama)              |') -ForegroundColor Magenta
Write-Host ('  |   ' + $CloudName.PadRight(14) + ' (Gemini + Grok ensemble)         |') -ForegroundColor Magenta
Write-Host '  |                                                        |' -ForegroundColor Magenta
Write-Host '  +========================================================+' -ForegroundColor Magenta
Write-Host ''

$startTime = Get-Date

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Navigate to repository
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '1/12' 'Navigate to Repository'

if (-not (Test-Path $RepoPath)) {
    Write-Fail ('Repo not found: ' + $RepoPath)
    Write-Recovery 'Clone it: git clone git@github.com:Z0mb13V1/mindcraft-0.1.3.git'
    exit 1
}
Set-Location $RepoPath
Write-OK ('Working directory: ' + $RepoPath)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Git pull (SSH — no password prompt)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '2/12' 'Git Pull'

if ($SkipPull) {
    Write-Info '-SkipPull set -- using local files as-is.'
} else {
    Write-Info 'Pulling latest from origin/main (SSH)...'
    $pullOutput = & git pull origin main 2>&1
    $pullExit   = $LASTEXITCODE

    # Display pull output
    $pullOutput | ForEach-Object { Write-Info ($_.ToString()) }

    if ($pullExit -ne 0) {
        Write-Warn 'git pull failed -- continuing with local files.'
        Write-Recovery 'Check SSH key: ssh -T git@github.com'
        Write-Recovery 'Or rerun with: .\rig-go.ps1 -SkipPull'
    } else {
        $pullSummary = ($pullOutput | Out-String).Trim()
        if ($pullSummary -match 'Already up to date') {
            Write-OK 'Already up to date.'
        } else {
            Write-OK 'Pulled latest changes.'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Verify Ollama is responding + model exists
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '3/12' 'Ollama Verification'

$ollamaOK = $false
try {
    $ollamaTags = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 5
    $ollamaOK   = $true
} catch {
    Write-Fail 'Ollama API not responding on http://localhost:11434/'
    Write-Recovery 'Start Ollama:  ollama serve'
    Write-Recovery 'Then rerun:    .\rig-go.ps1'
}

if ($ollamaOK) {
    $modelCount = if ($ollamaTags.models) { $ollamaTags.models.Count } else { 0 }
    Write-OK ('Ollama API healthy -- ' + $modelCount + ' model(s) loaded')

    # Check for sweaterdog/andy-4 specifically
    $andyModel = $null
    if ($ollamaTags.models) {
        $andyModel = $ollamaTags.models |
            Where-Object { $_.name -like 'sweaterdog/andy*' } |
            Select-Object -First 1
    }
    if ($andyModel) {
        # Calculate model size for display
        $sizeGB = if ($andyModel.size) {
            [Math]::Round($andyModel.size / 1GB, 1).ToString() + ' GB'
        } else { 'unknown size' }
        Write-OK ('Model: ' + $andyModel.name + ' (' + $sizeGB + ')')
    } else {
        Write-Fail 'sweaterdog/andy-4 not found in Ollama.'
        Write-Recovery 'Pull it:  ollama pull sweaterdog/andy-4'
        Write-Recovery 'Verify:   ollama list'
    }

    # Quick Ollama generate test — ensure the model actually loads
    try {
        Write-Info 'Running quick inference test (2-token response)...'
        $testBody = @{
            model  = 'sweaterdog/andy-4'
            prompt = 'Say hi'
            stream = $false
            options = @{ num_predict = 2 }
        } | ConvertTo-Json
        $testResp = Invoke-RestMethod -Uri 'http://localhost:11434/api/generate' `
            -Method Post -ContentType 'application/json' -Body $testBody -TimeoutSec 120
        if ($testResp.response) {
            Write-OK ('Inference OK: "' + $testResp.response.Trim().Substring(0, [Math]::Min(30, $testResp.response.Trim().Length)) + '"')
        } else {
            Write-Warn 'Ollama responded but with empty output.'
        }
    } catch {
        Write-Warn ('Ollama inference test failed: ' + $_.Exception.Message)
        Write-Info 'Bot may still work -- Ollama might need a few seconds to warm up.'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Validate both profile JSON files
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '4/12' 'Profile Validation'

foreach ($profileInfo in @(
    @{ Path = $LocalProfile;  ExpectedName = $LocalName;  Label = 'Local' },
    @{ Path = $CloudProfile;  ExpectedName = $CloudName;  Label = 'Cloud' }
)) {
    $pPath = $profileInfo.Path
    if (-not (Test-Path $pPath)) {
        Write-Fail ($pPath + ' -- file not found')
        Write-Recovery ('Restore: git checkout -- ' + $pPath)
        continue
    }

    try {
        $pData = Get-Content $pPath -Raw | ConvertFrom-Json
    } catch {
        Write-Fail ($pPath + ' -- invalid JSON')
        Write-Recovery ('Fix syntax or restore: git checkout -- ' + $pPath)
        continue
    }

    # Check bot name
    $botName = if ($pData.name) { $pData.name } else { '(unnamed)' }
    $nameOK  = ($botName -eq $profileInfo.ExpectedName)
    $nameTag = if ($nameOK) { '' } else { '  (expected: ' + $profileInfo.ExpectedName + ')' }

    # Check for ensemble config (cloud bot)
    $ensTag = if ($pData.ensemble) { ' [ensemble]' } else { '' }

    # Check for model config
    $modelTag = ''
    if ($pData.model) {
        $modelVal = if ($pData.model -is [string]) { $pData.model } else { $pData.model.model }
        $modelTag = '  model=' + $modelVal
    }

    Write-OK ($botName + $ensTag + $modelTag + '  <-  ' + $pPath + $nameTag)
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Validate docker-compose.yml
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '5/12' 'Docker Compose Validation'

# First check Docker is running at all
& docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'Docker Desktop is not running.'
    Write-Recovery 'Start Docker Desktop. Wait for the whale icon in the taskbar.'
    Write-Recovery 'Then rerun: .\rig-go.ps1'
    exit 1
}
Write-OK ('Docker: ' + (& docker --version 2>&1).ToString().Trim())

# Validate compose file syntax
$composeErr = & docker compose config --quiet 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK 'docker-compose.yml is valid.'
} else {
    Write-Fail 'docker-compose.yml has errors.'
    Write-Info ($composeErr | Out-String).Trim()
    Write-Recovery 'Run: docker compose config  (to see full errors)'
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Delegate to full-rig-launch.ps1 (the 8-check master launcher)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '6/12' 'Master Launcher (full-rig-launch.ps1)'

$launcher     = Join-Path $RepoPath 'full-rig-launch.ps1'
$launcherUsed = $false

if (Test-Path $launcher) {
    Write-Info 'Delegating to full-rig-launch.ps1 (8 checks + launch + wait + status)...'
    Write-Host ''

    # Build argument list:
    #   -NoLogs:          we handle log tailing ourselves (step 12)
    #   -Build:           pass through if user specified -Build
    #   -SkipNameUpdate:  pass through if user specified -SkipNameUpdate
    $launchArgs = @('-NoLogs')
    if ($Build)          { $launchArgs += '-Build' }
    if ($SkipNameUpdate) { $launchArgs += '-SkipNameUpdate' }

    & $launcher @launchArgs
    $launchExit = $LASTEXITCODE
    $launcherUsed = $true

    if ($launchExit -ne 0) {
        Write-Host ''
        Write-Fail ('full-rig-launch.ps1 exited with code ' + $launchExit)
        Write-Recovery 'Fix the issues it reported, then rerun: .\rig-go.ps1'
        Send-DiscordWebhook ('Rig launch FAILED (exit code ' + $launchExit + '). Check terminal.') 'red'
        exit $launchExit
    }
    Write-OK 'full-rig-launch.ps1 completed successfully.'
} else {
    # ── STEP 7: Fallback — launch directly via docker compose ────────────────
    Write-Warn 'full-rig-launch.ps1 not found -- using direct docker compose fallback.'
    Write-Info 'This skips the 8-check validation. For full checks, restore full-rig-launch.ps1.'
    Write-Host ''

    # Load .env for API keys (same logic as full-rig-launch.ps1)
    if (Test-Path '.env') {
        Get-Content '.env' | ForEach-Object {
            if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)\s*$') {
                $k = $Matches[1].Trim()
                $v = $Matches[2].Trim().Trim('"').Trim("'")
                if ($v -and -not [System.Environment]::GetEnvironmentVariable($k)) {
                    [System.Environment]::SetEnvironmentVariable($k, $v, 'Process')
                }
            }
        }
        Write-Info '.env loaded.'
    }

    $env:PROFILES = '["./profiles/local-research.json","./profiles/cloud-persistent.json"]'
    Write-Info 'Command: docker compose --profile local --profile cloud up -d --force-recreate'

    if ($Build) {
        & docker compose --profile local --profile cloud up -d --force-recreate --build
    } else {
        & docker compose --profile local --profile cloud up -d --force-recreate
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'docker compose failed.'
        Write-Recovery 'Check: docker compose logs --tail 50'
        Write-Recovery 'Reset: docker compose down; .\rig-go.ps1 -Build'
        Send-DiscordWebhook 'Rig launch FAILED (docker compose error). Check terminal.' 'red'
        exit 1
    }
    Write-OK 'docker compose accepted the command.'
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: Wait + show container status
#   (full-rig-launch.ps1 already does a 60s wait + status, so only do this
#    in fallback mode when full-rig-launch.ps1 was missing)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '8/12' 'Container Status'

if (-not $launcherUsed) {
    # Fallback: we need to wait ourselves since full-rig-launch.ps1 wasn't used
    Write-Info 'Waiting 60s for services to start...'
    $totalWait = 60;  $steps = 20;  $sleepEach = $totalWait / $steps
    for ($i = 1; $i -le $steps; $i++) {
        Start-Sleep -Seconds $sleepEach
        $pct    = [Math]::Round($i / $steps * 100)
        $filled = [Math]::Round($i / $steps * 30)
        $bar    = ('#' * $filled) + ('-' * (30 - $filled))
        Write-Host ("`r  [" + $bar + '] ' + $pct + '%') -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ''
}

# Always show current container status
& docker compose ps
Write-Host ''

# Quick per-container health check
$containers = @('minecraft-server', 'mindcraft-agents', 'discord-bot', 'chromadb')
foreach ($c in $containers) {
    $status = (& docker inspect --format '{{.State.Status}}' $c 2>$null)
    if ($status -eq 'running') {
        Write-OK $c
    } elseif ($status) {
        Write-Warn ($c + ' -- status: ' + $status)
    } else {
        Write-Info ($c + ' -- not found or not started')
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: Send Discord webhook notification
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '9/12' 'Discord Notification'

$elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
$webhookMsg = ($LocalName + ' + ' + $CloudName + ' are online.`nLaunch took ' + $elapsed + 's.`nMinecraft: localhost:25565 / ' + $EC2_IP + ':25565')
Send-DiscordWebhook $webhookMsg 'green'

if ($env:BACKUP_WEBHOOK_URL) {
    Write-OK 'Discord embed sent via BACKUP_WEBHOOK_URL.'
} else {
    Write-Info 'BACKUP_WEBHOOK_URL not set -- Discord notification skipped.'
    Write-Info 'Set it in .env to get launch alerts in your Discord channel.'
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10: Print connection info
# ─────────────────────────────────────────────────────────────────────────────
Write-Step '10/12' 'Connection Info'

Write-Host ''
Write-Host '  +=========================================================+' -ForegroundColor Green
Write-Host '  |   RIG IS LIVE -- Connect now!                           |' -ForegroundColor Green
Write-Host '  +=========================================================+' -ForegroundColor Green
Write-Host ''
Write-Host '  Minecraft (Java Edition 1.21.6):' -ForegroundColor White
Write-Host '    Local:   localhost:25565' -ForegroundColor DarkGray
Write-Host ('    EC2:     ' + $EC2_IP + ':25565') -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Web Interfaces:' -ForegroundColor White
Write-Host '    MindServer UI : http://localhost:8080/' -ForegroundColor DarkGray
Write-Host ('    ' + $LocalName + ' cam  : http://localhost:3000/') -ForegroundColor DarkGray
Write-Host ('    ' + $CloudName + ' cam  : http://localhost:3001/') -ForegroundColor DarkGray
Write-Host '    Grafana       : http://localhost:3004/  (admin/admin)' -ForegroundColor DarkGray
Write-Host '    Prometheus    : http://localhost:9090/' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Discord:' -ForegroundColor White
Write-Host '    MindcraftBot#9501 should appear Online within 60s' -ForegroundColor DarkGray
Write-Host '    Type !status in your bot channel to confirm' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Bots:' -ForegroundColor White
Write-Host ('    ' + $LocalName + '  -- Ollama (sweaterdog/andy-4) via RTX 3090') -ForegroundColor DarkGray
Write-Host ('    ' + $CloudName + ' -- 4-model ensemble (Gemini + Grok) with arbiter/judge') -ForegroundColor DarkGray
Write-Host ''
$elapsedFinal = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)
Write-Host ('  Total launch time: ' + $elapsedFinal + 's') -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11: Offer experiment start (interactive)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $NoExperiment) {
    Write-Step '11/12' 'Experiment (Optional)'

    $expScript = Join-Path $RepoPath 'experiments\new-experiment.ps1'

    if (Test-Path $expScript) {
        $answer = Read-Host '  Run a test experiment? (y/n) [n]'
        if ($answer -eq 'y' -or $answer -eq 'Y') {
            Write-Host ''

            # Prompt for experiment details
            $expName = Read-Host '  Experiment name (slug, e.g. wood-collection)'
            if (-not $expName) { $expName = 'quick-test' }

            $expDuration = Read-Host '  Duration in minutes (default 30)'
            if (-not $expDuration) { $expDuration = '30' }

            $expDesc = Read-Host '  Description (optional, Enter to skip)'
            if (-not $expDesc) { $expDesc = ('Quick ' + $expName + ' test') }

            $expMode = Read-Host '  Mode: local / cloud / both (default both)'
            if (-not $expMode -or $expMode -notin @('local','cloud','both')) { $expMode = 'both' }

            Write-Host ''
            Write-Host ('  Creating experiment: ' + $expName + ' (' + $expDuration + ' min, ' + $expMode + ' mode)') -ForegroundColor Cyan

            $expArgs = @(
                '-Name',            $expName,
                '-DurationMinutes', $expDuration,
                '-Description',     $expDesc,
                '-Mode',            $expMode
            )
            & $expScript @expArgs

            if ($LASTEXITCODE -eq 0) {
                Write-OK ('Experiment "' + $expName + '" created. See output above for details.')
                Send-DiscordWebhook ('Experiment started: ' + $expName + ' (' + $expDuration + ' min, ' + $expMode + ')') 'green'
            } else {
                Write-Warn 'Experiment creation had issues -- check output above.'
            }
            Write-Host ''
        } else {
            Write-Info 'No experiment. You can start one later:'
            Write-Info '  .\experiments\new-experiment.ps1 -Name "my-test" -DurationMinutes 30'
        }
    } else {
        Write-Info 'experiments\new-experiment.ps1 not found -- skipping.'
        Write-Info 'Create it to enable one-click experiment setup.'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 12: Tail live logs until Ctrl+C
# ─────────────────────────────────────────────────────────────────────────────
if ($NoLogs) {
    Write-Step '12/12' 'Done (log tail skipped)'
    Write-Info '-NoLogs set -- tail manually:  docker compose logs -f mindcraft'
    Write-Host ''
    exit 0
}

Write-Step '12/12' 'Live Log Stream'
Write-Host ''
Write-Host '  Streaming mindcraft bot logs below. Press Ctrl+C to stop.' -ForegroundColor Cyan
Write-Host '  Bots will keep running in Docker after you stop the stream.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Quick commands (in another terminal):' -ForegroundColor DarkGray
Write-Host '    docker compose ps                     -- container states' -ForegroundColor DarkGray
Write-Host '    docker compose restart mindcraft      -- restart bots' -ForegroundColor DarkGray
Write-Host '    docker compose down                   -- stop everything' -ForegroundColor DarkGray
Write-Host '    .\rig-go.ps1                         -- full relaunch' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor DarkGray
Write-Host ''

& docker compose logs -f mindcraft
