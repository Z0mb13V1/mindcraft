# Mindcraft Project Cleanup Script
# This script cleans up old logs, histories, and temporary files

param(
    [int]$DaysToKeep = 30,
    [switch]$DryRun = $false
)

Write-Host "Mindcraft Cleanup Script" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# Function to remove old files
function Remove-OldFiles {
    param(
        [string]$Path,
        [string]$Pattern,
        [int]$Days,
        [bool]$DryRun
    )
    
    if (Test-Path $Path) {
        $cutoffDate = (Get-Date).AddDays(-$Days)
        $files = Get-ChildItem -Path $Path -Filter $Pattern -Recurse -File | 
                 Where-Object { $_.LastWriteTime -lt $cutoffDate }
        
        if ($files.Count -gt 0) {
            $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
            $sizeMB = [math]::Round($totalSize / 1MB, 2)
            
            Write-Host "Found $($files.Count) old files in $Path ($sizeMB MB)" -ForegroundColor Yellow
            
            if (-not $DryRun) {
                $files | Remove-Item -Force
                Write-Host "  Deleted $($files.Count) files" -ForegroundColor Green
            } else {
                Write-Host "  [DRY RUN] Would delete $($files.Count) files" -ForegroundColor Yellow
            }
        } else {
            Write-Host "No old files found in $Path" -ForegroundColor Gray
        }
    }
}

# Clean old bot logs (conversation logs, error logs)
Write-Host "`nCleaning bot logs older than $DaysToKeep days..." -ForegroundColor White
Remove-OldFiles -Path "bots" -Pattern "*.txt" -Days $DaysToKeep -DryRun $DryRun
Remove-OldFiles -Path "bots" -Pattern "*.log" -Days $DaysToKeep -DryRun $DryRun

# Clean old action code
Write-Host "`nCleaning old action code..." -ForegroundColor White
Remove-OldFiles -Path "bots\*\action-code" -Pattern "*.js" -Days $DaysToKeep -DryRun $DryRun

# Clean old histories
Write-Host "`nCleaning old conversation histories..." -ForegroundColor White
Remove-OldFiles -Path "bots\*\histories" -Pattern "*.json" -Days $DaysToKeep -DryRun $DryRun

# Clean old screenshots
Write-Host "`nCleaning old screenshots..." -ForegroundColor White
Remove-OldFiles -Path "bots\*\screenshots" -Pattern "*.png" -Days $DaysToKeep -DryRun $DryRun

# Clean tmp directory
if (Test-Path "tmp") {
    Write-Host "`nCleaning tmp directory..." -ForegroundColor White
    $tmpFiles = Get-ChildItem -Path "tmp" -Recurse -File
    if ($tmpFiles.Count -gt 0) {
        $tmpSize = [math]::Round(($tmpFiles | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
        Write-Host "Found $($tmpFiles.Count) files in tmp ($tmpSize MB)" -ForegroundColor Yellow
        
        if (-not $DryRun) {
            Remove-Item -Path "tmp\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Cleaned tmp directory" -ForegroundColor Green
        } else {
            Write-Host "  [DRY RUN] Would clean tmp directory" -ForegroundColor Yellow
        }
    }
}

# Calculate final space savings
Write-Host "`n" -NoNewline
if ($DryRun) {
    Write-Host "DRY RUN COMPLETE" -ForegroundColor Yellow
    Write-Host "Run without -DryRun flag to actually delete files" -ForegroundColor Yellow
} else {
    Write-Host "CLEANUP COMPLETE" -ForegroundColor Green
}

# Show current bot directory size
$botsSize = (Get-ChildItem -Path "bots" -Recurse -File | Measure-Object -Property Length -Sum).Sum
$botsSizeMB = [math]::Round($botsSize / 1MB, 2)
Write-Host "`nCurrent bots directory size: $botsSizeMB MB" -ForegroundColor Cyan
