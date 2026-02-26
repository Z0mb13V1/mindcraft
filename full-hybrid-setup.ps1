<#
.SYNOPSIS
    One-time master setup — takes you from zero to both bots running.
.DESCRIPTION
    Runs every prerequisite check and setup step in order:
    1. Docker Desktop running
    2. Ollama installed and serving
    3. Default model pulled
    4. API keys present
    5. Docker image build
    6. Ready-to-launch summary
.PARAMETER SkipOllama
    Skip Ollama setup (use if you only want cloud bot).
.PARAMETER PullLarge
    Also pull a larger Ollama model based on VRAM.
.EXAMPLE
    .\full-hybrid-setup.ps1
    .\full-hybrid-setup.ps1 -PullLarge
#>
param(
    [switch]$SkipOllama,
    [switch]$PullLarge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$pass = 0
$fail = 0
$warn = 0

function Write-Step  { param([int]$n, [int]$total, [string]$m) Write-Host "" ; Write-Host "[$n/$total] $m" -ForegroundColor Cyan }
function Write-OK    { param([string]$m) Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function Write-Warn  { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warn++ }
function Write-Fail  { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

$totalSteps = 8

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║    Mindcraft Hybrid Research Rig — Full Setup    ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── Step 1: Docker Desktop ──────────────────────────────────────────────────

Write-Step 1 $totalSteps "Checking Docker Desktop..."

$dockerInfo = & docker info 2>&1
if ($LASTEXITCODE -eq 0) {
    $dockerVersion = & docker --version 2>&1
    Write-OK "Docker: $dockerVersion"
} else {
    Write-Fail "Docker Desktop is not running."
    Write-Host "         Start Docker Desktop, wait for it to finish loading, then re-run this script." -ForegroundColor DarkGray
    exit 1
}

# ── Step 2: GPU Detection ──────────────────────────────────────────────────

Write-Step 2 $totalSteps "Detecting GPU..."

try {
    $gpuName = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>&1).Trim()
    $vramRaw = (& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>&1).Trim()
    $vramGB = [Math]::Round([int]$vramRaw / 1024, 1)
    Write-OK "GPU: $gpuName ($vramGB GB VRAM)"
} catch {
    Write-Warn "nvidia-smi not found. Local bot will still work if Ollama has a model loaded."
    $vramGB = 0
}

# ── Step 3: Ollama Setup ──────────────────────────────────────────────────

if (-not $SkipOllama) {
    Write-Step 3 $totalSteps "Setting up Ollama..."
    & "$PSScriptRoot\setup-litellm.ps1" -SkipLiteLLM $(if ($PullLarge) { "-PullLarge" } else { "" }) 2>&1 | Out-Null

    # Verify Ollama independently
    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5
        $modelCount = if ($tags.models) { $tags.models.Count } else { 0 }
        $modelNames = if ($tags.models) { ($tags.models | ForEach-Object { $_.name }) -join ", " } else { "none" }
        Write-OK "Ollama: $modelCount model(s) available — $modelNames"
    } catch {
        Write-Fail "Ollama not responding after setup. Try running '.\setup-litellm.ps1' manually."
    }
} else {
    Write-Step 3 $totalSteps "Ollama setup skipped (-SkipOllama)"
}

# ── Step 4: API Keys ──────────────────────────────────────────────────────

Write-Step 4 $totalSteps "Checking API keys..."

# Load from .env
if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)\s*$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim('"').Trim("'")
            if (-not [System.Environment]::GetEnvironmentVariable($key) -and $val) {
                [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
}

# Check keys.json fallback
$keysFromJson = @{}
if (Test-Path "keys.json") {
    try {
        $keysFromJson = Get-Content "keys.json" -Raw | ConvertFrom-Json
    } catch { }
}

$keyChecks = @(
    @{ Name = "GEMINI_API_KEY";  Env = $env:GEMINI_API_KEY;  Json = $keysFromJson.GEMINI_API_KEY; Required = $true },
    @{ Name = "XAI_API_KEY";     Env = $env:XAI_API_KEY;     Json = $keysFromJson.XAI_API_KEY;    Required = $true },
    @{ Name = "ANTHROPIC_API_KEY"; Env = $env:ANTHROPIC_API_KEY; Json = $keysFromJson.ANTHROPIC_API_KEY; Required = $false },
    @{ Name = "DISCORD_BOT_TOKEN"; Env = $env:DISCORD_BOT_TOKEN; Json = $null; Required = $false }
)

foreach ($kc in $keyChecks) {
    $hasKey = ($kc.Env -and $kc.Env.Length -gt 5) -or ($kc.Json -and $kc.Json.Length -gt 5)
    if ($hasKey) {
        $source = if ($kc.Env -and $kc.Env.Length -gt 5) { ".env" } else { "keys.json" }
        Write-OK "$($kc.Name) found ($source)"
    } elseif ($kc.Required) {
        Write-Fail "$($kc.Name) not set — cloud ensemble bot will fail!"
        Write-Host "         Set in .env or keys.json" -ForegroundColor DarkGray
    } else {
        Write-Warn "$($kc.Name) not set (optional)"
    }
}

# ── Step 5: Profile Validation ──────────────────────────────────────────────

Write-Step 5 $totalSteps "Validating profiles..."

$profileChecks = @(
    @{ Path = "profiles/local-research.json"; Name = "LocalResearch_1" },
    @{ Path = "profiles/cloud-persistent.json"; Name = "CloudPersistent_1" },
    @{ Path = "profiles/ensemble.json"; Name = "Ensemble_1" }
)
foreach ($pc in $profileChecks) {
    if (Test-Path $pc.Path) {
        try {
            $pj = Get-Content $pc.Path -Raw | ConvertFrom-Json
            $hasEnsemble = if ($pj.ensemble) { " (ensemble)" } else { "" }
            Write-OK "$($pc.Name) — $($pc.Path)$hasEnsemble"
        } catch {
            Write-Fail "$($pc.Path) — invalid JSON!"
        }
    } else {
        Write-Warn "$($pc.Path) not found"
    }
}

# ── Step 6: Docker Compose Validation ──────────────────────────────────────

Write-Step 6 $totalSteps "Validating docker-compose.yml..."

$composeCheck = & docker compose config --quiet 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-OK "docker-compose.yml is valid"
} else {
    Write-Fail "docker-compose.yml has errors: $composeCheck"
}

# ── Step 7: Pre-build Docker Image ──────────────────────────────────────────

Write-Step 7 $totalSteps "Building mindcraft Docker image..."
Write-Host "         (This takes 2-5 minutes on first run)" -ForegroundColor DarkGray

& docker compose build mindcraft 2>&1 | ForEach-Object {
    if ($_ -match "Step|Successfully|CACHED|ERROR") {
        Write-Host "         $_" -ForegroundColor DarkGray
    }
}
if ($LASTEXITCODE -eq 0) {
    Write-OK "Docker image built successfully."
} else {
    Write-Fail "Docker build failed. Check output above."
}

# ── Step 8: Create experiment directories ────────────────────────────────────

Write-Step 8 $totalSteps "Ensuring directory structure..."

$dirs = @("bots", "minecraft-data", "experiments")
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-OK "Created $d/"
    } else {
        Write-OK "$d/ exists"
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ║  Setup Complete: $pass passed, $warn warnings, $fail failures     ║" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })

if ($fail -eq 0) {
    Write-Host ""
    Write-Host "  Ready to launch! Run one of:" -ForegroundColor Green
    Write-Host ""
    Write-Host "    .\start.ps1 local -Detach      # Local bot only (Ollama RTX 3090)" -ForegroundColor White
    Write-Host "    .\start.ps1 cloud -Detach      # Cloud bot only (Gemini/Grok ensemble)" -ForegroundColor White
    Write-Host "    .\start.ps1 both -Detach       # Both bots in same world" -ForegroundColor White
    Write-Host ""
    Write-Host "  Then open:" -ForegroundColor DarkGray
    Write-Host "    MindServer UI:  http://localhost:8080/" -ForegroundColor DarkGray
    Write-Host "    Bot Camera:     http://localhost:3000/" -ForegroundColor DarkGray
    Write-Host "    Minecraft:      localhost:25565" -ForegroundColor DarkGray
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  Fix the failures above before launching." -ForegroundColor Red
    Write-Host ""
}
