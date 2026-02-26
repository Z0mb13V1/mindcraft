<#
.SYNOPSIS
    Hybrid Research Rig launcher — start local, cloud, or both bots.
.DESCRIPTION
    .\start.ps1 local   → LocalResearch_1 bot (Ollama/RTX 3090) + local MC server
    .\start.ps1 cloud   → CloudPersistent_1 bot (Gemini/Grok ensemble) + local MC server
    .\start.ps1 both    → Both bots in the same world
    .\start.ps1 stop    → Stop all running containers

    The PROFILES env var is set automatically to tell the mindcraft container
    which bot profile(s) to load.
.PARAMETER Mode
    Required. One of: local, cloud, both, stop
.PARAMETER McHost
    Override the Minecraft server host. Default: 'minecraft-server' (Docker service name).
    Set to a Tailscale IP (e.g., 100.64.0.2) to connect to an EC2 Minecraft server.
.PARAMETER WithLiteLLM
    Also start the LiteLLM proxy container (--profile litellm).
    Needed only if using profiles that route through LiteLLM.
.PARAMETER WithDiscord
    Also start the Discord bot container.
.PARAMETER NoOllama
    Skip Ollama health check. Use if Ollama is managed separately.
.PARAMETER Detach
    Run containers in the background (-d flag to docker compose).
.PARAMETER Build
    Force rebuild of the mindcraft Docker image before starting.
.EXAMPLE
    .\start.ps1 local
    .\start.ps1 both -Detach
    .\start.ps1 cloud -WithDiscord -Detach
    .\start.ps1 local -McHost 100.64.0.2        # Connect to EC2 MC via Tailscale
    .\start.ps1 stop
#>
param(
    [Parameter(Position=0, Mandatory)]
    [ValidateSet("local", "cloud", "both", "stop")]
    [string]$Mode,

    [string]$McHost,        # Override Minecraft host (Tailscale IP for EC2 world)
    [switch]$WithLiteLLM,   # Start LiteLLM proxy container
    [switch]$WithDiscord,   # Start Discord bot container
    [switch]$NoOllama,      # Skip Ollama health check
    [switch]$Detach,        # Run containers in background
    [switch]$Build          # Force Docker image rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"  # Don't abort on non-fatal errors

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Header { param([string]$m) Write-Host "" ; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Write-OK     { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info   { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }

# ── Stop mode ─────────────────────────────────────────────────────────────────

if ($Mode -eq "stop") {
    Write-Header "Stopping all containers"
    & docker compose down
    if ($LASTEXITCODE -eq 0) {
        Write-OK "All containers stopped."
    } else {
        Write-Fail "docker compose down returned exit code $LASTEXITCODE"
    }
    exit 0
}

# ── Map mode → profiles array ─────────────────────────────────────────────────
# The PROFILES env var is read by main.js (if set) to override settings.js profiles array.

$profilesJson = switch ($Mode) {
    "local" { '["./profiles/local-research.json"]' }
    "cloud" { '["./profiles/cloud-persistent.json"]' }
    "both"  { '["./profiles/local-research.json","./profiles/cloud-persistent.json"]' }
}

# ── Ollama health check (for local/both modes) ─────────────────────────────────

if ($Mode -in @("local", "both") -and -not $NoOllama) {
    Write-Header "Checking Ollama (local inference)"

    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 4
        $modelCount = if ($tags.models) { $tags.models.Count } else { 0 }
        Write-OK "Ollama running — $modelCount model(s) available."
    } catch {
        Write-Warn "Ollama not responding on port 11434."
        Write-Warn "Attempting to start Ollama..."
        $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
        if ($ollamaCmd) {
            Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
            Start-Sleep -Seconds 4
            try {
                Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5 | Out-Null
                Write-OK "Ollama started successfully."
            } catch {
                Write-Fail "Ollama still not responding. Run '.\setup-litellm.ps1' first."
                Write-Fail "Or use -NoOllama to skip this check."
                exit 1
            }
        } else {
            Write-Fail "Ollama not installed. Run '.\setup-litellm.ps1' first."
            exit 1
        }
    }
}

# ── Build SETTINGS_JSON override ──────────────────────────────────────────────
# Overrides settings.js at runtime via the SETTINGS_JSON env var (read in settings.js).
# We always set host here so the bots know which Minecraft server to connect to.

$settingsObj = @{
    auto_open_ui        = $false
    mindserver_host_public = $true
    host                = if ($McHost) { $McHost } else { "minecraft-server" }
}
$settingsJson = $settingsObj | ConvertTo-Json -Compress

# ── Set environment variables ──────────────────────────────────────────────────

$env:PROFILES     = $profilesJson
$env:SETTINGS_JSON = $settingsJson

# Load API keys from .env if they aren't already set in the environment
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

# ── Build docker compose command ───────────────────────────────────────────────

$composeArgs = @("compose")

# Activate Docker Compose profiles for optional services
if ($Mode -in @("local", "both")) {
    $composeArgs += "--profile", "local"   # enables nvidia-gpu-exporter
}
if ($Mode -in @("cloud", "both") -or $WithDiscord) {
    $composeArgs += "--profile", "cloud"   # enables discord-bot
}
if ($WithLiteLLM) {
    $composeArgs += "--profile", "litellm"  # enables litellm proxy
}

$composeArgs += "up"
if ($Build)  { $composeArgs += "--build" }
if ($Detach) { $composeArgs += "-d" }

# ── Print launch summary ───────────────────────────────────────────────────────

Write-Header "Research Rig: $($Mode.ToUpper())"
Write-Info "Profiles:    $profilesJson"
Write-Info "MC host:     $($settingsObj.host)"
if ($WithLiteLLM)  { Write-Info "LiteLLM:     enabled (port 4000)" }
if ($WithDiscord -or $Mode -in @("cloud","both")) { Write-Info "Discord:     enabled" }
Write-Info "Command:     docker $($composeArgs -join ' ')"
Write-Host ""

# ── Launch ─────────────────────────────────────────────────────────────────────

& docker @composeArgs

if ($LASTEXITCODE -eq 0 -and $Detach) {
    Write-Host ""
    Write-Header "Running — Endpoints"
    Write-Info "MindServer UI: http://localhost:8080/"
    Write-Info "Bot cameras:   http://localhost:3000/ (and 3001, 3002, 3003)"
    Write-Info "Minecraft:     localhost:25565"
    if ($Mode -in @("local","both")) {
        Write-Info "Ollama:        http://localhost:11434/"
    }
    if ($WithLiteLLM) {
        Write-Info "LiteLLM:       http://localhost:4000/"
    }
    Write-Host ""
    Write-Info "Logs:  docker compose logs -f mindcraft"
    Write-Info "Stop:  .\start.ps1 stop"
    Write-Host ""
}
