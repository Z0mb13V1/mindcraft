<#
.SYNOPSIS
    Restore a Minecraft world from a backup snapshot.
.DESCRIPTION
    Stops the Minecraft container, replaces minecraft-data/ contents with the
    backup, then restarts the container. Use this to reset a world to a known
    state before running a reproducible experiment.
.PARAMETER BackupDir
    Path to the backup directory (created by backup-world.ps1).
.PARAMETER Target
    Destination to restore to. Default: .\minecraft-data (project root).
.PARAMETER NoRestart
    Don't automatically restart the minecraft container after restore.
.EXAMPLE
    .\experiments\restore-world.ps1 -BackupDir .\experiments\2026-02-25_test\world-before
    .\experiments\restore-world.ps1 -BackupDir .\experiments\2026-02-25_test\world-before -NoRestart
#>
param(
    [Parameter(Mandatory)]
    [string]$BackupDir,
    [string]$Target = "",
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve target relative to project root
if (-not $Target) {
    $projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $Target = Join-Path $projectRoot "minecraft-data"
}

if (-not (Test-Path $BackupDir)) {
    Write-Error "Backup directory not found: $BackupDir"
    exit 1
}

Write-Host ""
Write-Host "=== Restore World ===" -ForegroundColor Cyan
Write-Host "  Backup: $BackupDir" -ForegroundColor DarkGray
Write-Host "  Target: $Target" -ForegroundColor DarkGray
Write-Host ""

# ── Confirmation ───────────────────────────────────────────────────────────────

$confirm = Read-Host "This will OVERWRITE '$Target'. Continue? (y/N)"
if ($confirm -notmatch '^[yY]') {
    Write-Host "Aborted." -ForegroundColor Yellow
    exit 0
}

# ── Stop Minecraft container ──────────────────────────────────────────────────

Write-Host "[1/3] Stopping Minecraft container..." -ForegroundColor Cyan
& docker compose stop minecraft
if ($LASTEXITCODE -ne 0) {
    Write-Warning "docker compose stop returned non-zero. Continuing anyway."
}
Start-Sleep -Seconds 2

# ── Replace world data ────────────────────────────────────────────────────────

Write-Host "[2/3] Replacing world data..." -ForegroundColor Cyan

if (Test-Path $Target) {
    Remove-Item -Path "$Target\*" -Recurse -Force
    Write-Host "  Cleared: $Target" -ForegroundColor DarkGray
} else {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}

# Copy backup (excluding the manifest file)
Get-ChildItem $BackupDir | Where-Object { $_.Name -ne "backup-manifest.json" } | ForEach-Object {
    Copy-Item $_.FullName -Destination $Target -Recurse -Force
}

$restoredMB = [Math]::Round((Get-ChildItem $Target -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host "  Restored: $restoredMB MB" -ForegroundColor DarkGray

# ── Restart Minecraft container ───────────────────────────────────────────────

if (-not $NoRestart) {
    Write-Host "[3/3] Restarting Minecraft container..." -ForegroundColor Cyan
    & docker compose start minecraft
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "World restored and server restarted." -ForegroundColor Green
    } else {
        Write-Warning "Failed to restart Minecraft. Run: docker compose start minecraft"
    }
} else {
    Write-Host "[3/3] Skipping restart (-NoRestart). Run: docker compose start minecraft" -ForegroundColor DarkGray
}

Write-Host ""
