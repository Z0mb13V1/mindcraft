<#
.SYNOPSIS
    Robust Ollama + LiteLLM setup — handles missing winget
#>
param(
    [string]$Model = "sweaterdog/andy-4",
    [switch]$SkipLiteLLM,
    [switch]$PullLarge,
    [switch]$SkipModelPull
)

$ErrorActionPreference = "Stop"
Write-Host "=== Ollama & LiteLLM Setup ===" -ForegroundColor Cyan

# Check if Ollama is already installed
if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "Ollama not found in PATH." -ForegroundColor Yellow
    Write-Host "Please install it manually from https://ollama.com/download" -ForegroundColor Yellow
    Write-Host "After installing, close and reopen PowerShell, then run this script again."
    exit 1
}

# Start Ollama service
Write-Host "Starting Ollama service..."
Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
Start-Sleep -Seconds 10

# Pull main model
if (-not $SkipModelPull) {
    Write-Host "Pulling $Model..." -ForegroundColor Yellow
    ollama pull $Model
}

# Optional large model for 3090
if ($PullLarge) {
    Write-Host "Pulling large model..." -ForegroundColor Yellow
    ollama pull qwen2.5:32b-instruct-q4_K_M
}

# Start LiteLLM (if not skipped)
if (-not $SkipLiteLLM) {
    Write-Host "Starting LiteLLM proxy..." -ForegroundColor Yellow
    docker compose --profile litellm up -d litellm
}

Write-Host "✅ Ollama + LiteLLM setup complete!" -ForegroundColor Green
