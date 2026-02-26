<#
.SYNOPSIS
    Analyze experiment results with rich research metrics.
.DESCRIPTION
    Parses ensemble_log.json, usage.json, and conversation logs from the
    experiment's logs/ directory. Computes:
    - Ensemble metrics (panel agreement, judge overrides, model win rates)
    - API usage and cost breakdown
    - Conversation metrics (interaction frequency, command diversity)
    - Research metrics (coordination score, resource efficiency, error rate)
    Writes summary.json and summary.txt to results/ directory.
.PARAMETER ExperimentDir
    Path to a completed experiment directory.
.PARAMETER Open
    Open results/summary.txt in Notepad after analysis.
.EXAMPLE
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
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║         Experiment Analysis: $($meta.id.PadRight(22))║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Helpers ────────────────────────────────────────────────────────────────────

function Get-JsonFile { param([string]$p) if (Test-Path $p) { try { Get-Content $p -Raw | ConvertFrom-Json } catch { $null } } else { $null } }

# ── Parse ensemble logs ───────────────────────────────────────────────────────

$ensembleSummaries = @{}

Get-ChildItem $logsDir -Filter "*ensemble_log.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $botName  = ($_.Name -replace "_ensemble_log.json", "")
    $entries  = Get-JsonFile $_.FullName
    if (-not $entries) { return }
    if ($entries -is [array]) { $log = $entries } else { $log = @($entries) }

    $totalDecisions = $log.Count
    $winCounts      = @{}
    $latencies      = @()
    $agreementVals  = @()
    $judgeOverrides = 0
    $commandCounts  = @{}

    foreach ($entry in $log) {
        if ($entry.winner_id) {
            if (-not $winCounts.ContainsKey($entry.winner_id)) { $winCounts[$entry.winner_id] = 0 }
            $winCounts[$entry.winner_id]++
        }
        if ($entry.winner_latency_ms) { $latencies += $entry.winner_latency_ms }
        if ($entry.panel_agreement)   { $agreementVals += $entry.panel_agreement }
        if ($entry.judge_override -eq $true) { $judgeOverrides++ }
        # Track command diversity
        if ($entry.winner_command) {
            $cmd = $entry.winner_command -replace '\(.*', ''  # Strip args
            if (-not $commandCounts.ContainsKey($cmd)) { $commandCounts[$cmd] = 0 }
            $commandCounts[$cmd]++
        }
    }

    $avgLatency   = if ($latencies.Count -gt 0)    { [Math]::Round(($latencies | Measure-Object -Average).Average) } else { 0 }
    $p50Latency   = if ($latencies.Count -gt 0)    { $sorted = $latencies | Sort-Object; $sorted[[Math]::Floor($sorted.Count * 0.5)] } else { 0 }
    $p99Latency   = if ($latencies.Count -gt 0)    { $sorted = $latencies | Sort-Object; $sorted[[Math]::Floor($sorted.Count * 0.99)] } else { 0 }
    $avgAgreement = if ($agreementVals.Count -gt 0) { [Math]::Round(($agreementVals | Measure-Object -Average).Average * 100, 1) } else { 0 }

    $winRates = @{}
    foreach ($k in $winCounts.Keys) {
        $winRates[$k] = [Math]::Round($winCounts[$k] / [Math]::Max(1, $totalDecisions) * 100, 1)
    }

    $ensembleSummaries[$botName] = @{
        bot_name            = $botName
        total_decisions     = $totalDecisions
        avg_latency_ms      = $avgLatency
        p50_latency_ms      = $p50Latency
        p99_latency_ms      = $p99Latency
        avg_agreement_pct   = $avgAgreement
        judge_overrides     = $judgeOverrides
        judge_override_pct  = [Math]::Round($judgeOverrides / [Math]::Max(1, $totalDecisions) * 100, 1)
        win_rates           = $winRates
        command_diversity   = $commandCounts.Count  # unique commands used
        top_commands        = $commandCounts
    }
}

# ── Parse usage logs ──────────────────────────────────────────────────────────

$usageSummaries = @{}

Get-ChildItem $logsDir -Filter "*usage.json" -ErrorAction SilentlyContinue | ForEach-Object {
    $botName = ($_.Name -replace "_usage.json", "")
    $usage   = Get-JsonFile $_.FullName
    if (-not $usage) { return }

    $totalPrompt     = 0
    $totalCompletion = 0
    $totalCalls      = 0
    $totalCost       = 0.0
    $modelBreakdown  = @{}

    foreach ($prop in $usage.PSObject.Properties) {
        $modelName = $prop.Name
        $modelData = $prop.Value
        if ($modelData.input_tokens -or $modelData.output_tokens -or $modelData.total_calls) {
            $inp   = if ($modelData.input_tokens)       { $modelData.input_tokens }       else { 0 }
            $out   = if ($modelData.output_tokens)      { $modelData.output_tokens }      else { 0 }
            $calls = if ($modelData.total_calls)        { $modelData.total_calls }        else { 0 }
            $cost  = if ($modelData.estimated_cost_usd) { $modelData.estimated_cost_usd } else { 0.0 }
            $totalPrompt     += $inp
            $totalCompletion += $out
            $totalCalls      += $calls
            $totalCost       += $cost
            $modelBreakdown[$modelName] = @{ input = $inp; output = $out; calls = $calls; cost = $cost }
        }
    }

    $usageSummaries[$botName] = @{
        bot_name            = $botName
        total_input_tokens  = $totalPrompt
        total_output_tokens = $totalCompletion
        total_tokens        = $totalPrompt + $totalCompletion
        total_calls         = $totalCalls
        estimated_cost_usd  = $totalCost
        model_breakdown     = $modelBreakdown
    }
}

# ── Parse conversation logs for research metrics ─────────────────────────────

$conversationMetrics = @{}

Get-ChildItem $logsDir -Include "*.txt","*.log" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $content   = Get-Content $_.FullName -ErrorAction SilentlyContinue
    if (-not $content) { return }
    $botName   = $_.BaseName -replace '_.*', ''

    $totalLines       = $content.Count
    $commandLines     = @($content | Where-Object { $_ -match '!\w+' })
    $errorLines       = @($content | Where-Object { $_ -match 'error|fail|crash|exception|timeout' })
    $coordLines       = @($content | Where-Object { $_ -match 'coordinate|collaborate|together|help|share' })
    $actionLines      = @($content | Where-Object { $_ -match '!newAction|!collectBlocks|!goToPlayer|!craftRecipe' })
    $deathLines       = @($content | Where-Object { $_ -match 'died|killed|drowned|burned|fell|starved' })

    # Extract unique commands used
    $uniqueCommands = @{}
    foreach ($line in $commandLines) {
        if ($line -match '(!\w+)') {
            $cmd = $Matches[1]
            if (-not $uniqueCommands.ContainsKey($cmd)) { $uniqueCommands[$cmd] = 0 }
            $uniqueCommands[$cmd]++
        }
    }

    if (-not $conversationMetrics.ContainsKey($botName)) {
        $conversationMetrics[$botName] = @{
            total_messages        = 0
            total_commands        = 0
            total_errors          = 0
            coordination_mentions = 0
            action_commands       = 0
            deaths                = 0
            unique_commands       = @{}
        }
    }

    $m = $conversationMetrics[$botName]
    $m.total_messages        += $totalLines
    $m.total_commands        += $commandLines.Count
    $m.total_errors          += $errorLines.Count
    $m.coordination_mentions += $coordLines.Count
    $m.action_commands       += $actionLines.Count
    $m.deaths                += $deathLines.Count
    foreach ($k in $uniqueCommands.Keys) {
        if (-not $m.unique_commands.ContainsKey($k)) { $m.unique_commands[$k] = 0 }
        $m.unique_commands[$k] += $uniqueCommands[$k]
    }
}

# ── Compute research scores ─────────────────────────────────────────────────

$researchScores = @{}

$allBots = @($ensembleSummaries.Keys) + @($usageSummaries.Keys) + @($conversationMetrics.Keys) | Select-Object -Unique | Sort-Object

foreach ($botName in $allBots) {
    $ens  = $ensembleSummaries[$botName]
    $use  = $usageSummaries[$botName]
    $conv = $conversationMetrics[$botName]

    $durationMin = if ($meta.duration_minutes) { $meta.duration_minutes } else { 30 }

    # Interaction frequency: commands per minute
    $cmdPerMin = if ($conv -and $durationMin -gt 0) { [Math]::Round($conv.total_commands / $durationMin, 2) } else { 0 }

    # Error rate: errors per total messages
    $errorRate = if ($conv -and $conv.total_messages -gt 0) { [Math]::Round($conv.total_errors / $conv.total_messages * 100, 1) } else { 0 }

    # Command diversity: unique commands / total commands (0-1, higher = more diverse)
    $cmdDiversity = if ($conv -and $conv.total_commands -gt 0) { [Math]::Round($conv.unique_commands.Count / [Math]::Max(1, $conv.total_commands) * 100, 1) } else { 0 }

    # Coordination score: coordination mentions per 100 messages (higher = more teamwork)
    $coordScore = if ($conv -and $conv.total_messages -gt 0) { [Math]::Round($conv.coordination_mentions / $conv.total_messages * 100, 1) } else { 0 }

    # Survival score: 100 - (deaths per 10 minutes * 10). Capped 0-100.
    $deathsPer10 = if ($conv -and $durationMin -gt 0) { $conv.deaths / ($durationMin / 10) } else { 0 }
    $survivalScore = [Math]::Max(0, [Math]::Min(100, [Math]::Round(100 - $deathsPer10 * 10)))

    # Cost efficiency: commands per dollar (higher = better)
    $costPerCmd = if ($use -and $use.estimated_cost_usd -gt 0 -and $conv) {
        [Math]::Round($conv.total_commands / $use.estimated_cost_usd, 1)
    } else { 0 }

    $researchScores[$botName] = @{
        commands_per_minute = $cmdPerMin
        error_rate_pct      = $errorRate
        command_diversity   = $cmdDiversity
        coordination_score  = $coordScore
        survival_score      = $survivalScore
        cost_per_command    = if ($costPerCmd -gt 0) { $costPerCmd } else { "N/A (local)" }
        deaths              = if ($conv) { $conv.deaths } else { 0 }
    }
}

# ── Print console summary ─────────────────────────────────────────────────────

$divider = "=" * 62

Write-Host $divider -ForegroundColor DarkGray
Write-Host "  Experiment:  $($meta.name)" -ForegroundColor White
Write-Host "  Mode:        $($meta.mode) | Duration: $($meta.duration_minutes) min"
if ($meta.goal) { Write-Host "  Goal:        $($meta.goal)" }
Write-Host $divider -ForegroundColor DarkGray

foreach ($botName in $allBots) {
    Write-Host ""
    Write-Host "  $botName" -ForegroundColor Yellow

    $ens   = $ensembleSummaries[$botName]
    $usage = $usageSummaries[$botName]
    $conv  = $conversationMetrics[$botName]
    $rs    = $researchScores[$botName]

    if ($ens) {
        Write-Host "    Ensemble:  $($ens.total_decisions) decisions | $($ens.avg_latency_ms)ms avg (P50:$($ens.p50_latency_ms) P99:$($ens.p99_latency_ms))"
        Write-Host "    Agreement: $($ens.avg_agreement_pct)% | Judge overrides: $($ens.judge_overrides) ($($ens.judge_override_pct)%)"
        if ($ens.win_rates.Count -gt 0) {
            $wins = ($ens.win_rates.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key):$($_.Value)%" }) -join "  "
            Write-Host "    Wins:      $wins"
        }
    }

    if ($usage) {
        $totalK = [Math]::Round($usage.total_tokens / 1000, 1)
        $costStr = if ($usage.estimated_cost_usd -gt 0) { "`$$($usage.estimated_cost_usd.ToString('F4'))" } else { "`$0 (local)" }
        Write-Host "    Tokens:    ${totalK}K ($($usage.total_input_tokens) in / $($usage.total_output_tokens) out) | $($usage.total_calls) calls"
        Write-Host "    Cost:      $costStr"
    }

    if ($rs) {
        Write-Host "    Research:  Cmds/min:$($rs.commands_per_minute) | Errors:$($rs.error_rate_pct)% | Diversity:$($rs.command_diversity)%" -ForegroundColor DarkCyan
        Write-Host "               Coordination:$($rs.coordination_score)% | Survival:$($rs.survival_score)/100 | Deaths:$($rs.deaths)" -ForegroundColor DarkCyan
    }
}

Write-Host ""
Write-Host $divider -ForegroundColor DarkGray

# ── Grand totals ──────────────────────────────────────────────────────────────

$grandTokens = ($usageSummaries.Values | ForEach-Object { $_.total_tokens } | Measure-Object -Sum).Sum
$grandCost   = ($usageSummaries.Values | ForEach-Object { $_.estimated_cost_usd } | Measure-Object -Sum).Sum
$grandCalls  = ($usageSummaries.Values | ForEach-Object { $_.total_calls } | Measure-Object -Sum).Sum
$grandK      = [Math]::Round($grandTokens / 1000, 1)

Write-Host "  TOTALS: ${grandK}K tokens | $grandCalls API calls | `$$([Math]::Round($grandCost, 4))" -ForegroundColor White
Write-Host $divider -ForegroundColor DarkGray

# ── Write results files ───────────────────────────────────────────────────────

$summary = [ordered]@{
    experiment         = $meta
    analyzed_at        = (Get-Date -Format "o")
    grand_totals       = @{
        total_tokens   = $grandTokens
        total_calls    = $grandCalls
        estimated_cost = $grandCost
    }
    ensemble           = $ensembleSummaries
    usage              = $usageSummaries
    conversation       = $conversationMetrics
    research_scores    = $researchScores
}

$summaryJsonPath = Join-Path $resultsDir "summary.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryJsonPath -Encoding UTF8

# Plain-text report
$lines = @(
    "Experiment Analysis: $($meta.id)",
    "Analyzed: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
    "Mode: $($meta.mode) | Duration: $($meta.duration_minutes) min",
    $(if ($meta.goal) { "Goal: $($meta.goal)" } else { "" }),
    "",
    $divider
)
foreach ($botName in $allBots) {
    $ens   = $ensembleSummaries[$botName]
    $usage = $usageSummaries[$botName]
    $rs    = $researchScores[$botName]
    $lines += ""
    $lines += $botName
    if ($ens) {
        $lines += "  Ensemble: $($ens.total_decisions) decisions | Avg:$($ens.avg_latency_ms)ms P50:$($ens.p50_latency_ms)ms P99:$($ens.p99_latency_ms)ms"
        $lines += "  Agreement: $($ens.avg_agreement_pct)% | Judge overrides: $($ens.judge_overrides)"
        if ($ens.win_rates.Count -gt 0) {
            $lines += "  Wins: $(($ens.win_rates.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)%" }) -join ', ')"
        }
    }
    if ($usage) {
        $totalK = [Math]::Round($usage.total_tokens / 1000, 1)
        $lines += "  Tokens: ${totalK}K | Calls: $($usage.total_calls) | Cost: `$$([Math]::Round($usage.estimated_cost_usd, 4))"
    }
    if ($rs) {
        $lines += "  Research: Cmds/min=$($rs.commands_per_minute) ErrorRate=$($rs.error_rate_pct)% Diversity=$($rs.command_diversity)%"
        $lines += "            Coordination=$($rs.coordination_score)% Survival=$($rs.survival_score)/100 Deaths=$($rs.deaths)"
    }
}
$lines += ""
$lines += $divider
$lines += "TOTALS: ${grandK}K tokens | $grandCalls calls | `$$([Math]::Round($grandCost, 4))"

$summaryTxtPath = Join-Path $resultsDir "summary.txt"
$lines | Set-Content -Path $summaryTxtPath -Encoding UTF8

Write-Host ""
Write-Host "  Results: $resultsDir" -ForegroundColor Green
Write-Host "    summary.json  (structured data for further analysis)" -ForegroundColor DarkGray
Write-Host "    summary.txt   (human-readable report)" -ForegroundColor DarkGray
Write-Host ""

if ($Open) { Start-Process "notepad.exe" -ArgumentList $summaryTxtPath }
