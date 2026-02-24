<#
.SYNOPSIS
    Stops Minecraft gaming session and saves to NAS
.DESCRIPTION
    Saves current world state to NAS and optionally stops the server
#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$KeepServerRunning
)

Write-Host "`n💾 Stopping Minecraft Gaming Session..." -ForegroundColor Yellow
Write-Host "================================`n" -ForegroundColor Yellow

# Step 1: Save world to NAS
Write-Host "📤 Saving world to NAS..." -ForegroundColor Cyan
.\sync-world.ps1 -Direction ToNAS

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n❌ Failed to save world to NAS!" -ForegroundColor Red
    Write-Host "   You may want to retry or manually backup your world." -ForegroundColor Yellow
    exit 1
}

# Step 2: Optionally stop server
if (-not $KeepServerRunning) {
    Write-Host "`n🛑 Stopping Minecraft server..." -ForegroundColor Cyan
    docker compose stop minecraft
    Write-Host "✅ Server stopped." -ForegroundColor Green
} else {
    Write-Host "`n✅ Server is still running (use -KeepServerRunning:$false to stop)" -ForegroundColor Green
}

Write-Host "`n✅ Session saved to NAS successfully!" -ForegroundColor Green
Write-Host "   World is backed up and ready for next session.`n" -ForegroundColor DarkGray
