<#
.SYNOPSIS
    Fast-path launcher for the Mindcraft hybrid research rig.
.DESCRIPTION
    Assumes Ollama is already running with sweaterdog/andy-4 loaded.
    Validates prerequisites, then launches both bots via start.ps1.
    Passes -NoOllama to start.ps1 to skip the pull logic that was crashing.
.PARAMETER WithLiteLLM
    Also start the LiteLLM proxy container (needed only if profiles route through it).
.PARAMETER Build
    Force-rebuild the mindcraft Docker image before launching.
.PARAMETER NoLaunch
    Run validation checks only -- do not start the bots.
.EXAMPLE
    .\launch-rig.ps1
    .\launch-rig.ps1 -Build
    .\launch-rig.ps1 -NoLaunch
#>
param(
    [switch]$WithLiteLLM,
    [switch]$Build,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:pass = 0
$script:fail = 0
$script:warn = 0

# ── Helpers ──────────────────────────────────────────────────────────────────

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
    Write-Host ('  >>> ' + $m) -ForegroundColor Yellow
}

# ── Banner ────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  +====================================================+' -ForegroundColor Cyan
Write-Host '  |   Mindcraft Hybrid Rig -- Fast Launch              |' -ForegroundColor Cyan
Write-Host '  |   Ollama already running -- no model pulls         |' -ForegroundColor Cyan
Write-Host '  +====================================================+' -ForegroundColor Cyan
Write-Host ''

# ── [1/6] Docker Desktop ─────────────────────────────────────────────────────

Write-Header '[1/6] Docker Desktop'

$dockerInfo = & docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'Docker Desktop is not running.'
    Write-Recovery 'Start Docker Desktop, wait for the whale icon in the taskbar, then rerun.'
    exit 1
}
$dockerVer = (& docker --version 2>&1).ToString().Trim()
Write-OK $dockerVer

# ── [2/6] GPU (informational) ────────────────────────────────────────────────

Write-Header '[2/6] GPU'

try {
    $gpuName = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>&1).ToString().Trim()
    $vramRaw  = (& nvidia-smi '--query-gpu=memory.total' '--format=csv,noheader,nounits' 2>&1).ToString().Trim()
    $vramGB   = [Math]::Round([int]$vramRaw / 1024, 1)
    $gpuMsg   = 'GPU: ' + $gpuName + ' -- ' + $vramGB + ' GB VRAM'
    Write-OK $gpuMsg
} catch {
    Write-Warn 'nvidia-smi not available (GPU check skipped -- Ollama already loaded, ok to continue).'
}

# ── [3/6] Ollama -- verify only, zero pulls ───────────────────────────────────

Write-Header '[3/6] Ollama (verify only -- no pulls)'

$ollamaTags   = $null
$ollamaOnline = $false

try {
    $ollamaTags   = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 5
    $ollamaOnline = $true
} catch {
    Write-Fail 'Ollama API not responding on http://localhost:11434/'
    Write-Recovery 'Run in a NEW terminal:  ollama serve'
    Write-Recovery 'Wait 5 seconds, then rerun:  .\launch-rig.ps1'
}

if ($ollamaOnline) {
    $modelCount = if ($ollamaTags.models) { $ollamaTags.models.Count } else { 0 }
    Write-OK ('Ollama API responding -- ' + $modelCount + ' model(s) available')

    $andyModel = $null
    if ($ollamaTags.models) {
        $andyModel = $ollamaTags.models | Where-Object { $_.name -like 'sweaterdog/andy*' } | Select-Object -First 1
    }

    if ($andyModel) {
        Write-OK ('Model ready: ' + $andyModel.name)
    } else {
        Write-Fail 'sweaterdog/andy-4 not found in Ollama model list.'
        Write-Recovery 'Run:  ollama pull sweaterdog/andy-4'
        Write-Recovery 'Then rerun this script.'
    }
}

# ── [4/6] API Keys ────────────────────────────────────────────────────────────

Write-Header '[4/6] API Keys'

# Load .env into process environment
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
}

# Load keys.json fallback
$kj = $null
if (Test-Path 'keys.json') {
    try { $kj = Get-Content 'keys.json' -Raw | ConvertFrom-Json } catch {
        Write-Warn 'keys.json could not be parsed as JSON.'
    }
}

function Test-ApiKey {
    param([string]$Name, [string]$EnvVal, [string]$JsonProp, [bool]$Required)
    $ev = $EnvVal
    $jv = $null
    if ($kj -and $JsonProp -and $JsonProp.Length -gt 0) {
        $jv = $kj.$JsonProp
    }
    $ok = ($ev -and $ev.Length -gt 5) -or ($jv -and $jv.Length -gt 5)
    if ($ok) {
        $src = if ($ev -and $ev.Length -gt 5) { '.env' } else { 'keys.json' }
        Write-OK ($Name + ' found (' + $src + ')')
    } elseif ($Required) {
        Write-Fail ($Name + ' missing -- cloud bot will fail to make API calls')
        Write-Recovery ('Add to .env:  ' + $Name + '=your-key-here')
    } else {
        Write-Warn ($Name + ' not set (optional)')
    }
}

Test-ApiKey 'GEMINI_API_KEY'    $env:GEMINI_API_KEY    'GEMINI_API_KEY'    $true
Test-ApiKey 'XAI_API_KEY'       $env:XAI_API_KEY       'XAI_API_KEY'       $true
Test-ApiKey 'ANTHROPIC_API_KEY' $env:ANTHROPIC_API_KEY 'ANTHROPIC_API_KEY' $false
Test-ApiKey 'DISCORD_BOT_TOKEN' $env:DISCORD_BOT_TOKEN ''                  $false

# ── [5/6] Bot Profiles ────────────────────────────────────────────────────────

Write-Header '[5/6] Bot Profiles'

$profilesToCheck = @(
    'profiles/local-research.json',
    'profiles/cloud-persistent.json'
)

foreach ($pPath in $profilesToCheck) {
    if (Test-Path $pPath) {
        try {
            $pData = Get-Content $pPath -Raw | ConvertFrom-Json
            $botName = if ($pData.name) { $pData.name } else { '(unnamed)' }
            Write-OK ($botName + ' -- ' + $pPath)
        } catch {
            Write-Fail ($pPath + ' -- invalid JSON, cannot parse')
        }
    } else {
        Write-Fail ($pPath + ' -- file not found')
        Write-Recovery ('Restore from git:  git checkout -- ' + $pPath)
    }
}

# Ensure runtime directories exist
foreach ($d in @('bots', 'minecraft-data', 'experiments', 'backups')) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Info ('Created directory: ' + $d + '/')
    }
}

# ── [6/6] docker-compose.yml ──────────────────────────────────────────────────

Write-Header '[6/6] docker-compose.yml'

$composeErr = & docker compose config --quiet 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK 'docker-compose.yml is valid'
} else {
    Write-Fail 'docker-compose.yml has syntax errors'
    Write-Info ('Error: ' + ($composeErr | Out-String).Trim())
    Write-Recovery 'Run:  docker compose config  -- to see the full error'
}

# ── Check summary ─────────────────────────────────────────────────────────────

Write-Host ''
$summaryColor = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
$summaryLine  = '  Checks: ' + $script:pass + ' passed  ' + $script:warn + ' warnings  ' + $script:fail + ' failed'
Write-Host $summaryLine -ForegroundColor $summaryColor
Write-Host ''

if ($script:fail -gt 0) {
    Write-Host '  Fix the failures above (recovery commands shown above each), then rerun:' -ForegroundColor Red
    Write-Host '    .\launch-rig.ps1' -ForegroundColor Red
    Write-Host ''
    exit 1
}

if ($NoLaunch) {
    Write-Host '  All checks passed. -NoLaunch set -- skipping startup.' -ForegroundColor Yellow
    exit 0
}

# ── Optional: LiteLLM ─────────────────────────────────────────────────────────

if ($WithLiteLLM) {
    Write-Header 'LiteLLM Proxy'
    $litellmUp = $false
    try {
        Invoke-RestMethod -Uri 'http://localhost:4000/health' -TimeoutSec 3 | Out-Null
        $litellmUp = $true
    } catch { }

    if ($litellmUp) {
        Write-OK 'LiteLLM already running on :4000'
    } else {
        Write-Info 'Starting LiteLLM proxy...'
        & docker compose --profile litellm up -d litellm 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-OK 'LiteLLM container started (allow 15-20s to become healthy)'
        } else {
            Write-Warn 'LiteLLM failed to start -- bots will use direct API (ok for most configs)'
        }
    }
}

# ── Launch ────────────────────────────────────────────────────────────────────

Write-Header 'Launching Both Bots'

# -NoOllama is the critical flag: it bypasses start.ps1's ollama pull logic
# that was causing the crash. We already verified Ollama above.
$startArgs = @('both', '-Detach', '-NoOllama')
if ($Build)        { $startArgs += '-Build' }
if ($WithLiteLLM)  { $startArgs += '-WithLiteLLM' }

$startScript = Join-Path $PSScriptRoot 'start.ps1'
Write-Info ('Running: .\start.ps1 ' + ($startArgs -join ' '))
Write-Host ''

& $startScript @startArgs

$launchCode = $LASTEXITCODE

# ── Result ────────────────────────────────────────────────────────────────────

if ($launchCode -ne 0) {
    Write-Host ''
    $exitMsg = '  [FAIL] start.ps1 exited with code ' + $launchCode.ToString()
    Write-Host $exitMsg -ForegroundColor Red
    Write-Host ''
    Write-Host '  Recovery steps:' -ForegroundColor Yellow
    Write-Host '    1. Read logs:   docker compose logs --tail 50' -ForegroundColor White
    Write-Host '    2. Hard reset:  docker compose down' -ForegroundColor White
    Write-Host '                    .\launch-rig.ps1 -Build' -ForegroundColor White
    Write-Host '    3. Inspect:     docker compose ps' -ForegroundColor White
    Write-Host ''
    exit $launchCode
}

# start.ps1 already prints health progress + endpoints when -Detach is used.
# We add Discord-specific instructions below.

Write-Host ''
Write-Host '  +====================================================+' -ForegroundColor Green
Write-Host '  |   Both bots launching -- check Discord & MC now   |' -ForegroundColor Green
Write-Host '  +====================================================+' -ForegroundColor Green
Write-Host ''
Write-Host '  Discord check:' -ForegroundColor White
Write-Host '    1. Open your Discord server' -ForegroundColor DarkGray
Write-Host '    2. MindcraftBot#9501 should go Online within 30-60s' -ForegroundColor DarkGray
Write-Host '    3. Type !status in your bot channel to confirm it is alive' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Minecraft check:' -ForegroundColor White
Write-Host '    1. Open Minecraft Java Edition' -ForegroundColor DarkGray
Write-Host '    2. Multiplayer > Add Server > localhost:25565' -ForegroundColor DarkGray
Write-Host '    3. Within 90s you should see LocalResearch_1 and CloudPersistent_1 join' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  If bots do not join within 90s:' -ForegroundColor Yellow
Write-Host '    docker compose logs mindcraft --tail 40' -ForegroundColor White
Write-Host '    docker compose restart mindcraft' -ForegroundColor White
Write-Host ''
Write-Host '  Useful commands:' -ForegroundColor White
Write-Host '    .\start.ps1 status    -- show all container health' -ForegroundColor DarkGray
Write-Host '    .\start.ps1 stop      -- graceful shutdown' -ForegroundColor DarkGray
