<#
.SYNOPSIS
    Start an experiment run (snapshot world, launch bots, collect logs, snapshot again).
.DESCRIPTION
    1. Reads metadata.json from the experiment directory
    2. Snapshots the world (world-before/)
    3. Sets the init_message goal on the bots via SETTINGS_JSON
    4. Launches bots via start.ps1 in detached mode
    5. Waits for the experiment duration
    6. Stops the bots
    7. Collects logs into experiments/<id>/logs/
    8. Snapshots the world again (world-after/)
    9. Updates metadata.json status to "completed"
.PARAMETER ExperimentDir
    Path to the experiment directory (created by new-experiment.ps1).
.PARAMETER Goal
    Goal message injected as init_message into bot settings.
    If not set, bots start with their default behavior.
.PARAMETER NoWorldSnapshot
    Skip world snapshots (faster, but no before/after comparison).
.PARAMETER NoBotTimer
    Don't auto-stop bots after duration — you control when to stop.
.EXAMPLE
    .\experiments\start-experiment.ps1 -ExperimentDir .\experiments\2026-02-25_wood-collection -Goal "Collect as much wood as possible"
    .\experiments\start-experiment.ps1 -ExperimentDir .\experiments\2026-02-25_test -NoWorldSnapshot -NoBotTimer
#>
param(
    [Parameter(Mandatory)]
    [string]$ExperimentDir,
    [string]$Goal = "",
    [switch]$NoWorldSnapshot,
    [switch]$NoBotTimer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Load metadata ─────────────────────────────────────────────────────────────

$metaPath = Join-Path $ExperimentDir "metadata.json"
if (-not (Test-Path $metaPath)) {
    Write-Error "metadata.json not found in: $ExperimentDir"
    exit 1
}
$meta = Get-Content $metaPath -Raw | ConvertFrom-Json

if ($meta.status -eq "completed") {
    Write-Warning "This experiment is already completed. Create a new one to run again."
    exit 1
}

Write-Host ""
Write-Host "=== Starting Experiment: $($meta.id) ===" -ForegroundColor Cyan
Write-Host "  Mode:     $($meta.mode)" -ForegroundColor DarkGray
Write-Host "  Duration: $($meta.duration_minutes) minutes" -ForegroundColor DarkGray
if ($Goal) { Write-Host "  Goal:     $Goal" -ForegroundColor DarkGray }
Write-Host ""

# ── Resolve paths ─────────────────────────────────────────────────────────────

$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$startScript = Join-Path $projectRoot "start.ps1"
$backupScript = Join-Path $PSScriptRoot "backup-world.ps1"

# ── Step 1: World snapshot (before) ──────────────────────────────────────────

if (-not $NoWorldSnapshot) {
    Write-Host "[1/5] Snapshotting world (before)..." -ForegroundColor Cyan
    $worldBefore = Join-Path $ExperimentDir "world-before"
    & $backupScript -Target $worldBefore
} else {
    Write-Host "[1/5] Skipping world snapshot (-NoWorldSnapshot)." -ForegroundColor DarkGray
}

# ── Step 2: Update metadata status ───────────────────────────────────────────

Write-Host "[2/5] Updating metadata..." -ForegroundColor Cyan
$meta.status     = "running"
$meta.started_at = (Get-Date -Format "o")
if ($Goal) { $meta | Add-Member -NotePropertyName "goal" -NotePropertyValue $Goal -Force }
$meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaPath -Encoding UTF8

# ── Step 3: Launch bots ───────────────────────────────────────────────────────

Write-Host "[3/5] Launching bots..." -ForegroundColor Cyan

# Build SETTINGS_JSON — inject goal as init_message if provided
$settingsObj = @{
    auto_open_ui           = $false
    mindserver_host_public = $true
    host                   = "minecraft-server"
}
if ($Goal) {
    $settingsObj.init_message = $Goal
}
$env:SETTINGS_JSON = $settingsObj | ConvertTo-Json -Compress

# Build PROFILES from metadata
$profilePaths = $meta.profiles | ForEach-Object { "./profiles/$_" }
$env:PROFILES = $profilePaths | ConvertTo-Json -Compress

# Use start.ps1 in detach mode
& $startScript $meta.mode -Detach -NoOllama:($meta.mode -eq "cloud")

Write-Host ""
Write-Host "  Bots running. Experiment ends in $($meta.duration_minutes) minutes." -ForegroundColor Green

# ── Step 4: Wait or skip timer ───────────────────────────────────────────────

if (-not $NoBotTimer) {
    Write-Host "[4/5] Waiting $($meta.duration_minutes) minutes..." -ForegroundColor Cyan
    $endTime = (Get-Date).AddMinutes($meta.duration_minutes)

    while ((Get-Date) -lt $endTime) {
        $remaining = [Math]::Round(($endTime - (Get-Date)).TotalMinutes, 1)
        Write-Host "      $remaining minutes remaining..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 60
    }

    Write-Host "      Timer done. Stopping bots..." -ForegroundColor Yellow
    & $startScript stop
} else {
    Write-Host "[4/5] Timer disabled (-NoBotTimer). Stop bots manually: .\start.ps1 stop" -ForegroundColor Yellow
    Write-Host "      Then run: .\experiments\start-experiment.ps1 (won't re-launch if status=running)" -ForegroundColor DarkGray
    Write-Host "      Manually proceed to log collection when done." -ForegroundColor DarkGray
    exit 0
}

# ── Step 5: Collect logs ──────────────────────────────────────────────────────

Write-Host "[5/5] Collecting logs..." -ForegroundColor Cyan

$logsTarget = Join-Path $ExperimentDir "logs"
$botsDir    = Join-Path $projectRoot "bots"

if (Test-Path $botsDir) {
    # Copy ensemble decision logs
    Get-ChildItem $botsDir -Filter "ensemble_log.json" -Recurse | ForEach-Object {
        $botName = $_.Directory.Name
        $dest = Join-Path $logsTarget "${botName}_ensemble_log.json"
        Copy-Item $_.FullName $dest -Force
        Write-Host "    Copied: $($_.Name) → $dest" -ForegroundColor DarkGray
    }

    # Copy usage/cost logs
    Get-ChildItem $botsDir -Filter "usage.json" -Recurse | ForEach-Object {
        $botName = $_.Directory.Name
        $dest = Join-Path $logsTarget "${botName}_usage.json"
        Copy-Item $_.FullName $dest -Force
        Write-Host "    Copied: $($_.Name) → $dest" -ForegroundColor DarkGray
    }

    # Copy conversation/action logs
    Get-ChildItem $botsDir -Recurse -Include "*.log", "*.txt" | ForEach-Object {
        $rel = $_.FullName.Substring($botsDir.Length + 1)
        $dest = Join-Path $logsTarget ($rel -replace '[\\/:*?"<>|]', '_')
        Copy-Item $_.FullName $dest -Force
    }
} else {
    Write-Warning "bots/ directory not found at $botsDir — no logs to collect."
}

# ── World snapshot (after) ────────────────────────────────────────────────────

if (-not $NoWorldSnapshot) {
    Write-Host "     Snapshotting world (after)..." -ForegroundColor Cyan
    $worldAfter = Join-Path $ExperimentDir "world-after"
    & $backupScript -Target $worldAfter
}

# ── Update metadata ───────────────────────────────────────────────────────────

$meta.status       = "completed"
$meta.completed_at = (Get-Date -Format "o")
$meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaPath -Encoding UTF8

Write-Host ""
Write-Host "Experiment complete: $($meta.id)" -ForegroundColor Green
Write-Host ""
Write-Host "  Next step: .\experiments\analyze.ps1 -ExperimentDir '$ExperimentDir'" -ForegroundColor DarkGray
Write-Host ""
