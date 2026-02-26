<#
.SYNOPSIS
    Create a new experiment directory with metadata.
.DESCRIPTION
    Sets up a structured experiment folder containing metadata, placeholder
    directories for world snapshots, logs, and results.
.PARAMETER Name
    Short slug for the experiment (e.g., "wood-collection-baseline").
    Used as part of the directory name.
.PARAMETER Description
    Human-readable description of what this experiment tests.
.PARAMETER Mode
    Which bot mode to use: local, cloud, or both. Default: both
.PARAMETER DurationMinutes
    Planned experiment duration in minutes. Default: 30
.EXAMPLE
    .\experiments\new-experiment.ps1 -Name "wood-collection" -Description "Measure wood collection rate" -Mode both
    .\experiments\new-experiment.ps1 -Name "solo-local" -Mode local -DurationMinutes 60
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,
    [string]$Description = "",
    [ValidateSet("local", "cloud", "both")]
    [string]$Mode = "both",
    [int]$DurationMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Build experiment directory path ──────────────────────────────────────────

$date     = Get-Date -Format "yyyy-MM-dd"
$slug     = $Name -replace '[^a-zA-Z0-9_-]', '-'   # sanitize
$dirName  = "${date}_${slug}"
$expRoot  = Join-Path $PSScriptRoot $dirName         # experiments/<date>_<slug>/

if (Test-Path $expRoot) {
    Write-Error "Experiment directory already exists: $expRoot"
    exit 1
}

# ── Create directory structure ────────────────────────────────────────────────

$dirs = @(
    $expRoot,
    (Join-Path $expRoot "world-before"),   # world snapshot before experiment
    (Join-Path $expRoot "world-after"),    # world snapshot after experiment
    (Join-Path $expRoot "logs"),           # bot logs, ensemble logs, usage stats
    (Join-Path $expRoot "results")         # analyzed output from analyze.ps1
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Path $d | Out-Null }

# ── Determine profiles based on mode ─────────────────────────────────────────

$profiles = switch ($Mode) {
    "local" { @("local-research.json") }
    "cloud" { @("cloud-persistent.json") }
    "both"  { @("local-research.json", "cloud-persistent.json") }
}

# ── Write metadata.json ───────────────────────────────────────────────────────

$metadata = [ordered]@{
    id                 = $dirName
    name               = $Name
    description        = $Description
    mode               = $Mode
    duration_minutes   = $DurationMinutes
    created_at         = (Get-Date -Format "o")   # ISO 8601
    started_at         = $null
    completed_at       = $null
    status             = "created"
    profiles           = $profiles
    minecraft_version  = "1.21.6"
    local_model        = "sweaterdog/andy-4"
    cloud_models       = @("gemini-2.5-pro", "gemini-2.5-flash", "grok-4-1-fast-non-reasoning", "grok-code-fast-1")
    notes              = ""
}

$metaPath = Join-Path $expRoot "metadata.json"
$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path $metaPath -Encoding UTF8

# ── Done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Experiment created: $dirName" -ForegroundColor Green
Write-Host ""
Write-Host "  Directory: $expRoot" -ForegroundColor DarkGray
Write-Host "  Mode:      $Mode  ($DurationMinutes min)" -ForegroundColor DarkGray
Write-Host "  Profiles:  $($profiles -join ', ')" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  .\experiments\start-experiment.ps1 -ExperimentDir '$expRoot' -Goal 'Collect 64 wood logs'" -ForegroundColor DarkGray
Write-Host ""
