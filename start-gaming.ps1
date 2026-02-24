<#
.SYNOPSIS
    Starts a Minecraft gaming session on PC
.DESCRIPTION
    Syncs world from NAS, starts server, and launches the bot
#>

param(
    [Parameter(Mandatory=$false)]
    [int]$MaxWaitSeconds = 60,
    [Parameter(Mandatory=$false)]
    [string]$ContainerName = "minecraft-server",
    [Parameter(Mandatory=$false)]
    [int]$Port = 25565
)

function Test-MinecraftReady {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [Parameter(Mandatory=$true)]
        [int]$Port
    )

    $conn = $null
    try {
        $conn = Test-NetConnection -ComputerName "127.0.0.1" -Port $Port -WarningAction SilentlyContinue
        if (-not $conn.TcpTestSucceeded) {
            return $false
        }
    } catch {
        return $false
    }

    try {
        $logs = docker logs $Name --since 5m 2>$null
        if ($logs -match "Done \(") {
            return $true
        }
    } catch {
        return $conn.TcpTestSucceeded
    }

    return $false
}

Write-Host "`n🎮 Starting Minecraft Gaming Session..." -ForegroundColor Green
Write-Host "================================`n" -ForegroundColor Green

# Step 1: Sync world from NAS
Write-Host "📥 Step 1/3: Loading latest world from NAS..." -ForegroundColor Cyan
.\sync-world.ps1 -Direction FromNAS

if ($LASTEXITCODE -ne 0) {
    Write-Host "`n❌ Failed to sync world from NAS. Aborting." -ForegroundColor Red
    exit 1
}

# Step 2: Wait for server to be ready
Write-Host "`n⏳ Step 2/3: Waiting for Minecraft server to start..." -ForegroundColor Cyan
$maxWaitSeconds = $MaxWaitSeconds
$elapsedSeconds = 0
$serverReady = $false

while ($elapsedSeconds -lt $maxWaitSeconds) {
    if (Test-MinecraftReady -Name $ContainerName -Port $Port) {
        $serverReady = $true
        break
    }
    Start-Sleep -Seconds 2
    $elapsedSeconds += 2
}

if ($serverReady) {
    Write-Host "✅ Server is running!" -ForegroundColor Green
} else {
    Write-Host "⚠️  Server may still be starting. Check with: docker logs minecraft-server -f" -ForegroundColor Yellow
}

# Step 3: Start bot
Write-Host "`n🤖 Step 3/3: Starting Mindcraft bot..." -ForegroundColor Cyan
Write-Host "================================`n" -ForegroundColor Green
Write-Host "✅ Ready to play!" -ForegroundColor Green
Write-Host "   Server: localhost:25565" -ForegroundColor DarkGray
Write-Host "   Camera: http://localhost:3000/`n" -ForegroundColor DarkGray

# Start the bot
node main.js
