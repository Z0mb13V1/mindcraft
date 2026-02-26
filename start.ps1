<#
.SYNOPSIS
    Hybrid Research Rig launcher — start local, cloud, or both bots.
.DESCRIPTION
    .\start.ps1 local   → LocalResearch_1 bot (Ollama/RTX 3090) + local MC server
    .\start.ps1 cloud   → CloudPersistent_1 bot (Gemini/Grok ensemble) + local MC server
    .\start.ps1 both    → Both bots in the same world
    .\start.ps1 stop    → Graceful shutdown of all containers
    .\start.ps1 status  → Show container health + endpoint checks
.PARAMETER Mode
    Required. One of: local, cloud, both, stop, status
.PARAMETER McHost
    Override the Minecraft server host. Default: 'minecraft-server' (Docker service name).
    Set to a Tailscale IP (e.g., 100.64.0.2) to connect to an EC2 Minecraft server.
.PARAMETER WithLiteLLM
    Also start the LiteLLM proxy container (--profile litellm).
.PARAMETER WithDiscord
    Also start the Discord bot container.
.PARAMETER NoOllama
    Skip Ollama health check. Use if Ollama is managed separately.
.PARAMETER Detach
    Run containers in the background (-d flag to docker compose).
.PARAMETER Build
    Force rebuild of the mindcraft Docker image before starting.
.EXAMPLE
    .\start.ps1 local -Detach
    .\start.ps1 both -Detach -Build
    .\start.ps1 cloud -WithDiscord -Detach
    .\start.ps1 local -McHost 100.64.0.2
    .\start.ps1 status
    .\start.ps1 stop
#>
param(
    [Parameter(Position=0, Mandatory)]
    [ValidateSet("local", "cloud", "both", "stop", "status")]
    [string]$Mode,

    [string]$McHost,        # Override Minecraft host (Tailscale IP for EC2 world)
    [switch]$WithLiteLLM,   # Start LiteLLM proxy container
    [switch]$WithDiscord,   # Start Discord bot container
    [switch]$NoOllama,      # Skip Ollama health check
    [switch]$Detach,        # Run containers in background
    [switch]$Build          # Force Docker image rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Header { param([string]$m) Write-Host "" ; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Write-OK     { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info   { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }

function Test-Endpoint {
    param([string]$Name, [string]$Url, [int]$TimeoutSec = 3)
    try {
        Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec | Out-Null
        Write-OK "$Name — $Url"
        return $true
    } catch {
        Write-Fail "$Name — $Url (unreachable)"
        return $false
    }
}

function Send-DiscordWebhook {
    param([string]$Message)
    # Use BACKUP_WEBHOOK_URL from .env for operational notifications
    $webhook = $env:BACKUP_WEBHOOK_URL
    if (-not $webhook) { return }
    try {
        $body = @{ content = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $webhook -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5 | Out-Null
    } catch { }  # non-critical — don't fail if webhook is down
}

# ── Status mode ──────────────────────────────────────────────────────────────

if ($Mode -eq "status") {
    Write-Header "Research Rig Status"

    # Container status
    Write-Host ""
    Write-Host "  Docker Containers:" -ForegroundColor White
    $containers = & docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>&1
    if ($LASTEXITCODE -eq 0) {
        $containers | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
        Write-Warn "No containers running."
    }

    # Endpoint health checks
    Write-Host ""
    Write-Host "  Endpoints:" -ForegroundColor White
    Test-Endpoint "Minecraft"  "http://localhost:25565" 2 | Out-Null  # MC won't respond to HTTP, but port check
    Test-Endpoint "MindServer" "http://localhost:8080/" | Out-Null
    Test-Endpoint "Bot Camera" "http://localhost:3000/" | Out-Null

    # Ollama
    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
        $models = if ($tags.models) { ($tags.models | ForEach-Object { $_.name }) -join ", " } else { "none" }
        Write-OK "Ollama — http://localhost:11434/ ($models)"
    } catch {
        Write-Info "Ollama — not running"
    }

    # LiteLLM
    Test-Endpoint "LiteLLM" "http://localhost:4000/health" | Out-Null

    # GPU
    Write-Host ""
    try {
        $gpu = & nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>&1
        Write-Host "  GPU: $gpu" -ForegroundColor DarkGray
    } catch {
        Write-Info "GPU: nvidia-smi not available"
    }
    Write-Host ""
    exit 0
}

# ── Stop mode ─────────────────────────────────────────────────────────────────

if ($Mode -eq "stop") {
    Write-Header "Graceful Shutdown"

    # Notify Discord before stopping
    Send-DiscordWebhook "🔴 **Research Rig** shutting down (manual stop)"

    # Stop mindcraft first (lets agents disconnect cleanly)
    Write-Info "Stopping mindcraft agents..."
    & docker compose stop mindcraft 2>$null
    Start-Sleep -Seconds 2

    # Then stop everything else
    Write-Info "Stopping all containers..."
    & docker compose down
    if ($LASTEXITCODE -eq 0) {
        Write-OK "All containers stopped."
    } else {
        Write-Fail "docker compose down returned exit code $LASTEXITCODE"
    }
    exit 0
}

# ── Map mode → profiles array ─────────────────────────────────────────────────

$profilesJson = switch ($Mode) {
    "local" { '["./profiles/local-research.json"]' }
    "cloud" { '["./profiles/cloud-persistent.json"]' }
    "both"  { '["./profiles/local-research.json","./profiles/cloud-persistent.json"]' }
}

# ── Docker Desktop check ─────────────────────────────────────────────────────

$dockerCheck = & docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Docker Desktop is not running. Start it first."
    exit 1
}

# ── Ollama health check (for local/both modes) ─────────────────────────────────

if ($Mode -in @("local", "both") -and -not $NoOllama) {
    Write-Header "Checking Ollama (local inference)"

    $ollamaReady = $false
    try {
        $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 4
        $modelCount = if ($tags.models) { $tags.models.Count } else { 0 }
        Write-OK "Ollama running — $modelCount model(s) available."
        $ollamaReady = $true
    } catch {
        Write-Warn "Ollama not responding on port 11434."
        Write-Warn "Attempting to start Ollama..."
        $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
        if ($ollamaCmd) {
            Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
            # Wait with progress dots
            for ($i = 0; $i -lt 8; $i++) {
                Start-Sleep -Seconds 1
                Write-Host "." -NoNewline -ForegroundColor DarkGray
                try {
                    Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 2 | Out-Null
                    $ollamaReady = $true
                    break
                } catch { }
            }
            Write-Host ""
            if ($ollamaReady) {
                Write-OK "Ollama started successfully."
            } else {
                Write-Fail "Ollama still not responding. Run '.\setup-litellm.ps1' first."
                Write-Fail "Or use -NoOllama to skip this check."
                exit 1
            }
        } else {
            Write-Fail "Ollama not installed. Run '.\setup-litellm.ps1' first."
            exit 1
        }
    }

    # Verify the required model is pulled
    if ($ollamaReady) {
        try {
            $tags = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
            $hasAndy = $tags.models | Where-Object { $_.name -like "sweaterdog/andy*" }
            if (-not $hasAndy) {
                Write-Warn "Model 'sweaterdog/andy-4' not found. Pulling now (first time only)..."
                & ollama pull sweaterdog/andy-4
            }
        } catch { }
    }
}

# ── Build SETTINGS_JSON override ──────────────────────────────────────────────

$settingsObj = @{
    auto_open_ui           = $false
    mindserver_host_public = $true
    host                   = if ($McHost) { $McHost } else { "minecraft-server" }
}
$settingsJson = $settingsObj | ConvertTo-Json -Compress

# ── Set environment variables ──────────────────────────────────────────────────

$env:PROFILES      = $profilesJson
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

# Verify API keys for cloud mode
if ($Mode -in @("cloud", "both")) {
    $missingKeys = @()
    if (-not $env:GEMINI_API_KEY) { $missingKeys += "GEMINI_API_KEY" }
    if (-not $env:XAI_API_KEY)    { $missingKeys += "XAI_API_KEY" }
    if ($missingKeys.Count -gt 0) {
        Write-Warn "Missing API keys for cloud ensemble: $($missingKeys -join ', ')"
        Write-Warn "Set them in .env or keys.json. Cloud bot may fail to respond."
    }
}

# ── Build docker compose command ───────────────────────────────────────────────

$composeArgs = @("compose")

if ($Mode -in @("local", "both")) {
    $composeArgs += "--profile", "local"
}
if ($Mode -in @("cloud", "both") -or $WithDiscord) {
    $composeArgs += "--profile", "cloud"
}
if ($WithLiteLLM) {
    $composeArgs += "--profile", "litellm"
}

$composeArgs += "up"
if ($Build)  { $composeArgs += "--build" }
if ($Detach) { $composeArgs += "-d" }

# ── Print launch summary ───────────────────────────────────────────────────────

Write-Header "Research Rig: $($Mode.ToUpper())"
Write-Info "Profiles:    $profilesJson"
Write-Info "MC host:     $($settingsObj.host)"
if ($Mode -in @("local","both")) { Write-Info "Ollama:      http://localhost:11434/" }
if ($WithLiteLLM)  { Write-Info "LiteLLM:     enabled (port 4000)" }
if ($WithDiscord -or $Mode -in @("cloud","both")) { Write-Info "Discord:     enabled" }
Write-Info "Command:     docker $($composeArgs -join ' ')"
Write-Host ""

# ── Launch ─────────────────────────────────────────────────────────────────────

$startTime = Get-Date
& docker @composeArgs

if ($LASTEXITCODE -eq 0 -and $Detach) {
    $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds)

    # Wait for services to become healthy
    Write-Header "Waiting for services..."
    $maxWait = 90
    $waited = 0
    $healthy = $false
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5
        $mindcraftStatus = (& docker inspect --format '{{.State.Health.Status}}' mindcraft-agents 2>$null)
        $mcStatus = (& docker inspect --format '{{.State.Health.Status}}' minecraft-server 2>$null)

        $pct = [Math]::Min(100, [Math]::Round($waited / $maxWait * 100))
        Write-Host "`r  [$("=" * ($pct/5))$(" " * (20 - $pct/5))] ${pct}% — MC:$mcStatus Mindcraft:$mindcraftStatus" -NoNewline -ForegroundColor DarkGray

        if ($mindcraftStatus -eq "healthy" -and $mcStatus -eq "healthy") {
            $healthy = $true
            break
        }
    }
    Write-Host ""

    if ($healthy) {
        Write-OK "All services healthy. (${waited}s)"
        Send-DiscordWebhook "🟢 **Research Rig** started — mode: **$Mode** | profiles: $profilesJson"
    } else {
        Write-Warn "Services not fully healthy after ${maxWait}s. Check: docker compose logs -f"
    }

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
    Write-Info "Logs:    docker compose logs -f mindcraft"
    Write-Info "Status:  .\start.ps1 status"
    Write-Info "Stop:    .\start.ps1 stop"
    Write-Host ""
}
