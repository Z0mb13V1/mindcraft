<#
.SYNOPSIS
    Syncs Minecraft world between PC and NAS
.DESCRIPTION
    Bidirectional sync for hybrid PC/NAS Minecraft setup
.PARAMETER Direction
    "ToNAS" or "FromNAS"
.PARAMETER NASPath
    UNC path to NAS minecraft data folder
.EXAMPLE
    .\sync-world.ps1 -Direction ToNAS
    .\sync-world.ps1 -Direction FromNAS -NASPath "\\192.168.1.100\minecraft-data"
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("ToNAS", "FromNAS")]
    [string]$Direction,
    
    [Parameter(Mandatory=$false)]
    [string]$NASPath = "\\192.168.0.30\Minecraft",
    [Parameter(Mandatory=$false)]
    [switch]$Verify,
    [Parameter(Mandatory=$false)]
    [switch]$VerifyHashes
)

$PCPath = "$PSScriptRoot\minecraft-data"
$LogFile = "$PSScriptRoot\sync-log.txt"
$syncFailed = $false

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Write-Host $logMessage -ForegroundColor Cyan
    $logMessage | Out-File -FilePath $LogFile -Append
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Source,
        [Parameter(Mandatory=$true)]
        [string]$Destination
    )

    robocopy $Source $Destination /MIR /Z /R:3 /W:5 /NP /NFL /NDL /LOG+:$LogFile
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        Write-Log "ERROR: Robocopy failed with exit code $exitCode"
        $script:syncFailed = $true
    } elseif ($exitCode -ge 1) {
        Write-Log "Robocopy completed with exit code $exitCode (non-fatal)"
    }
}

function Get-TreeStats {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Count = $files.Count
        Bytes = ($files | Measure-Object -Property Length -Sum).Sum
    }
}

function Compare-TreeHashes {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Source,
        [Parameter(Mandatory=$true)]
        [string]$Destination
    )

    $srcFiles = Get-ChildItem $Source -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $srcFiles) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart("\", "/")
        $destFile = Join-Path $Destination $relative
        if (-not (Test-Path $destFile)) {
            return $false
        }
        $hash1 = Get-FileHash $file.FullName -Algorithm SHA256
        $hash2 = Get-FileHash $destFile -Algorithm SHA256
        if ($hash1.Hash -ne $hash2.Hash) {
            return $false
        }
    }
    return $true
}

function Invoke-DockerCompose {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("stop", "start")]
        [string]$Action,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        docker compose $Action minecraft | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log "docker compose $Action succeeded on attempt $attempt"
            return
        }
        Write-Log "docker compose $Action failed (attempt $attempt of $MaxAttempts)"
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Log "ERROR: docker compose $Action failed after $MaxAttempts attempts"
    $script:syncFailed = $true
}

# Validate NAS path is configured
if ($NASPath -eq "\\YOUR-NAS-IP\minecraft-data") {
    Write-Host "❌ ERROR: Please configure your NAS path in sync-world.ps1" -ForegroundColor Red
    Write-Host "   Edit the file and replace '\\YOUR-NAS-IP\minecraft-data' with your actual NAS path" -ForegroundColor Yellow
    Write-Host "   Example: '\\192.168.1.100\docker\minecraft-data'" -ForegroundColor Yellow
    exit 1
}

# Test NAS connectivity
Write-Log "Testing NAS connectivity..."
if (-not (Test-Path $NASPath)) {
    Write-Host "❌ ERROR: Cannot access NAS path: $NASPath" -ForegroundColor Red
    Write-Host "   Ensure NAS is online and path is correct" -ForegroundColor Yellow
    exit 1
}

# Stop servers before sync
Write-Log "Stopping Minecraft server for sync..."
Invoke-DockerCompose -Action stop
Start-Sleep -Seconds 5

if ($Direction -eq "ToNAS") {
    Write-Host "`n📤 Syncing PC → NAS (backing up active world)" -ForegroundColor Green
    Write-Log "Syncing PC → NAS"
    
    # Ensure NAS directory exists
    if (-not (Test-Path $NASPath)) {
        New-Item -ItemType Directory -Path $NASPath -Force | Out-Null
    }
    
    Invoke-Robocopy -Source $PCPath -Destination $NASPath
    
    Write-Host "✅ World saved to NAS successfully!" -ForegroundColor Green
    
} else {
    Write-Host "`n📥 Syncing NAS → PC (loading saved world)" -ForegroundColor Green
    Write-Log "Syncing NAS → PC"
    
    # Ensure PC directory exists
    if (-not (Test-Path $PCPath)) {
        New-Item -ItemType Directory -Path $PCPath -Force | Out-Null
    }
    
    Invoke-Robocopy -Source $NASPath -Destination $PCPath
    
    Write-Host "✅ World loaded from NAS successfully!" -ForegroundColor Green
}

# Restart server
Write-Log "Restarting Minecraft server..."
Invoke-DockerCompose -Action start
Start-Sleep -Seconds 3

Write-Host "`n✅ Sync complete! Server is ready." -ForegroundColor Green
Write-Log "Sync operation completed successfully"
Write-Host "   Log file: $LogFile" -ForegroundColor DarkGray

if ($Verify) {
    Write-Log "Verifying sync results..."
    $sourcePath = if ($Direction -eq "ToNAS") { $PCPath } else { $NASPath }
    $destPath = if ($Direction -eq "ToNAS") { $NASPath } else { $PCPath }

    $sourceStats = Get-TreeStats -Path $sourcePath
    $destStats = Get-TreeStats -Path $destPath

    Write-Log "Source: $($sourceStats.Count) files, $($sourceStats.Bytes) bytes"
    Write-Log "Dest:   $($destStats.Count) files, $($destStats.Bytes) bytes"

    if ($sourceStats.Count -ne $destStats.Count -or $sourceStats.Bytes -ne $destStats.Bytes) {
        Write-Log "WARNING: Verification mismatch (count/bytes)."
    } elseif ($VerifyHashes) {
        if (-not (Compare-TreeHashes -Source $sourcePath -Destination $destPath)) {
            Write-Log "WARNING: Hash verification failed."
        } else {
            Write-Log "Hash verification passed."
        }
    } else {
        Write-Log "Verification passed."
    }
}

if ($syncFailed) {
    Write-Host "`n❌ Sync completed with errors. Review the log before continuing." -ForegroundColor Red
    exit 1
}
