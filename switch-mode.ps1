<#
.SYNOPSIS
    Switch bot profiles between cloud, local, and hybrid compute modes.

.DESCRIPTION
    Reads _modes config from profile JSON files and applies the selected mode.
    Updates model, embedding, code_model, and conversing prompt identity facts.

    Modes:
      cloud  - Cloud API model only (Gemini, Grok, GPT, Claude, etc.)
      local  - Local vLLM model only (runs on host machine via vLLM)
      hybrid - Cloud model for chat, local vLLM model for code generation

.PARAMETER Mode
    Compute mode: cloud, local, or hybrid.

.PARAMETER ProfileName
    Profile name(s) without .json extension. Defaults to active bots.

.PARAMETER All
    Apply to all profiles that have _modes config.

.PARAMETER Restart
    Restart the mindcraft container after switching.

.EXAMPLE
    .\switch-mode.ps1 -Mode local
    .\switch-mode.ps1 -Mode hybrid -ProfileName gemini,grok -Restart
    .\switch-mode.ps1 -Mode cloud -All
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet("cloud", "local", "hybrid")]
    [string]$Mode,

    [string[]]$ProfileName,
    [switch]$All,
    [switch]$Restart
)

$ProfileDir = Join-Path $PSScriptRoot "profiles"

# Default to active profiles if none specified
if (-not $ProfileName -and -not $All) {
    $ProfileName = @("gemini", "gemini2", "grok")
}

if ($All) {
    $ProfileName = Get-ChildItem "$ProfileDir\*.json" |
        Where-Object { $_.Directory.Name -eq "profiles" } |
        ForEach-Object { $_.BaseName }
}

Write-Host ""
Write-Host "=== Mode Switch: $($Mode.ToUpper()) ===" -ForegroundColor Cyan
Write-Host ""

$switched = @()

foreach ($name in $ProfileName) {
    $path = Join-Path $ProfileDir "$name.json"
    if (-not (Test-Path $path)) {
        Write-Warning "Profile not found: $name.json"
        continue
    }

    $raw = Get-Content $path -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json

    if (-not $json._modes) {
        Write-Warning "No _modes config in $name.json - skipping"
        continue
    }

    # Get the mode config (cloud, local, or hybrid)
    $modeConfig = $json._modes.$Mode
    if (-not $modeConfig) {
        Write-Warning "Mode '$Mode' not defined in $name.json - skipping"
        continue
    }

    # Apply mode fields to top-level profile
    foreach ($prop in $modeConfig.PSObject.Properties) {
        $key = $prop.Name
        if ($key -eq "compute_type") { continue }  # metadata, not a Mindcraft field
        $json | Add-Member -NotePropertyName $key -NotePropertyValue $prop.Value -Force
    }

    # Remove code_model if this mode doesn't define one
    $modeKeys = @($modeConfig.PSObject.Properties.Name)
    if ($json.PSObject.Properties.Name -contains "code_model" -and $modeKeys -notcontains "code_model") {
        $json.PSObject.Properties.Remove("code_model")
    }

    # Update compute type in conversing prompt if it has identity facts
    if ($json.conversing -and $modeConfig.compute_type) {
        $json.conversing = $json.conversing -replace '(?<=- Compute: )[^\n\\]+', $modeConfig.compute_type
    }

    # Track active mode
    $json | Add-Member -NotePropertyName "_active_mode" -NotePropertyValue $Mode -Force

    # Write back with clean formatting
    $output = $json | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $output, [System.Text.UTF8Encoding]::new($false))

    $computeLabel = if ($modeConfig.compute_type) { " ($($modeConfig.compute_type))" } else { "" }
    Write-Host "  [OK] $name -> $Mode$computeLabel" -ForegroundColor Green
    $switched += $name
}

Write-Host ""
if ($switched.Count -gt 0) {
    Write-Host "Switched $($switched.Count) profile(s) to $Mode mode." -ForegroundColor Cyan
} else {
    Write-Host "No profiles were switched." -ForegroundColor Yellow
}

if ($Restart -and $switched.Count -gt 0) {
    Write-Host ""
    Write-Host "Restarting mindcraft container..." -ForegroundColor Yellow
    Push-Location $PSScriptRoot
    docker-compose up -d --force-recreate mindcraft
    Pop-Location
}
