<#
.SYNOPSIS
    Analyze experiment results from logs and usage data.
.DESCRIPTION
    Parses ensemble_log.json, usage.json, and conversation logs collected in the
    experiment's logs/ directory. Writes a summary table to the console and
    results/summary.json + results/summary.txt to the experiment directory.
.PARAMETER ExperimentDir
    Path to a completed experiment directory.
.PARAMETER Open
    Open results/summary.txt in Notepad after analysis.
.EXAMPLE
    .\experiments\analyze.ps1 -ExperimentDir .\experiments\2026-02-25_wood-collection
    .\experiments\analyze.ps1 -ExperimentDir .\experiments\2026-02-25_wood-collection -Open
#>
param(
    [Parameter(Mandatory)]
    [string]$ExperimentDir,
    [switch]$Open
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

$logsDir    = Join-Path $ExperimentDir "logs"
$resultsDir = Join-Path $ExperimentDir "results"
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

Write-Host ""
Write-Host "=== Analyzing: $($meta.id) ===" -ForegroundColor Cyan
Write-Host ""

# ── Helpers ────────────────────────────────────────────────────────────────────

function Get-JsonFile { param([string]$path) if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { $null } }

# ── Parse ensemble logs ───────────────────────────────────────────────────────

$ensembleSummaries = @{}

Get-ChildItem $logsDir -Filter "*ensemble_log.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $botName  = ($_.Name -replace "_ensemble_log.json", "")
    $entries  = Get-JsonFile $_.FullName
    if (-not $entries) { return }

    # Handle both array-of-entries and object-with-entries-array
    if ($entries -is [array]) { $log = $entries } else { $log = @($entries) }

    $totalDecisions = $log.Count
    $winCounts      = @{}
    $latencies      = @()
    $agreementVals  = @()
    $judgeOverrides = 0

    foreach ($entry in $log) {
        # Count model wins
        if ($entry.winner_id) {
            if (-not $winCounts.ContainsKey($entry.winner_id)) { $winCounts[$entry.winner_id] = 0 }
            $winCounts[$entry.winner_id]++
        }
        # Average latency
        if ($entry.winner_latency_ms) { $latencies += $entry.winner_latency_ms }
        # Agreement
        if ($entry.panel_agreement) { $agreementVals += $entry.panel_agreement }
        # Judge overrides
        if ($entry.judge_override -eq $true) { $judgeOverrides++ }
    }

    $avgLatency   = if ($latencies.Count -gt 0)    { [Math]::Round(($latencies | Measure-Object -Average).Average) } else { 0 }
    $avgAgreement = if ($agreementVals.Count -gt 0) { [Math]::Round(($agreementVals | Measure-Object -Average).Average * 100, 1) } else { 0 }

    $winRates = @{}
    foreach ($k in $winCounts.Keys) {
        $winRates[$k] = [Math]::Round($winCounts[$k] / [Math]::Max(1, $totalDecisions) * 100, 1)
    }

    $ensembleSummaries[$botName] = @{
        bot_name          = $botName
        total_decisions   = $totalDecisions
        avg_latency_ms    = $avgLatency
        avg_agreement_pct = $avgAgreement
        judge_overrides   = $judgeOverrides
        judge_override_pct = [Math]::Round($judgeOverrides / [Math]::Max(1, $totalDecisions) * 100, 1)
        win_rates         = $winRates
    }
}

# ── Parse usage logs ──────────────────────────────────────────────────────────

$usageSummaries = @{}

Get-ChildItem $logsDir -Filter "*usage.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $botName = ($_.Name -replace "_usage.json", "")
    $usage   = Get-JsonFile $_.FullName
    if (-not $usage) { return }

    # Sum up tokens across all models
    $totalPrompt     = 0
    $totalCompletion = 0
    $totalCalls      = 0
    $modelBreakdown  = @{}

    foreach ($prop in $usage.PSObject.Properties) {
        $modelName = $prop.Name
        $modelData = $prop.Value
        if ($modelData.input_tokens -or $modelData.output_tokens -or $modelData.total_calls) {
            $inp  = if ($modelData.input_tokens)  { $modelData.input_tokens }  else { 0 }
            $out  = if ($modelData.output_tokens) { $modelData.output_tokens } else { 0 }
            $calls = if ($modelData.total_calls)  { $modelData.total_calls }   else { 0 }
            $totalPrompt     += $inp
            $totalCompletion += $out
            $totalCalls      += $calls
            $modelBreakdown[$modelName] = @{ input = $inp; output = $out; calls = $calls }
        }
    }

    $usageSummaries[$botName] = @{
        bot_name          = $botName
        total_input_tokens = $totalPrompt
        total_output_tokens = $totalCompletion
        total_tokens      = $totalPrompt + $totalCompletion
        total_calls       = $totalCalls
        model_breakdown   = $modelBreakdown
    }
}

# ── Print console summary ─────────────────────────────────────────────────────

$divider = "-" * 60
Write-Host $divider
Write-Host "Experiment:  $($meta.name)" -ForegroundColor White
Write-Host "Mode:        $($meta.mode)"
Write-Host "Duration:    $($meta.duration_minutes) minutes"
if ($meta.goal) { Write-Host "Goal:        $($meta.goal)" }
Write-Host $divider

foreach ($botName in ($ensembleSummaries.Keys + $usageSummaries.Keys | Select-Object -Unique | Sort-Object)) {
    Write-Host ""
    Write-Host "$botName" -ForegroundColor Yellow

    $ens   = $ensembleSummaries[$botName]
    $usage = $usageSummaries[$botName]

    if ($ens) {
        Write-Host "  Decisions:   $($ens.total_decisions)"
        Write-Host "  Avg latency: $($ens.avg_latency_ms) ms"
        Write-Host "  Agreement:   $($ens.avg_agreement_pct)%"
        if ($ens.judge_overrides -gt 0) {
            Write-Host "  Judge:       $($ens.judge_overrides) overrides ($($ens.judge_override_pct)%)"
        }
        if ($ens.win_rates.Count -gt 0) {
            Write-Host "  Panel wins:"
            foreach ($k in ($ens.win_rates.Keys | Sort-Object)) {
                Write-Host "    $k → $($ens.win_rates[$k])%"
            }
        }
    } else {
        Write-Host "  (No ensemble log)" -ForegroundColor DarkGray
    }

    if ($usage) {
        $totalK = [Math]::Round($usage.total_tokens / 1000, 1)
        Write-Host "  Tokens:      ${totalK}K total ($($usage.total_input_tokens) in / $($usage.total_output_tokens) out)"
        Write-Host "  API calls:   $($usage.total_calls)"
    } else {
        Write-Host "  (No usage log)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host $divider

# ── Write results files ───────────────────────────────────────────────────────

$summary = @{
    experiment        = $meta
    analyzed_at       = (Get-Date -Format "o")
    ensemble          = $ensembleSummaries
    usage             = $usageSummaries
}

$summaryJsonPath = Join-Path $resultsDir "summary.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryJsonPath -Encoding UTF8

# Plain-text report
$lines = @(
    "Experiment Analysis: $($meta.id)",
    "Analyzed: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    "Mode: $($meta.mode) | Duration: $($meta.duration_minutes) min",
    ($meta.goal ? "Goal: $($meta.goal)" : ""),
    "",
    $divider
)
foreach ($botName in ($ensembleSummaries.Keys + $usageSummaries.Keys | Select-Object -Unique | Sort-Object)) {
    $ens   = $ensembleSummaries[$botName]
    $usage = $usageSummaries[$botName]
    $lines += "$botName"
    if ($ens) {
        $lines += "  Decisions: $($ens.total_decisions) | Avg latency: $($ens.avg_latency_ms)ms | Agreement: $($ens.avg_agreement_pct)%"
        if ($ens.win_rates.Count -gt 0) {
            $lines += "  Panel wins: $(($ens.win_rates.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)%" }) -join ', ')"
        }
    }
    if ($usage) {
        $totalK = [Math]::Round($usage.total_tokens / 1000, 1)
        $lines += "  Tokens: ${totalK}K | API calls: $($usage.total_calls)"
    }
    $lines += ""
}

$summaryTxtPath = Join-Path $resultsDir "summary.txt"
$lines | Set-Content -Path $summaryTxtPath -Encoding UTF8

Write-Host "Results written to: $resultsDir" -ForegroundColor Green
Write-Host "  summary.json" -ForegroundColor DarkGray
Write-Host "  summary.txt" -ForegroundColor DarkGray
Write-Host ""

if ($Open) { Start-Process "notepad.exe" -ArgumentList $summaryTxtPath }
