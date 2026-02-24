<#
.SYNOPSIS
    Auto-syncs Minecraft world from NAS on PC startup
.DESCRIPTION
    Designed to run via Windows Task Scheduler at logon
    Waits for network, then pulls latest world from NAS
#>

# Wait for network to be available
Write-Host "⏳ Waiting for network..." -ForegroundColor Cyan
Start-Sleep -Seconds 10

# Change to Mindcraft directory
Set-Location $PSScriptRoot

# Sync world from NAS
Write-Host "📥 Auto-syncing Minecraft world from NAS..." -ForegroundColor Cyan
.\sync-world.ps1 -Direction FromNAS

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Startup sync complete!" -ForegroundColor Green
} else {
    Write-Host "⚠️  Startup sync failed. Run manually when needed." -ForegroundColor Yellow
}
