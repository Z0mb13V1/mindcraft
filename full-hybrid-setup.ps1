<#
.SYNOPSIS
    One-time master setup -- takes you from zero to both bots running.
.DESCRIPTION
    Runs every prerequisite check and setup step in order:
    1. Docker Desktop running
    2. GPU detection
    3. Ollama + model setup
    4. API keys present
    5. Profile validation
    6. Docker Compose validation
    7. Docker image build
    8. Directory structure
.PARAMETER SkipOllama
    Skip Ollama setup (use if you only want the cloud bot).
.PARAMETER PullLarge
    Also pull a larger Ollama model based on detected VRAM.
.EXAMPLE
    .\full-hybrid-setup.ps1
    .\full-hybrid-setup.ps1 -PullLarge
    .\full-hybrid-setup.ps1 -SkipOllama
#>
param(
    [switch]$SkipOllama,
    [switch]$PullLarge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$script:pass = 0
$script:fail = 0
$script:warn = 0

function Write-Step {
    param([int]$n, [int]$total, [string]$m)
    Write-Host ""
    Write-Host ('[' + $n + '/' + $total + '] ' + $m) -ForegroundColor Cyan
}

function Write-OK {
    param([string]$m)
    Write-Host ('  [PASS] ' + $m) -ForegroundColor Green
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

$totalSteps = 8

Write-Host ''
Write-Host '  +==================================================+' -ForegroundColor Cyan
Write-Host '  |    Mindcraft Hybrid Research Rig -- Full Setup   |' -ForegroundColor Cyan
Write-Host '  +==================================================+' -ForegroundColor Cyan

# ==============================================================================
# Step 1: Docker Desktop
# ==============================================================================

Write-Step 1 $totalSteps 'Checking Docker Desktop...'

$dockerInfo = & docker info 2>&1
if ($LASTEXITCODE -eq 0) {
    $dockerVersion = (& docker --version 2>&1).ToString().Trim()
    Write-OK ('Docker: ' + $dockerVersion)
} else {
    Write-Fail 'Docker Desktop is not running.'
    Write-Info 'Start Docker Desktop, wait for it to finish loading, then re-run this script.'
    exit 1
}

# ==============================================================================
# Step 2: GPU Detection
# ==============================================================================

Write-Step 2 $totalSteps 'Detecting GPU...'

$script:vramGB = 0

try {
    $gpuName = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>&1).ToString().Trim()
    $vramRaw = (& nvidia-smi '--query-gpu=memory.total' '--format=csv,noheader,nounits' 2>&1).ToString().Trim()
    $script:vramGB = [Math]::Round([int]$vramRaw / 1024, 1)
    # Build the GPU message with concatenation -- avoids parser confusion with
    # parentheses and variable names inside double-quoted strings.
    $gpuMsg = 'GPU: ' + $gpuName + ' (' + $script:vramGB + ' GB VRAM)'
    Write-OK $gpuMsg
} catch {
    Write-Warn 'nvidia-smi not found. GPU detection skipped.'
    Write-Info 'Local bot will still work if Ollama has a model loaded.'
}

# ==============================================================================
# Step 3: Ollama Setup
# ==============================================================================

if (-not $SkipOllama) {
    Write-Step 3 $totalSteps 'Setting up Ollama...'

    $setupScript = Join-Path $PSScriptRoot 'setup-litellm.ps1'
    if (Test-Path $setupScript) {
        # Use separate branches to avoid passing an empty-string argument,
        # which confuses PowerShell's parameter binder.
        if ($PullLarge) {
            & $setupScript -SkipLiteLLM -PullLarge 2>&1 | Out-Null
        } else {
            & $setupScript -SkipLiteLLM 2>&1 | Out-Null
        }
    } else {
        Write-Warn 'setup-litellm.ps1 not found -- skipping automated Ollama setup.'
        Write-Info 'Install Ollama manually from https://ollama.com/download'
    }

    # Verify Ollama independently after setup
    try {
        $tags = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 5
        $modelCount = if ($tags.models) { $tags.models.Count } else { 0 }
        if ($tags.models -and $tags.models.Count -gt 0) {
            $modelNames = ($tags.models | ForEach-Object { $_.name }) -join ', '
        } else {
            $modelNames = 'none'
        }
        Write-OK ('Ollama: ' + $modelCount + ' model(s) -- ' + $modelNames)
    } catch {
        Write-Fail 'Ollama not responding. Try running .\setup-litellm.ps1 manually.'
    }
} else {
    Write-Step 3 $totalSteps 'Ollama setup skipped (-SkipOllama)'
    Write-Info 'Use -SkipOllama only if you are running cloud-only mode.'
}

# ==============================================================================
# Step 4: API Keys
# ==============================================================================

Write-Step 4 $totalSteps 'Checking API keys...'

# Load from .env into current process environment
if (Test-Path '.env') {
    Get-Content '.env' | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)\s*$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            if ($val -and -not [System.Environment]::GetEnvironmentVariable($key)) {
                [System.Environment]::SetEnvironmentVariable($key, $val, 'Process')
            }
        }
    }
}

# Check keys.json fallback
$keysFromJson = $null
if (Test-Path 'keys.json') {
    try {
        $keysFromJson = Get-Content 'keys.json' -Raw | ConvertFrom-Json
    } catch {
        Write-Warn 'keys.json exists but could not be parsed as JSON.'
    }
}

$keyChecks = @(
    @{ Name = 'GEMINI_API_KEY';    EnvVal = $env:GEMINI_API_KEY;    JsonProp = 'GEMINI_API_KEY';    Required = $true  },
    @{ Name = 'XAI_API_KEY';       EnvVal = $env:XAI_API_KEY;       JsonProp = 'XAI_API_KEY';       Required = $true  },
    @{ Name = 'ANTHROPIC_API_KEY'; EnvVal = $env:ANTHROPIC_API_KEY; JsonProp = 'ANTHROPIC_API_KEY'; Required = $false },
    @{ Name = 'DISCORD_BOT_TOKEN'; EnvVal = $env:DISCORD_BOT_TOKEN; JsonProp = '';                  Required = $false }
)

foreach ($kc in $keyChecks) {
    $envVal = $kc.EnvVal
    $jsonProp = $kc.JsonProp
    $jsonVal = if ($keysFromJson -and $jsonProp -and $jsonProp.Length -gt 0) {
        $keysFromJson.$jsonProp
    } else {
        $null
    }
    $hasKey = ($envVal  -and $envVal.Length  -gt 5) -or
              ($jsonVal -and $jsonVal.Length -gt 5)

    if ($hasKey) {
        $src = if ($envVal -and $envVal.Length -gt 5) { '.env' } else { 'keys.json' }
        Write-OK ($kc.Name + ' found (' + $src + ')')
    } elseif ($kc.Required) {
        Write-Fail ($kc.Name + ' not set -- cloud ensemble bot will fail!')
        Write-Info 'Set it in .env or keys.json'
    } else {
        Write-Warn ($kc.Name + ' not set (optional)')
    }
}

# ==============================================================================
# Step 5: Profile Validation
# ==============================================================================

Write-Step 5 $totalSteps 'Validating bot profiles...'

$profileChecks = @(
    @{ Path = 'profiles/local-research.json';   Label = 'LocalResearch_1'  },
    @{ Path = 'profiles/cloud-persistent.json'; Label = 'CloudPersistent_1' },
    @{ Path = 'profiles/ensemble.json';          Label = 'Ensemble_1'        }
)

foreach ($pc in $profileChecks) {
    if (Test-Path $pc.Path) {
        try {
            $pj  = Get-Content $pc.Path -Raw | ConvertFrom-Json
            $tag = if ($pj.ensemble) { ' (ensemble)' } else { '' }
            Write-OK ($pc.Label + ' -- ' + $pc.Path + $tag)
        } catch {
            Write-Fail ($pc.Path + ' -- invalid JSON!')
        }
    } else {
        Write-Warn ($pc.Path + ' not found')
    }
}

# ==============================================================================
# Step 6: Docker Compose Validation
# ==============================================================================

Write-Step 6 $totalSteps 'Validating docker-compose.yml...'

$composeOut = & docker compose config --quiet 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK 'docker-compose.yml is valid'
} else {
    $errMsg = ($composeOut | Out-String).Trim()
    Write-Fail ('docker-compose.yml has errors: ' + $errMsg)
}

# ==============================================================================
# Step 7: Build Docker Image
# ==============================================================================

Write-Step 7 $totalSteps 'Building mindcraft Docker image...'
Write-Info '(Takes 2-5 minutes on first run -- subsequent builds use cache)'

& docker compose build mindcraft 2>&1 | ForEach-Object {
    $line = $_.ToString()
    if ($line -match 'Step|Successfully|CACHED|ERROR|error') {
        Write-Info $line
    }
}
if ($LASTEXITCODE -eq 0) {
    Write-OK 'Docker image built successfully.'
} else {
    Write-Fail 'Docker build failed. See output above.'
    Write-Info 'Run manually: docker compose build mindcraft'
}

# ==============================================================================
# Step 8: Directory Structure
# ==============================================================================

Write-Step 8 $totalSteps 'Ensuring directory structure...'

$dirs = @('bots', 'minecraft-data', 'experiments', 'backups')
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-OK ('Created ' + $d + '/')
    } else {
        Write-OK ($d + '/ exists')
    }
}

# ==============================================================================
# Summary
# ==============================================================================

Write-Host ''

$summaryColor = if ($script:fail -eq 0) { 'Green' } else { 'Red' }

# Build the summary line with concatenation so PS never tries to
# evaluate fail/warn/pass as part of an expression inside a string.
$summaryBody  = '  | Setup: ' + $script:pass + ' passed, ' + $script:warn + ' warned, ' + $script:fail + ' failed'
$summaryLine  = $summaryBody.PadRight(51) + '|'

Write-Host '  +==================================================+' -ForegroundColor $summaryColor
Write-Host $summaryLine                                               -ForegroundColor $summaryColor
Write-Host '  +==================================================+' -ForegroundColor $summaryColor
Write-Host ''

if ($script:fail -eq 0) {
    Write-Host '  Ready to launch! Choose a mode:' -ForegroundColor Green
    Write-Host ''
    Write-Host '    .\start.ps1 local -Detach     # Local bot only (Ollama + RTX 3090)' -ForegroundColor White
    Write-Host '    .\start.ps1 cloud -Detach     # Cloud ensemble only (Gemini + Grok)' -ForegroundColor White
    Write-Host '    .\start.ps1 both  -Detach     # Both bots in the same world'         -ForegroundColor White
    Write-Host ''
    Write-Host '  Then open in your browser:' -ForegroundColor DarkGray
    Write-Host '    MindServer UI : http://localhost:8080/' -ForegroundColor DarkGray
    Write-Host '    Bot Camera    : http://localhost:3000/' -ForegroundColor DarkGray
    Write-Host '    Minecraft     : localhost:25565'         -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Optional extras:' -ForegroundColor DarkGray
    Write-Host '    .\tailscale-setup.ps1    # Set up Tailscale VPN to EC2' -ForegroundColor DarkGray
    Write-Host '    .\deploy-to-aws.ps1      # Deploy cloud bot to AWS EC2'  -ForegroundColor DarkGray
    Write-Host ''
} else {
    $failCount = $script:fail.ToString()
    Write-Host ('  Fix the ' + $failCount + ' failure(s) above, then re-run:') -ForegroundColor Red
    Write-Host '  .\full-hybrid-setup.ps1' -ForegroundColor Red
    Write-Host ''
}
