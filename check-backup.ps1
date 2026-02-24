param(
    [string]$SSHUser = "Zombie",
    [string]$SSHHost = "192.168.0.30",
    [string]$SSHKeyPath = "$($env:USERPROFILE)\.ssh\nas_key",
    [string]$BackupPath = '/volume1/Minecraft-Backups',
    [int]$MaxAgeHours = 24,
    [string]$DiscordWebhookUrl = $env:BACKUP_WEBHOOK_URL,
    [string]$LocalLogPath = "$($PSScriptRoot)\backup-alerts.log",
    [switch]$NotifyLocal,
    [switch]$NotifyOnSuccess
)

function Write-LocalAlert {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LocalLogPath -Append
    if ($NotifyLocal) {
        msg.exe * $Message | Out-Null
    }
}

$latestCmd = "ls -t $BackupPath | head -n 1"
$latest = & ssh -i $SSHKeyPath "$SSHUser@$SSHHost" $latestCmd 2>$null

if (-not $latest) {
    Write-Host "No backups found." -ForegroundColor Red
    if ($DiscordWebhookUrl) {
        Invoke-RestMethod -Method Post -Uri $DiscordWebhookUrl -ContentType "application/json" -Body (@{ content = "Backup missing on NAS." } | ConvertTo-Json)
    }
    Write-LocalAlert "Backup missing on NAS."
    exit 1
}

$timeCmd = "stat -c %Y $BackupPath/$latest"
$epoch = & ssh -i $SSHKeyPath "$SSHUser@$SSHHost" $timeCmd 2>$null
$last = [DateTimeOffset]::FromUnixTimeSeconds([int64]$epoch).UtcDateTime
$age = (Get-Date).ToUniversalTime() - $last

if ($age.TotalHours -gt $MaxAgeHours) {
    Write-Host "Backup too old: $([int]$age.TotalHours) hours." -ForegroundColor Red
    if ($DiscordWebhookUrl) {
        Invoke-RestMethod -Method Post -Uri $DiscordWebhookUrl -ContentType "application/json" -Body (@{ content = "Backup is stale ($([int]$age.TotalHours)h)." } | ConvertTo-Json)
    }
    Write-LocalAlert "Backup is stale ($([int]$age.TotalHours)h)."
    exit 2
}

Write-Host "Backup OK: $latest ($([int]$age.TotalHours)h old)" -ForegroundColor Green
if ($NotifyOnSuccess) {
    if ($DiscordWebhookUrl) {
        Invoke-RestMethod -Method Post -Uri $DiscordWebhookUrl -ContentType "application/json" -Body (@{ content = "Backup OK: $latest ($([int]$age.TotalHours)h old)." } | ConvertTo-Json)
    }
    Write-LocalAlert "Backup OK: $latest ($([int]$age.TotalHours)h old)."
}
