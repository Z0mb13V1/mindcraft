# ── Setup Ubuntu WSL2 + vLLM (Windows 11) ────────────────────────────────────
# Run this from PowerShell AS ADMINISTRATOR.
# Once Ubuntu is installed you only need start.sh for subsequent runs.
# Usage:  .\setup-wsl-vllm.ps1
# ─────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "=== WSL2 + vLLM Setup ===" -ForegroundColor Cyan
Write-Host ""

# 1. Check we're admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Run this script as Administrator (right-click -> Run as administrator)" -ForegroundColor Red
    exit 1
}

# 2. Enable WSL2 if not present
$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux
if ($wslFeature.State -ne 'Enabled') {
    Write-Host "[1/4] Enabling WSL feature..." -ForegroundColor Yellow
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
    Write-Host "      Reboot required! Re-run this script after rebooting." -ForegroundColor Red
    exit 0
}
Write-Host "[1/4] WSL feature: enabled" -ForegroundColor Green

# 3. Install Ubuntu 22.04 if not present
$distros = wsl --list --quiet 2>$null
if ($distros -notmatch 'Ubuntu') {
    Write-Host "[2/4] Installing Ubuntu 22.04..." -ForegroundColor Yellow
    wsl --install -d Ubuntu-22.04
    Write-Host ""
    Write-Host "Ubuntu installed. Set your username/password in the Ubuntu window that opened," -ForegroundColor Cyan
    Write-Host "then re-run this script to continue setup." -ForegroundColor Cyan
    exit 0
}
Write-Host "[2/4] Ubuntu WSL2: installed" -ForegroundColor Green

# 4. Copy install.sh into WSL2 and run it
Write-Host "[3/4] Running vLLM install script in Ubuntu WSL2..." -ForegroundColor Yellow
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installSh = Join-Path $scriptDir "services\vllm\install.sh"

# Convert Windows path to WSL path
$wslInstallPath = wsl -- wslpath -u "$installSh"

wsl -d Ubuntu-22.04 -- bash -c "chmod +x '$wslInstallPath' && bash '$wslInstallPath'"

Write-Host ""
Write-Host "[4/4] Done! To start vLLM:" -ForegroundColor Green
Write-Host ""
Write-Host "  Option A (foreground, in a new WSL terminal):" -ForegroundColor Cyan
$startSh  = Join-Path $scriptDir "services\vllm\start.sh"
$wslStartPath = wsl -d Ubuntu-22.04 -- wslpath -u "$startSh"
Write-Host "    wsl -d Ubuntu-22.04 -- bash '$wslStartPath'"
Write-Host ""
Write-Host "  Option B (background, stays running):" -ForegroundColor Cyan
Write-Host "    wsl -d Ubuntu-22.04 -- bash '$wslStartPath' --background"
Write-Host ""
Write-Host "  Endpoint will be at: http://localhost:8000/v1" -ForegroundColor Green
Write-Host "  (Your Mindcraft bots already point to host.docker.internal:8000)" -ForegroundColor Green
Write-Host ""

# Offer to start immediately
$response = Read-Host "Start vLLM now in background? [y/N]"
if ($response -match '^[Yy]') {
    Write-Host "Starting vLLM in background..." -ForegroundColor Yellow
    wsl -d Ubuntu-22.04 -- bash "$wslStartPath" --background
}
