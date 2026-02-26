<#
.SYNOPSIS
    One-click setup: Ollama (native Windows) + LiteLLM proxy (Docker).
.DESCRIPTION
    Step 1: Check/install Ollama via winget
    Step 2: Start Ollama service if not already running
    Step 3: Pull the default inference model (sweaterdog/andy-4)
    Step 4: Optionally pull a larger model based on detected VRAM
    Step 5: Start LiteLLM proxy container via docker compose (optional)
    Step 6: Print a health summary of all endpoints

    Run this script from PowerShell (not WSL). Docker Desktop must be running if
    you want the LiteLLM proxy. Ollama itself runs natively — no Docker needed.
.PARAMETER Model
    Ollama model to pull as the default. Default: sweaterdog/andy-4
.PARAMETER SkipLiteLLM
    Skip starting the LiteLLM Docker container. Use if you're hitting Ollama directly.
.PARAMETER PullLarge
    Pull a larger model based on available VRAM:
      >= 48 GB → llama3.1:70b-instruct-q4_K_M
      >= 24 GB → qwen2.5:32b-instruct-q4_K_M
      >= 12 GB → qwen2.5:14b-instruct-q4_K_M
.PARAMETER SkipModelPull
    Skip model pull (useful if models are already downloaded).
.EXAMPLE
    .\setup-litellm.ps1
    .\setup-litellm.ps1 -PullLarge
    .\setup-litellm.ps1 -SkipLiteLLM -SkipModelPull
#>
param(
    [string]$Model = "sweaterdog/andy-4",
    [switch]$SkipLiteLLM,
    [switch]$PullLarge,
    [switch]$SkipModelPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Step {
    param([int]$n, [string]$msg)
    Write-Host ""
    Write-Host "[$n] $msg" -ForegroundColor Cyan
}

function Write-OK   { param([string]$m) Write-Host "    OK  $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    WARN $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    FAIL $m" -ForegroundColor Red }

function Test-OllamaRunning {
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 3
        return $true
    } catch {
        return $false
    }
}

function Wait-OllamaReady {
    param([int]$TimeoutSec = 30)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSec) {
        if (Test-OllamaRunning) { return $true }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    return $false
}

# ── Step 1: Check/install Ollama ───────────────────────────────────────────────

Write-Step 1 "Checking Ollama installation..."

$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    $ollamaVer = & ollama --version 2>&1
    Write-OK "Ollama found: $ollamaVer"
} else {
    Write-Warn "Ollama not found. Installing via winget..."
    try {
        winget install Ollama.Ollama --accept-source-agreements --accept-package-agreements
        Write-OK "Ollama installed. Refreshing PATH..."
        # Refresh PATH in current session
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH", "User")
    } catch {
        Write-Fail "winget install failed: $_"
        Write-Fail "Download manually from https://ollama.com/download"
        exit 1
    }
}

# ── Step 2: Start Ollama service ────────────────────────────────────────────────

Write-Step 2 "Starting Ollama service..."

if (Test-OllamaRunning) {
    Write-OK "Ollama is already running on port 11434."
} else {
    Write-Warn "Ollama not responding. Launching 'ollama serve'..."
    Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
    if (Wait-OllamaReady -TimeoutSec 20) {
        Write-OK "Ollama service started."
    } else {
        Write-Fail "Ollama didn't start within 20 seconds. Check if port 11434 is blocked."
        exit 1
    }
}

# ── Step 3: Pull default inference model ───────────────────────────────────────

if (-not $SkipModelPull) {
    Write-Step 3 "Pulling default model: $Model"
    Write-Warn "(This may take a few minutes on first run — model is ~3GB)"
    & ollama pull $Model
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Model '$Model' ready."
    } else {
        Write-Fail "Failed to pull '$Model'. Check model name at https://ollama.com/library"
        exit 1
    }
} else {
    Write-Step 3 "Skipping model pull (-SkipModelPull flag set)."
}

# ── Step 4: Optionally pull a larger model based on VRAM ──────────────────────

if ($PullLarge) {
    Write-Step 4 "Detecting VRAM for large model selection..."
    try {
        $vramRaw = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>&1
        $vramMB = [int]($vramRaw.Trim())
        $vramGB = [Math]::Round($vramMB / 1024, 1)
        Write-OK "Detected: ${vramGB} GB VRAM"

        if ($vramMB -ge 46000) {
            $largeModel = "llama3.1:70b-instruct-q4_K_M"
        } elseif ($vramMB -ge 22000) {
            $largeModel = "qwen2.5:32b-instruct-q4_K_M"
        } elseif ($vramMB -ge 10000) {
            $largeModel = "qwen2.5:14b-instruct-q4_K_M"
        } else {
            Write-Warn "Less than 10GB VRAM — skipping large model pull."
            $largeModel = $null
        }

        if ($largeModel) {
            Write-Warn "Pulling $largeModel — this may take 10-30 minutes..."
            & ollama pull $largeModel
            if ($LASTEXITCODE -eq 0) {
                Write-OK "Large model '$largeModel' ready."
                Write-OK "To use it, change 'model' in profiles/local-research.json to '$largeModel'."
            } else {
                Write-Warn "Failed to pull $largeModel. You can pull it manually later."
            }
        }
    } catch {
        Write-Warn "nvidia-smi not found or failed. Skipping large model detection."
        Write-Warn "Run 'ollama pull qwen2.5:32b-instruct-q4_K_M' manually if you have 24GB+ VRAM."
    }
} else {
    Write-Step 4 "Skipping large model pull (use -PullLarge to enable)."
}

# ── Step 5: Start LiteLLM Docker container ────────────────────────────────────

if (-not $SkipLiteLLM) {
    Write-Step 5 "Starting LiteLLM proxy container..."

    # Verify Docker is available
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) {
        Write-Warn "Docker not found. Skipping LiteLLM container."
        Write-Warn "Install Docker Desktop from https://www.docker.com/products/docker-desktop/"
        $SkipLiteLLM = $true
    } else {
        try {
            & docker compose --profile litellm up -d litellm
            if ($LASTEXITCODE -eq 0) {
                Write-OK "LiteLLM container started."
                Start-Sleep -Seconds 3

                # Health check
                try {
                    $health = Invoke-RestMethod -Uri "http://localhost:4000/health" -TimeoutSec 5
                    Write-OK "LiteLLM health check passed."
                } catch {
                    Write-Warn "LiteLLM container started but health endpoint not yet ready."
                    Write-Warn "Wait ~10 seconds then check: http://localhost:4000/health"
                }
            } else {
                Write-Warn "LiteLLM container failed to start. Check docker compose logs litellm."
            }
        } catch {
            Write-Warn "Failed to start LiteLLM: $_"
        }
    }
} else {
    Write-Step 5 "Skipping LiteLLM container (-SkipLiteLLM flag set)."
}

# ── Step 6: Summary ────────────────────────────────────────────────────────────

Write-Step 6 "Setup complete. Endpoint summary:"
Write-Host ""
Write-Host "  Ollama (native Windows):  http://localhost:11434/" -ForegroundColor White
Write-Host "    Models:  ollama list" -ForegroundColor DarkGray

if (-not $SkipLiteLLM) {
    Write-Host "  LiteLLM proxy (Docker):   http://localhost:4000/" -ForegroundColor White
    Write-Host "    Health:  http://localhost:4000/health" -ForegroundColor DarkGray
    Write-Host "    Models:  http://localhost:4000/v1/models" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    .\start.ps1 local          # Start LocalResearch_1 bot (uses Ollama)" -ForegroundColor DarkGray
Write-Host "    .\start.ps1 both           # Start both bots in the same world" -ForegroundColor DarkGray
Write-Host "    .\start.ps1 local -WithLiteLLM  # With LiteLLM proxy" -ForegroundColor DarkGray
Write-Host ""
