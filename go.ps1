<#
.SYNOPSIS
    One-command wrapper: pull, launch, optionally start an experiment.
.DESCRIPTION
    1. cd to repo
    2. git pull (SSH)
    3. Run full-rig-launch.ps1 -NoLogs (all 8 checks + launch + wait + status)
    4. Ask if user wants a quick experiment
    5. Tail logs until Ctrl+C
.PARAMETER SkipPull
    Skip git pull (useful offline or when already up to date).
.PARAMETER Build
    Pass -Build through to full-rig-launch.ps1 to force Docker image rebuild.
.PARAMETER SkipNameUpdate
    Pass -SkipNameUpdate through to full-rig-launch.ps1.
.EXAMPLE
    .\go.ps1
    .\go.ps1 -SkipPull
    .\go.ps1 -Build
#>
param(
    [switch]$SkipPull,
    [switch]$Build,
    [switch]$SkipNameUpdate
)

$ErrorActionPreference = 'Continue'

$RepoPath = 'C:\Users\Tyler\Desktop\AI\minecraft ai bot\Mindcraft\mindcraft-0.1.3'

# ── Navigate to repo ──────────────────────────────────────────────────────────

if (-not (Test-Path $RepoPath)) {
    Write-Host ('  [FAIL] Repo not found: ' + $RepoPath) -ForegroundColor Red
    exit 1
}
Set-Location $RepoPath

# ── Git pull ──────────────────────────────────────────────────────────────────

if (-not $SkipPull) {
    Write-Host ''
    Write-Host '=== Git Pull ===' -ForegroundColor Cyan
    & git pull origin main 2>&1 | ForEach-Object { Write-Host ('  ' + $_) -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [WARN] git pull failed -- continuing with local files' -ForegroundColor Yellow
    }
}

# ── Run full-rig-launch.ps1 (the master launcher) ────────────────────────────

$launcher = Join-Path $RepoPath 'full-rig-launch.ps1'

if (Test-Path $launcher) {
    Write-Host ''
    Write-Host '=== Running full-rig-launch.ps1 ===' -ForegroundColor Cyan
    Write-Host ''

    # Build argument list for the launcher
    # -NoLogs: we handle log tailing ourselves after the experiment prompt
    $launchArgs = @('-NoLogs')
    if ($Build)          { $launchArgs += '-Build' }
    if ($SkipNameUpdate) { $launchArgs += '-SkipNameUpdate' }

    & $launcher @launchArgs
    $launchExit = $LASTEXITCODE

    if ($launchExit -ne 0) {
        Write-Host ''
        Write-Host ('  [FAIL] full-rig-launch.ps1 exited with code ' + $launchExit) -ForegroundColor Red
        Write-Host '  Fix the issues above and rerun: .\go.ps1' -ForegroundColor Yellow
        exit $launchExit
    }
} else {
    # Fallback: full-rig-launch.ps1 not found -- direct docker compose
    Write-Host ''
    Write-Host '  [WARN] full-rig-launch.ps1 not found -- using direct docker compose' -ForegroundColor Yellow

    # Load .env for API keys
    if (Test-Path '.env') {
        Get-Content '.env' | ForEach-Object {
            if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)\s*$') {
                $k = $Matches[1].Trim()
                $v = $Matches[2].Trim().Trim('"').Trim("'")
                if ($v -and -not [System.Environment]::GetEnvironmentVariable($k)) {
                    [System.Environment]::SetEnvironmentVariable($k, $v, 'Process')
                }
            }
        }
    }

    $env:PROFILES = '["./profiles/local-research.json","./profiles/cloud-persistent.json"]'
    & docker compose --profile local --profile cloud up -d --force-recreate

    if ($LASTEXITCODE -ne 0) {
        Write-Host '  [FAIL] docker compose failed' -ForegroundColor Red
        Write-Host '  Check: docker compose logs --tail 50' -ForegroundColor Yellow
        exit 1
    }

    Write-Host '  Waiting 60s for startup...' -ForegroundColor DarkGray
    Start-Sleep -Seconds 60
    & docker compose ps
}

# ── Connection info (always show, even if launcher already printed it) ────────

Write-Host ''
Write-Host '  +--------------------------------------------------+' -ForegroundColor Green
Write-Host '  |  Rig is live. Connect now:                       |' -ForegroundColor Green
Write-Host '  |    Minecraft : localhost:25565                   |' -ForegroundColor Green
Write-Host '  |    UI        : http://localhost:8080/            |' -ForegroundColor Green
Write-Host '  |    Camera    : http://localhost:3000/            |' -ForegroundColor Green
Write-Host '  +--------------------------------------------------+' -ForegroundColor Green
Write-Host ''

# ── Optional: quick experiment ────────────────────────────────────────────────

$expScript = Join-Path $RepoPath 'experiments\new-experiment.ps1'

if (Test-Path $expScript) {
    $answer = Read-Host '  Run a test experiment? (y/n)'
    if ($answer -eq 'y' -or $answer -eq 'Y') {
        $expName = Read-Host '  Experiment name (slug, e.g. wood-collection)'
        if (-not $expName) { $expName = 'quick-test' }

        $expDuration = Read-Host '  Duration in minutes (default 30)'
        if (-not $expDuration) { $expDuration = '30' }

        $expDesc = Read-Host '  Description (optional, press Enter to skip)'
        if (-not $expDesc) { $expDesc = 'Quick test run' }

        Write-Host ''
        Write-Host ('  Creating experiment: ' + $expName + ' (' + $expDuration + ' min)') -ForegroundColor Cyan

        $expArgs = @(
            '-Name', $expName,
            '-DurationMinutes', $expDuration,
            '-Description', $expDesc,
            '-Mode', 'both'
        )
        & $expScript @expArgs

        if ($LASTEXITCODE -eq 0) {
            Write-Host '  Experiment directory created. See output above for next steps.' -ForegroundColor Green
        } else {
            Write-Host '  [WARN] Experiment creation had issues -- check output above' -ForegroundColor Yellow
        }
        Write-Host ''
    }
}

# ── Tail logs until Ctrl+C ───────────────────────────────────────────────────

Write-Host '  Streaming bot logs (Ctrl+C to stop)...' -ForegroundColor Cyan
Write-Host '  -------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

& docker compose logs -f mindcraft
