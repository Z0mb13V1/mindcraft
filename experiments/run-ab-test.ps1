<#
.SYNOPSIS
    Automated A/B testing — run multiple experiments with different model configs and compare.
.DESCRIPTION
    Runs N trials of each variant (model/profile), auto-restoring the world between runs,
    collecting metrics, and producing a comparison table + CSV.

    Example: Compare andy-4 (local) vs gemini-2.5-flash (cloud) vs qwen2.5:32b (local)
    across 5 runs each, measuring coordination, survival, and cost.

    Flow per trial:
    1. Restore world to baseline snapshot
    2. Create experiment directory
    3. Start bots with the variant's profile
    4. Wait for duration
    5. Stop bots, collect logs
    6. Analyze metrics
    7. Repeat for next trial

    After all trials: aggregate results, compute means/stddev, output comparison.

.PARAMETER TestName
    Name for this A/B test (e.g., "andy4-vs-gemini-vs-qwen32b").
.PARAMETER Variants
    Array of hashtables defining each variant. Each must have:
    - Name: short label (e.g., "andy-4", "gemini-flash")
    - Mode: local, cloud, or both
    - Profile: profile filename (without path) to use
    Optional: Model (override model in profile for this run)
.PARAMETER TrialsPerVariant
    Number of runs per variant. Default: 3
.PARAMETER DurationMinutes
    Duration of each trial. Default: 15
.PARAMETER Goal
    Goal message injected into bots for each trial.
.PARAMETER BaselineBackup
    Path to a world backup to restore before each trial.
    If not set, takes a snapshot before the first trial and reuses it.
.PARAMETER SkipWorldRestore
    Don't restore world between runs (faster but less controlled).
.PARAMETER NoConfirm
    Skip the confirmation prompt before starting.
.EXAMPLE
    # Quick 2-variant test
    $variants = @(
        @{ Name = "andy-4-local";   Mode = "local"; Profile = "local-research.json" },
        @{ Name = "gemini-cloud";   Mode = "cloud"; Profile = "cloud-persistent.json" }
    )
    .\experiments\run-ab-test.ps1 -TestName "local-vs-cloud" -Variants $variants -TrialsPerVariant 3 -DurationMinutes 10 -Goal "Collect 32 wood logs"

    # Single-variant benchmark (5 runs for statistical significance)
    $variants = @(
        @{ Name = "ensemble-baseline"; Mode = "cloud"; Profile = "cloud-persistent.json" }
    )
    .\experiments\run-ab-test.ps1 -TestName "ensemble-5run" -Variants $variants -TrialsPerVariant 5 -DurationMinutes 20
#>
param(
    [Parameter(Mandatory)]
    [string]$TestName,

    [Parameter(Mandatory)]
    [hashtable[]]$Variants,

    [int]$TrialsPerVariant = 3,
    [int]$DurationMinutes = 15,
    [string]$Goal = "",
    [string]$BaselineBackup = "",
    [switch]$SkipWorldRestore,
    [switch]$NoConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Header { param([string]$m) Write-Host "" ; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Write-OK     { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info   { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }

function Send-DiscordWebhook {
    param([string]$Message)
    $webhook = $env:BACKUP_WEBHOOK_URL
    if (-not $webhook) { return }
    try {
        $body = @{ content = $Message } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri $webhook -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5 | Out-Null
    } catch { }
}

$projectRoot = (Resolve-Path "$PSScriptRoot\..").Path
$startScript = Join-Path $projectRoot "start.ps1"
$newExpScript = Join-Path $PSScriptRoot "new-experiment.ps1"
$startExpScript = Join-Path $PSScriptRoot "start-experiment.ps1"
$analyzeScript = Join-Path $PSScriptRoot "analyze.ps1"
$backupScript = Join-Path $PSScriptRoot "backup-world.ps1"
$restoreScript = Join-Path $PSScriptRoot "restore-world.ps1"

# ── Validate inputs ──────────────────────────────────────────────────────────

$date = Get-Date -Format "yyyy-MM-dd"
$testSlug = $TestName -replace '[^a-zA-Z0-9_-]', '-'
$testDir = Join-Path $PSScriptRoot "${date}_ab_${testSlug}"

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║         A/B Test: $($TestName.PadRight(35))║" -ForegroundColor Magenta
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

$totalTrials = $Variants.Count * $TrialsPerVariant
$totalMinutes = $totalTrials * ($DurationMinutes + 3)  # +3 for snapshot/restore overhead

Write-Host "  Variants:     $($Variants.Count)" -ForegroundColor White
foreach ($v in $Variants) {
    Write-Info "  - $($v.Name): mode=$($v.Mode), profile=$($v.Profile)"
}
Write-Host "  Trials each:  $TrialsPerVariant" -ForegroundColor White
Write-Host "  Duration:     $DurationMinutes min/trial" -ForegroundColor White
Write-Host "  Total trials: $totalTrials (~$totalMinutes min)" -ForegroundColor White
if ($Goal) { Write-Host "  Goal:         $Goal" -ForegroundColor White }
Write-Host "  Output:       $testDir" -ForegroundColor White
Write-Host ""

if (-not $NoConfirm) {
    $confirm = Read-Host "Start A/B test? This will take ~$totalMinutes minutes (y/N)"
    if ($confirm -notmatch '^[yY]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# ── Create test directory ────────────────────────────────────────────────────

New-Item -ItemType Directory -Path $testDir -Force | Out-Null

# Save test metadata
$testMeta = [ordered]@{
    test_name       = $TestName
    created_at      = (Get-Date -Format "o")
    variants        = $Variants
    trials_per_variant = $TrialsPerVariant
    duration_minutes = $DurationMinutes
    goal            = $Goal
    status          = "running"
}
$testMeta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $testDir "test-config.json") -Encoding UTF8

# ── Take baseline snapshot ──────────────────────────────────────────────────

if (-not $SkipWorldRestore) {
    if ($BaselineBackup -and (Test-Path $BaselineBackup)) {
        Write-OK "Using provided baseline: $BaselineBackup"
    } else {
        Write-Header "Taking Baseline World Snapshot"
        $BaselineBackup = Join-Path $testDir "baseline-world"
        & $backupScript -Target $BaselineBackup -SkipSaveControl
        Write-OK "Baseline saved to $BaselineBackup"
    }
}

Send-DiscordWebhook "🧪 **A/B Test Started**: $TestName — $totalTrials trials (~${totalMinutes}min)"

# ── Run trials ──────────────────────────────────────────────────────────────

$allResults = @()
$trialNum = 0

foreach ($variant in $Variants) {
    for ($trial = 1; $trial -le $TrialsPerVariant; $trial++) {
        $trialNum++
        $trialId = "$($variant.Name)_run$trial"
        $trialDir = Join-Path $testDir $trialId

        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "  │ Trial $trialNum/$totalTrials: $($trialId.PadRight(33))│" -ForegroundColor Yellow
        Write-Host "  └─────────────────────────────────────────────┘" -ForegroundColor Yellow

        $trialStart = Get-Date

        # 1. Restore world
        if (-not $SkipWorldRestore -and $BaselineBackup) {
            Write-Info "Restoring world to baseline..."
            # Stop any running bots first
            & $startScript stop 2>$null
            Start-Sleep -Seconds 3

            # Restore world (auto-confirms with pipeline input)
            $restoreTarget = Join-Path $projectRoot "minecraft-data"
            if (Test-Path $restoreTarget) {
                Remove-Item -Path "$restoreTarget\*" -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $BaselineBackup) {
                Get-ChildItem $BaselineBackup | Where-Object { $_.Name -ne "backup-manifest.json" } | ForEach-Object {
                    Copy-Item $_.FullName -Destination $restoreTarget -Recurse -Force
                }
                Write-OK "World restored"
            }
        }

        # 2. Create experiment dir structure
        New-Item -ItemType Directory -Path $trialDir -Force | Out-Null
        foreach ($sub in @("logs", "results")) {
            New-Item -ItemType Directory -Path (Join-Path $trialDir $sub) -Force | Out-Null
        }

        # Write trial metadata
        $trialMeta = [ordered]@{
            id              = $trialId
            name            = "$TestName — $($variant.Name) run $trial"
            variant         = $variant.Name
            mode            = $variant.Mode
            duration_minutes = $DurationMinutes
            profiles        = @($variant.Profile)
            goal            = $Goal
            status          = "running"
            started_at      = (Get-Date -Format "o")
        }
        $trialMeta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $trialDir "metadata.json") -Encoding UTF8

        # 3. Set profiles and launch
        $profilePath = "./profiles/$($variant.Profile)"
        $env:PROFILES = "[$([char]34)$profilePath$([char]34)]"
        $settingsObj = @{
            auto_open_ui           = $false
            mindserver_host_public = $true
            host                   = "minecraft-server"
        }
        if ($Goal) { $settingsObj.init_message = $Goal }
        $env:SETTINGS_JSON = $settingsObj | ConvertTo-Json -Compress

        Write-Info "Launching: mode=$($variant.Mode), profile=$($variant.Profile)"
        $composeArgs = @("compose")
        if ($variant.Mode -in @("local", "both")) { $composeArgs += "--profile", "local" }
        if ($variant.Mode -in @("cloud", "both")) { $composeArgs += "--profile", "cloud" }
        $composeArgs += "up", "-d"
        & docker @composeArgs 2>&1 | Out-Null

        # 4. Wait for healthy
        Write-Info "Waiting for services to be healthy..."
        $healthWait = 0
        while ($healthWait -lt 120) {
            Start-Sleep -Seconds 10
            $healthWait += 10
            $mcStatus = & docker inspect --format '{{.State.Health.Status}}' minecraft-server 2>$null
            if ($mcStatus -eq "healthy") { break }
        }

        # 5. Wait for experiment duration
        Write-Info "Running for $DurationMinutes minutes..."
        $endTime = (Get-Date).AddMinutes($DurationMinutes)
        while ((Get-Date) -lt $endTime) {
            $remaining = [Math]::Round(($endTime - (Get-Date)).TotalMinutes, 1)
            Write-Host "`r    $remaining min remaining...    " -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 30
        }
        Write-Host ""

        # 6. Stop bots
        Write-Info "Stopping bots..."
        & docker compose stop mindcraft 2>$null
        Start-Sleep -Seconds 2
        & docker compose down 2>$null

        # 7. Collect logs
        Write-Info "Collecting logs..."
        $botsDir = Join-Path $projectRoot "bots"
        $logsTarget = Join-Path $trialDir "logs"
        if (Test-Path $botsDir) {
            Get-ChildItem $botsDir -Filter "ensemble_log.json" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $botName = $_.Directory.Name
                Copy-Item $_.FullName (Join-Path $logsTarget "${botName}_ensemble_log.json") -Force
            }
            Get-ChildItem $botsDir -Filter "usage.json" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $botName = $_.Directory.Name
                Copy-Item $_.FullName (Join-Path $logsTarget "${botName}_usage.json") -Force
            }
            Get-ChildItem $botsDir -Recurse -Include "*.log", "*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Substring($botsDir.Length + 1)
                $dest = Join-Path $logsTarget ($rel -replace '[\\/:*?"<>|]', '_')
                Copy-Item $_.FullName $dest -Force
            }
        }

        # 8. Analyze
        Write-Info "Analyzing trial..."
        & $analyzeScript -ExperimentDir $trialDir 2>&1 | Out-Null

        # 9. Load results for aggregation
        $summaryPath = Join-Path $trialDir "results" "summary.json"
        $trialResult = [ordered]@{
            trial_id = $trialId
            variant  = $variant.Name
            trial    = $trial
        }
        if (Test-Path $summaryPath) {
            try {
                $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
                # Extract key metrics from the first bot found
                $botNames = @()
                if ($summary.research_scores) {
                    $summary.research_scores.PSObject.Properties | ForEach-Object { $botNames += $_.Name }
                }
                if ($botNames.Count -gt 0) {
                    $firstBot = $botNames[0]
                    $rs = $summary.research_scores.$firstBot
                    if ($rs) {
                        $trialResult.commands_per_minute = $rs.commands_per_minute
                        $trialResult.error_rate_pct      = $rs.error_rate_pct
                        $trialResult.command_diversity    = $rs.command_diversity
                        $trialResult.coordination_score   = $rs.coordination_score
                        $trialResult.survival_score       = $rs.survival_score
                        $trialResult.deaths               = $rs.deaths
                    }
                    $ens = $summary.ensemble.$firstBot
                    if ($ens) {
                        $trialResult.avg_latency_ms  = $ens.avg_latency_ms
                        $trialResult.agreement_pct   = $ens.avg_agreement_pct
                    }
                }
                if ($summary.grand_totals) {
                    $trialResult.total_tokens  = $summary.grand_totals.total_tokens
                    $trialResult.total_calls   = $summary.grand_totals.total_calls
                    $trialResult.cost_usd      = $summary.grand_totals.estimated_cost
                }
            } catch {
                Write-Warn "Could not parse results for $trialId"
            }
        }
        $allResults += $trialResult

        $trialElapsed = [Math]::Round(((Get-Date) - $trialStart).TotalMinutes, 1)

        # Update trial metadata
        $trialMeta.status = "completed"
        $trialMeta.completed_at = (Get-Date -Format "o")
        $trialMeta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $trialDir "metadata.json") -Encoding UTF8

        Write-OK "Trial $trialId complete ($trialElapsed min)"
        Send-DiscordWebhook "✅ **Trial $trialNum/$totalTrials**: $trialId complete (${trialElapsed}min)"
    }
}

# ── Aggregate results ────────────────────────────────────────────────────────

Write-Header "Aggregating Results"

# Group by variant, compute mean and stddev
$metrics = @("commands_per_minute", "error_rate_pct", "command_diversity", "coordination_score",
             "survival_score", "deaths", "avg_latency_ms", "agreement_pct", "total_tokens",
             "total_calls", "cost_usd")

$comparison = @()
foreach ($variant in $Variants) {
    $variantResults = $allResults | Where-Object { $_.variant -eq $variant.Name }
    $agg = [ordered]@{ variant = $variant.Name; trials = $variantResults.Count }

    foreach ($metric in $metrics) {
        $values = @($variantResults | ForEach-Object { $_.$metric } | Where-Object { $_ -ne $null -and $_ -ne "N/A (local)" })
        if ($values.Count -gt 0) {
            $mean = [Math]::Round(($values | Measure-Object -Average).Average, 2)
            $agg["${metric}_mean"] = $mean
            if ($values.Count -gt 1) {
                $sumSqDiff = ($values | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum
                $stddev = [Math]::Round([Math]::Sqrt($sumSqDiff / ($values.Count - 1)), 2)
                $agg["${metric}_stddev"] = $stddev
            }
        }
    }
    $comparison += $agg
}

# ── Print comparison table ───────────────────────────────────────────────────

$divider = "=" * 72

Write-Host ""
Write-Host $divider -ForegroundColor DarkGray
Write-Host "  A/B TEST RESULTS: $TestName" -ForegroundColor White
Write-Host $divider -ForegroundColor DarkGray

# Header
$headerFmt = "  {0,-20} " -f "Metric"
foreach ($v in $Variants) { $headerFmt += "{0,-22} " -f $v.Name }
Write-Host $headerFmt -ForegroundColor Cyan
Write-Host "  $("-" * 66)" -ForegroundColor DarkGray

# Rows
$displayMetrics = @(
    @{ Key = "commands_per_minute"; Label = "Commands/min";    Better = "higher" },
    @{ Key = "error_rate_pct";     Label = "Error rate (%)";   Better = "lower" },
    @{ Key = "command_diversity";   Label = "Cmd diversity (%)"; Better = "higher" },
    @{ Key = "coordination_score"; Label = "Coordination (%)"; Better = "higher" },
    @{ Key = "survival_score";     Label = "Survival (/100)";  Better = "higher" },
    @{ Key = "deaths";             Label = "Deaths";           Better = "lower" },
    @{ Key = "avg_latency_ms";     Label = "Latency (ms)";    Better = "lower" },
    @{ Key = "agreement_pct";      Label = "Agreement (%)";   Better = "higher" },
    @{ Key = "total_tokens";       Label = "Total tokens";    Better = "neutral" },
    @{ Key = "cost_usd";           Label = "Cost (USD)";      Better = "lower" }
)

foreach ($dm in $displayMetrics) {
    $rowFmt = "  {0,-20} " -f $dm.Label
    $values = @()
    foreach ($v in $Variants) {
        $agg = $comparison | Where-Object { $_.variant -eq $v.Name }
        $meanKey = "$($dm.Key)_mean"
        $sdKey = "$($dm.Key)_stddev"
        $mean = $agg.$meanKey
        $sd = $agg.$sdKey
        if ($null -ne $mean) {
            $cell = "$mean"
            if ($null -ne $sd) { $cell += " +/-$sd" }
            $values += $mean
        } else {
            $cell = "N/A"
            $values += $null
        }
        $rowFmt += "{0,-22} " -f $cell
    }

    # Highlight the winner
    $color = "White"
    $validValues = $values | Where-Object { $_ -ne $null }
    if ($validValues.Count -gt 1) {
        if ($dm.Better -eq "higher") { $color = "Green" }
        elseif ($dm.Better -eq "lower") { $color = "Green" }
    }
    Write-Host $rowFmt -ForegroundColor $color
}

Write-Host $divider -ForegroundColor DarkGray

# ── Export CSV ───────────────────────────────────────────────────────────────

$csvPath = Join-Path $testDir "results.csv"
$allResults | ForEach-Object { [PSCustomObject]$_ } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-OK "Raw trial data: $csvPath"

$comparisonCsvPath = Join-Path $testDir "comparison.csv"
$comparison | ForEach-Object { [PSCustomObject]$_ } | Export-Csv -Path $comparisonCsvPath -NoTypeInformation -Encoding UTF8
Write-OK "Comparison summary: $comparisonCsvPath"

# Save full results JSON
$fullResults = [ordered]@{
    test_name        = $TestName
    completed_at     = (Get-Date -Format "o")
    variants         = $Variants
    trials_per_variant = $TrialsPerVariant
    duration_minutes = $DurationMinutes
    goal             = $Goal
    all_trials       = $allResults
    comparison       = $comparison
}
$fullResults | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $testDir "full-results.json") -Encoding UTF8

# Update test metadata
$testMeta.status = "completed"
$testMeta.completed_at = (Get-Date -Format "o")
$testMeta | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $testDir "test-config.json") -Encoding UTF8

$totalElapsed = [Math]::Round(((Get-Date) - (Get-Date $testMeta.created_at)).TotalMinutes, 1)

Write-Host ""
Write-Host "  A/B test complete: $totalTrials trials in ~$totalElapsed min" -ForegroundColor Green
Write-Host "  Results: $testDir" -ForegroundColor Green
Write-Host ""

Send-DiscordWebhook "🏁 **A/B Test Complete**: $TestName — $totalTrials trials in ${totalElapsed}min. Results: $testDir"
