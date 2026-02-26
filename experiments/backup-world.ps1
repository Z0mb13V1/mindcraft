<#
.SYNOPSIS
    Backup (snapshot) the local Minecraft world data.
.DESCRIPTION
    Pauses server auto-saves, copies minecraft-data/ to the target directory,
    then re-enables auto-saves. Safe to run while the server is running.
.PARAMETER Target
    Destination directory for the world backup.
.PARAMETER Source
    Source directory to back up. Default: .\minecraft-data (relative to project root).
.PARAMETER SkipSaveControl
    Skip the save-off/save-on commands (use if RCON isn't available or server is stopped).
.EXAMPLE
    .\experiments\backup-world.ps1 -Target .\experiments\2026-02-25_test\world-before
    .\experiments\backup-world.ps1 -Target C:\Backups\world -SkipSaveControl
#>
param(
    [Parameter(Mandatory)]
    [string]$Target,
    [string]$Source = "",
    [switch]$SkipSaveControl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# Resolve source relative to project root (parent of experiments/)
if (-not $Source) {
    $projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $Source = Join-Path $projectRoot "minecraft-data"
}

if (-not (Test-Path $Source)) {
    Write-Warning "Source not found: $Source — nothing to back up."
    exit 0
}

# ── Pause server auto-saves ───────────────────────────────────────────────────

if (-not $SkipSaveControl) {
    try {
        Write-Host "  Pausing world saves..." -ForegroundColor DarkGray
        & docker exec minecraft-server rcon-cli save-off 2>&1 | Out-Null
        & docker exec minecraft-server rcon-cli save-all 2>&1 | Out-Null
        Start-Sleep -Seconds 2   # let the save flush
    } catch {
        Write-Warning "Could not pause server saves (server may not be running). Continuing anyway."
        $SkipSaveControl = $true
    }
}

# ── Create target directory and copy ─────────────────────────────────────────

New-Item -ItemType Directory -Path $Target -Force | Out-Null

Write-Host "  Copying world data..." -ForegroundColor DarkGray
$sourceSize = (Get-ChildItem $Source -Recurse -File | Measure-Object -Property Length -Sum).Sum
$sourceMB   = [Math]::Round($sourceSize / 1MB, 1)
Write-Host "    Source: $Source ($sourceMB MB)" -ForegroundColor DarkGray
Write-Host "    Target: $Target" -ForegroundColor DarkGray

Copy-Item -Path "$Source\*" -Destination $Target -Recurse -Force

# ── Resume server auto-saves ──────────────────────────────────────────────────

if (-not $SkipSaveControl) {
    try {
        & docker exec minecraft-server rcon-cli save-on 2>&1 | Out-Null
        Write-Host "  World saves resumed." -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not resume server saves. Run 'save-on' manually in the server console."
    }
}

# ── Write manifest ────────────────────────────────────────────────────────────

$manifest = @{
    source      = $Source
    target      = $Target
    timestamp   = (Get-Date -Format "o")
    size_bytes  = $sourceSize
}
$manifest | ConvertTo-Json | Set-Content -Path (Join-Path $Target "backup-manifest.json") -Encoding UTF8

Write-Host "  Backup complete: $sourceMB MB → $Target" -ForegroundColor Green
