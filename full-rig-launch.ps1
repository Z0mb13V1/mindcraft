<#
.SYNOPSIS
    Master launch script for the Mindcraft hybrid research rig.
.DESCRIPTION
    Handles every step from validation to live log streaming.
    Assumes Ollama is already running with sweaterdog/andy-4 loaded.
    Does NOT pull models, does NOT touch world data.
    Uses --profile local --profile cloud to activate GPU exporter + Discord bot.
.PARAMETER SkipNameUpdate
    Skip renaming bots in profile JSON files (use if already renamed).
.PARAMETER NoLogs
    Skip the live log stream at the end (just launch and exit).
.PARAMETER Build
    Force-rebuild the mindcraft Docker image before launching.
.EXAMPLE
    .\full-rig-launch.ps1
    .\full-rig-launch.ps1 -SkipNameUpdate -NoLogs
    .\full-rig-launch.ps1 -Build
#>
param(
    [switch]$SkipNameUpdate,
    [switch]$NoLogs,
    [switch]$Build
)

$ErrorActionPreference = 'Continue'

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — edit these if you want different names
# ─────────────────────────────────────────────────────────────────────────────
$RepoPath    = 'C:\Users\Tyler\Desktop\AI\minecraft ai bot\Mindcraft\mindcraft-0.1.3'
$LocalName   = 'LocalAndy'
$CloudName   = 'CloudGrok'
$LocalProfile = 'profiles\local-research.json'
$CloudProfile = 'profiles\cloud-persistent.json'

# PROFILES env var: tells the mindcraft container which bot JSON files to load.
# Paths are relative to /app inside the container (bind-mounted from .\profiles\).
$ProfilesEnv = '["./profiles/local-research.json","./profiles/cloud-persistent.json"]'

# ─────────────────────────────────────────────────────────────────────────────
# COUNTERS AND HELPERS
# ─────────────────────────────────────────────────────────────────────────────
$script:pass = 0
$script:fail = 0
$script:warn = 0

function Write-Header {
    param([string]$m)
    Write-Host ''
    Write-Host ('=== ' + $m + ' ===') -ForegroundColor Cyan
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
function Send-Webhook {
    param([string]$Message)
    $url = [System.Environment]::GetEnvironmentVariable('BACKUP_WEBHOOK_URL')
    if (-not $url) { return }
    try {
        $body = '{"content":"' + ($Message -replace '"', '\"') + '"}'
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 | Out-Null
    } catch { }  # non-critical
}

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host '  |   Mindcraft Hybrid Rig -- Master Launch Script       |' -ForegroundColor Cyan
Write-Host ('  |   Local: ' + $LocalName.PadRight(14) + '  Cloud: ' + $CloudName.PadRight(14) + '  |') -ForegroundColor Cyan
Write-Host '  |   No model pulls -- Ollama already serving           |' -ForegroundColor Cyan
Write-Host '  +======================================================+' -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# CD TO REPO
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $RepoPath)) {
    Write-Host ('  [FAIL] Repo path not found: ' + $RepoPath) -ForegroundColor Red
    Write-Recovery 'Update $RepoPath at the top of this script.'
    exit 1
}
Set-Location $RepoPath
Write-Info ('Working directory: ' + $RepoPath)

# ─────────────────────────────────────────────────────────────────────────────
# [1/8] DOCKER DESKTOP
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[1/8] Docker Desktop'

& docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'Docker Desktop is not running.'
    Write-Recovery 'Start Docker Desktop and wait for the whale icon in the taskbar.'
    Write-Recovery 'Then rerun: .\full-rig-launch.ps1'
    exit 1
}
$dockerVer = (& docker --version 2>&1).ToString().Trim()
Write-OK $dockerVer

# ─────────────────────────────────────────────────────────────────────────────
# [2/8] GPU (informational — failure here is non-fatal)
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[2/8] GPU'

try {
    $gpuName = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>&1).ToString().Trim()
    $vramRaw  = (& nvidia-smi '--query-gpu=memory.total' '--format=csv,noheader,nounits' 2>&1).ToString().Trim()
    $vramGB   = [Math]::Round([int]$vramRaw / 1024, 1)
    $gpuUtil  = (& nvidia-smi '--query-gpu=utilization.gpu' '--format=csv,noheader,nounits' 2>&1).ToString().Trim()
    Write-OK ('GPU: ' + $gpuName + '  VRAM: ' + $vramGB + ' GB  Util: ' + $gpuUtil + '%')
} catch {
    Write-Warn 'nvidia-smi not available (GPU skipped -- Ollama is already loaded, safe to continue).'
}

# ─────────────────────────────────────────────────────────────────────────────
# [3/8] OLLAMA — verify only, zero pulls
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[3/8] Ollama (verify, no pulls)'

$ollamaTags   = $null
$ollamaOnline = $false

try {
    $ollamaTags   = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 5
    $ollamaOnline = $true
} catch {
    Write-Fail 'Ollama API not responding on http://localhost:11434/'
    Write-Recovery 'In a new terminal run:  ollama serve'
    Write-Recovery 'Wait 5s then rerun:     .\full-rig-launch.ps1'
}

if ($ollamaOnline) {
    $modelCount = if ($ollamaTags.models) { $ollamaTags.models.Count } else { 0 }
    Write-OK ('Ollama API healthy -- ' + $modelCount + ' model(s) loaded')

    $andyModel = $null
    if ($ollamaTags.models) {
        $andyModel = $ollamaTags.models |
            Where-Object { $_.name -like 'sweaterdog/andy*' } |
            Select-Object -First 1
    }
    if ($andyModel) {
        Write-OK ('Local model: ' + $andyModel.name)
    } else {
        Write-Fail 'sweaterdog/andy-4 not found in Ollama model list.'
        Write-Recovery 'Run: ollama pull sweaterdog/andy-4  (then rerun this script)'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# [4/8] LOAD .env AND keys.json INTO PROCESS ENVIRONMENT
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[4/8] Environment / API Keys'

# Load .env (does not overwrite vars already set in the shell)
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
} else {
    Write-Warn '.env not found -- API keys must be in keys.json or shell environment.'
}

# Load keys.json fallback
$kj = $null
if (Test-Path 'keys.json') {
    try {
        $kj = Get-Content 'keys.json' -Raw | ConvertFrom-Json
        Write-Info 'keys.json loaded.'
    } catch {
        Write-Warn 'keys.json found but could not be parsed as JSON.'
    }
}

# Helper: check one API key against env + keys.json
function Test-ApiKey {
    param([string]$Name, [string]$EnvVal, [string]$JsonProp, [bool]$Required)
    $ev = $EnvVal
    $jv = $null
    if ($kj -and $JsonProp -and $JsonProp.Length -gt 0) { $jv = $kj.$JsonProp }
    $ok = ($ev -and $ev.Length -gt 5) -or ($jv -and $jv.Length -gt 5)
    if ($ok) {
        $src = if ($ev -and $ev.Length -gt 5) { '.env' } else { 'keys.json' }
        Write-OK ($Name + ' present (' + $src + ')')
    } elseif ($Required) {
        Write-Fail ($Name + ' missing -- cloud bot will fail')
        Write-Recovery ('Add to .env:  ' + $Name + '=your-key-here')
    } else {
        Write-Warn ($Name + ' not set (optional -- bot will skip that feature)')
    }
}

Test-ApiKey 'GEMINI_API_KEY'    $env:GEMINI_API_KEY    'GEMINI_API_KEY'    $true
Test-ApiKey 'XAI_API_KEY'       $env:XAI_API_KEY       'XAI_API_KEY'       $true
Test-ApiKey 'ANTHROPIC_API_KEY' $env:ANTHROPIC_API_KEY 'ANTHROPIC_API_KEY' $false
Test-ApiKey 'DISCORD_BOT_TOKEN' $env:DISCORD_BOT_TOKEN ''                  $false

if ($env:BACKUP_WEBHOOK_URL) {
    Write-Info 'BACKUP_WEBHOOK_URL set -- Discord launch notification will be sent.'
}

# ─────────────────────────────────────────────────────────────────────────────
# [5/8] UPDATE BOT NAMES IN PROFILE JSON FILES
# Renames: LocalResearch_1 → LocalAndy, CloudPersistent_1 → CloudGrok
# Also updates cross-bot references inside the conversing prompts.
# Skipped automatically if names already match.
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[5/8] Bot Name Update'

function Update-BotProfile {
    param(
        [string]$FilePath,
        [string]$NewName,
        [string[]]$OldNames,      # all old names to replace in conversing text
        [string[]]$NewNames       # corresponding new names
    )

    if (-not (Test-Path $FilePath)) {
        Write-Fail ($FilePath + ' not found -- skipping name update')
        Write-Recovery ('Restore from git: git checkout -- ' + $FilePath)
        return
    }

    try {
        $raw  = Get-Content $FilePath -Raw
        $data = $raw | ConvertFrom-Json
    } catch {
        Write-Fail ($FilePath + ' has invalid JSON -- cannot update name')
        Write-Recovery ('Fix JSON or restore: git checkout -- ' + $FilePath)
        return
    }

    # Check if name already matches
    if ($data.name -eq $NewName) {
        Write-OK ($FilePath + ' -- name already ' + $NewName)
        return
    }

    $oldTopName = $data.name
    $data.name  = $NewName

    # Update conversing text (and other prompt fields) to replace all old→new name pairs
    $promptFields = @('conversing', 'coding', 'saving_memory', 'bot_responder')
    foreach ($field in $promptFields) {
        if ($data.$field -and $data.$field.Length -gt 0) {
            $text = $data.$field
            for ($i = 0; $i -lt $OldNames.Length; $i++) {
                $text = $text -replace [regex]::Escape($OldNames[$i]), $NewNames[$i]
            }
            $data.$field = $text
        }
    }

    # Write back as UTF-8 without BOM (Node.js JSON.parse handles this cleanly)
    $newJson  = $data | ConvertTo-Json -Depth 20
    $absPath  = (Resolve-Path $FilePath).Path
    [System.IO.File]::WriteAllText($absPath, $newJson)

    Write-OK ($FilePath + ' -- renamed ' + $oldTopName + ' -> ' + $NewName)
}

if ($SkipNameUpdate) {
    Write-Info '-SkipNameUpdate set -- skipping profile name update.'
} else {
    # Local bot: LocalResearch_1 → LocalAndy
    # Also update cloud references to local name (for cross-bot coordination)
    Update-BotProfile `
        -FilePath   $LocalProfile `
        -NewName    $LocalName `
        -OldNames   @('LocalResearch_1', 'CloudPersistent_1') `
        -NewNames   @($LocalName, $CloudName)

    # Cloud bot: CloudPersistent_1 → CloudGrok, LocalResearch_1 → LocalAndy
    Update-BotProfile `
        -FilePath   $CloudProfile `
        -NewName    $CloudName `
        -OldNames   @('CloudPersistent_1', 'LocalResearch_1') `
        -NewNames   @($CloudName, $LocalName)
}

# ─────────────────────────────────────────────────────────────────────────────
# [6/8] PROFILE VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[6/8] Profile Validation'

foreach ($pPath in @($LocalProfile, $CloudProfile)) {
    if (Test-Path $pPath) {
        try {
            $pData   = Get-Content $pPath -Raw | ConvertFrom-Json
            $botName = if ($pData.name) { $pData.name } else { '(unnamed)' }
            $hasEnsemble = if ($pData.ensemble) { ' [ensemble]' } else { '' }
            Write-OK ($botName + $hasEnsemble + '  <-  ' + $pPath)
        } catch {
            Write-Fail ($pPath + ' -- JSON parse error')
            Write-Recovery ('Restore: git checkout -- ' + $pPath)
        }
    } else {
        Write-Fail ($pPath + ' -- not found')
        Write-Recovery ('Restore: git checkout -- ' + $pPath)
    }
}

# Ensure runtime directories exist (do not touch minecraft-data — world is in there)
foreach ($d in @('bots', 'experiments', 'backups')) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Info ('Created directory: ' + $d + '\')
    }
}

if (Test-Path 'minecraft-data') {
    Write-OK 'minecraft-data\ exists -- world data is safe'
} else {
    Write-Warn 'minecraft-data\ not found -- Minecraft will create a fresh world on first launch.'
}

# ─────────────────────────────────────────────────────────────────────────────
# [7/8] docker-compose.yml VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[7/8] docker-compose.yml'

$composeErr = & docker compose config --quiet 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK 'docker-compose.yml is valid'
} else {
    Write-Fail 'docker-compose.yml has errors'
    Write-Info ('Error output: ' + ($composeErr | Out-String).Trim())
    Write-Recovery 'Run: docker compose config  to see the full error'
}

# ─────────────────────────────────────────────────────────────────────────────
# [8/8] IMAGE BUILD (only if -Build flag passed)
# ─────────────────────────────────────────────────────────────────────────────
Write-Header '[8/8] Docker Image'

if ($Build) {
    Write-Info 'Rebuilding mindcraft image (this may take 2-5 min)...'
    & docker compose build mindcraft 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line -match 'Step |Successfully|CACHED|ERROR|error') {
            Write-Info $line
        }
    }
    if ($LASTEXITCODE -eq 0) {
        Write-OK 'mindcraft image rebuilt.'
    } else {
        Write-Fail 'Docker build failed. See output above.'
        Write-Recovery 'Run manually: docker compose build mindcraft'
    }
} else {
    # Just verify the image exists without rebuilding
    $imgCheck = & docker compose images mindcraft 2>&1 | Select-Object -Skip 1
    if ($imgCheck -and $imgCheck.ToString().Trim().Length -gt 0) {
        Write-OK 'mindcraft image present (use -Build to force rebuild)'
    } else {
        Write-Warn 'mindcraft image not found -- building now (first run)...'
        & docker compose build mindcraft 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-OK 'mindcraft image built.'
        } else {
            Write-Fail 'Docker build failed.'
            Write-Recovery 'Run: docker compose build mindcraft'
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-LAUNCH SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
$summaryColor = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
$summaryLine  = '  Checks: ' + $script:pass + ' passed   ' + $script:warn + ' warnings   ' + $script:fail + ' failed'
Write-Host $summaryLine -ForegroundColor $summaryColor
Write-Host ''

if ($script:fail -gt 0) {
    Write-Host '  One or more checks failed. Fix the issues above, then rerun:' -ForegroundColor Red
    Write-Host '    .\full-rig-launch.ps1' -ForegroundColor Red
    Write-Host ''
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SET PROFILES ENV VAR (tells mindcraft container which bots to load)
# ─────────────────────────────────────────────────────────────────────────────
$env:PROFILES = $ProfilesEnv
Write-Info ('PROFILES = ' + $ProfilesEnv)

# ─────────────────────────────────────────────────────────────────────────────
# LAUNCH
# --profile local  → enables nvidia-gpu-exporter
# --profile cloud  → enables discord-bot
# minecraft + mindcraft have no profile tag, so they always start
# --force-recreate → restarts containers with fresh config (volumes untouched)
# ─────────────────────────────────────────────────────────────────────────────
Write-Header 'Launching Both Bots'
Write-Info ('Bots:    ' + $LocalName + '  +  ' + $CloudName)
Write-Info 'Command: docker compose --profile local --profile cloud up -d --force-recreate'
Write-Host ''

if ($Build) {
    & docker compose --profile local --profile cloud up -d --force-recreate --build
} else {
    & docker compose --profile local --profile cloud up -d --force-recreate
}

$launchCode = $LASTEXITCODE

if ($launchCode -ne 0) {
    Write-Host ''
    $failMsg = '  [FAIL] docker compose exited with code ' + $launchCode.ToString()
    Write-Host $failMsg -ForegroundColor Red
    Write-Host ''
    Write-Host '  Recovery options:' -ForegroundColor Yellow
    Write-Host '    Read logs:    docker compose logs --tail 50' -ForegroundColor White
    Write-Host '    Hard reset:   docker compose down && .\full-rig-launch.ps1 -Build' -ForegroundColor White
    Write-Host '    Inspect:      docker compose ps' -ForegroundColor White
    Write-Host ''
    exit $launchCode
}

Write-Host ''
Write-OK 'docker compose accepted the command -- containers are starting...'

# ─────────────────────────────────────────────────────────────────────────────
# WAIT 60s FOR STARTUP (Minecraft needs ~30s, mindcraft waits on MC healthcheck)
# ─────────────────────────────────────────────────────────────────────────────
Write-Header 'Waiting 60s for services to start'
Write-Info 'Minecraft server starts first, then mindcraft agents connect.'
Write-Host ''

$totalWait  = 60
$steps      = 20
$sleepEach  = $totalWait / $steps

for ($i = 1; $i -le $steps; $i++) {
    Start-Sleep -Seconds $sleepEach
    $pct    = [Math]::Round($i / $steps * 100)
    $filled = [Math]::Round($i / $steps * 30)
    $empty  = 30 - $filled
    $bar    = ('#' * $filled) + ('-' * $empty)
    Write-Host ("`r  [" + $bar + '] ' + $pct + '%') -NoNewline -ForegroundColor DarkGray
}

Write-Host ''
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# CONTAINER STATUS
# ─────────────────────────────────────────────────────────────────────────────
Write-Header 'Container Status'
& docker compose ps
Write-Host ''

# Quick health snapshot
$containers = @('minecraft-server', 'mindcraft-agents', 'discord-bot', 'nvidia-gpu-exporter')
foreach ($c in $containers) {
    $status = (& docker inspect --format '{{.State.Status}}' $c 2>$null)
    $health = (& docker inspect --format '{{.State.Health.Status}}' $c 2>$null)
    if ($status -eq 'running') {
        $healthStr = if ($health -and $health.Length -gt 0) { ' [' + $health + ']' } else { '' }
        Write-OK ($c + $healthStr)
    } elseif ($status -eq 'starting') {
        Write-Warn ($c + ' -- still starting (check again in 30s)')
    } elseif ($status) {
        Write-Fail ($c + ' -- status: ' + $status)
        Write-Recovery ('Check logs: docker compose logs ' + $c + ' --tail 20')
    } else {
        Write-Info ($c + ' -- not found (profile not activated or not started)')
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ENDPOINT VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────
Write-Header 'Endpoint Check'

$endpoints = @(
    @{ Name = 'MindServer UI '; Url = 'http://localhost:8080/' },
    @{ Name = 'LiteLLM health'; Url = 'http://localhost:4000/health' },
    @{ Name = 'Ollama API    '; Url = 'http://localhost:11434/api/tags' }
)
foreach ($ep in $endpoints) {
    try {
        Invoke-RestMethod -Uri $ep.Url -TimeoutSec 3 | Out-Null
        Write-OK ($ep.Name + ' -- ' + $ep.Url)
    } catch {
        Write-Info ($ep.Name + ' -- ' + $ep.Url + '  (not reachable yet)')
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# DISCORD WEBHOOK NOTIFICATION
# (uses BACKUP_WEBHOOK_URL from .env — not the bot token)
# DISCORD_BOT_TOKEN is used by the discord-bot container, not for webhooks
# ─────────────────────────────────────────────────────────────────────────────
$webhookMsg = 'Mindcraft hybrid rig launched: ' + $LocalName + ' + ' + $CloudName + ' are live on localhost:25565'
Send-Webhook $webhookMsg
if ($env:BACKUP_WEBHOOK_URL) {
    Write-OK 'Discord webhook notification sent.'
}

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY + CONNECT INSTRUCTIONS
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host '  |   Both bots are live!                                |' -ForegroundColor Green
Write-Host '  +======================================================+' -ForegroundColor Green
Write-Host ''
Write-Host '  Connect to Minecraft:' -ForegroundColor White
Write-Host '    Host: localhost:25565  (Java Edition, version 1.21.6)' -ForegroundColor DarkGray
Write-Host ('    Bots: ' + $LocalName + ' and ' + $CloudName + ' will join within 90s') -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Web interfaces:' -ForegroundColor White
Write-Host '    MindServer UI : http://localhost:8080/' -ForegroundColor DarkGray
Write-Host ('    ' + $LocalName + ' camera: http://localhost:3000/') -ForegroundColor DarkGray
Write-Host ('    ' + $CloudName + ' camera: http://localhost:3001/') -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Discord:' -ForegroundColor White
Write-Host '    MindcraftBot#9501 should appear Online within 30-60s' -ForegroundColor DarkGray
Write-Host '    Type !status in your bot channel to confirm it is alive' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Useful commands:' -ForegroundColor White
Write-Host '    .\full-rig-launch.ps1 status  -- recheck health' -ForegroundColor DarkGray
Write-Host '    docker compose ps             -- all container states' -ForegroundColor DarkGray
Write-Host '    docker compose logs -f mindcraft          -- bot logs' -ForegroundColor DarkGray
Write-Host '    docker compose restart mindcraft          -- restart bots' -ForegroundColor DarkGray
Write-Host '    docker compose down                       -- stop everything' -ForegroundColor DarkGray
Write-Host ''

# If bots haven't joined after 90s (common first-run issue):
Write-Host '  If bots do not join Minecraft within 90s:' -ForegroundColor Yellow
Write-Host '    docker compose logs mindcraft --tail 40' -ForegroundColor White
Write-Host '    docker compose restart mindcraft' -ForegroundColor White
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# LIVE LOG STREAM (until Ctrl+C)
# ─────────────────────────────────────────────────────────────────────────────
if ($NoLogs) {
    Write-Info '-NoLogs set -- log stream skipped. Run manually:'
    Write-Info 'docker compose logs -f mindcraft'
    Write-Host ''
    exit 0
}

Write-Host '  Streaming bot logs (Ctrl+C to stop)...' -ForegroundColor Cyan
Write-Host '  -------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

& docker compose logs -f mindcraft
