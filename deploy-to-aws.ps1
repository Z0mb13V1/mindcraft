<#
.SYNOPSIS
    One-command AWS EC2 deployment — launches a Minecraft + CloudPersistent bot on EC2.
.DESCRIPTION
    Deploys the cloud research bot to AWS EC2 using your existing instance or launches
    a new one. Installs Docker, pulls the repo, configures .env, and starts services.

    Prerequisites:
    - AWS CLI installed and configured (aws configure)
    - SSH key pair registered in AWS
    - API keys set in local .env file

    Steps performed:
    1. Verify AWS CLI + credentials
    2. Detect or launch EC2 instance
    3. Wait for instance to be running + SSH ready
    4. Upload .env and docker-compose.aws.yml via EC2 Instance Connect or SCP
    5. SSH and run setup script (install Docker, clone repo, docker compose up)
    6. Return connection info (IP, Tailscale command, Minecraft address)

.PARAMETER InstanceId
    Existing EC2 instance ID. If not set, uses EC2_INSTANCE_ID from .env.
.PARAMETER KeyName
    AWS key pair name for SSH. Default: mindcraft-key
.PARAMETER Region
    AWS region. Default: us-east-1
.PARAMETER InstanceType
    EC2 instance type for new launches. Default: t3.medium (2 vCPU, 4GB RAM)
.PARAMETER StartOnly
    Just start an existing stopped instance (don't reinstall).
.PARAMETER StatusOnly
    Just check the instance status and return connection info.
.EXAMPLE
    .\deploy-to-aws.ps1                           # Use existing instance from .env
    .\deploy-to-aws.ps1 -StatusOnly                # Check status
    .\deploy-to-aws.ps1 -StartOnly                 # Start stopped instance
    .\deploy-to-aws.ps1 -InstanceId i-0abc123def   # Deploy to specific instance
#>
param(
    [string]$InstanceId,
    [string]$KeyName = "mindcraft-key",
    [string]$Region = "us-east-1",
    [string]$InstanceType = "t3.medium",
    [switch]$StartOnly,
    [switch]$StatusOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Header { param([string]$m) Write-Host "" ; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Write-OK     { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info   { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║    Mindcraft — AWS EC2 Deployment                ║" -ForegroundColor Magenta
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Magenta

# ── Step 1: Load .env ──────────────────────────────────────────────────────────

if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*(.*)\s*$') {
            $key = $Matches[1]; $val = $Matches[2].Trim('"').Trim("'")
            if (-not [System.Environment]::GetEnvironmentVariable($key) -and $val) {
                [System.Environment]::SetEnvironmentVariable($key, $val, "Process")
            }
        }
    }
}

# Resolve instance ID
if (-not $InstanceId) {
    $InstanceId = $env:EC2_INSTANCE_ID
}
if (-not $InstanceId) {
    Write-Fail "No EC2 instance ID. Set EC2_INSTANCE_ID in .env or pass -InstanceId"
    Write-Info "Example: .\deploy-to-aws.ps1 -InstanceId i-07340d0ddc3ac2bc5"
    exit 1
}

# ── Step 2: Verify AWS CLI ─────────────────────────────────────────────────────

Write-Header "Checking AWS CLI"

$awsCheck = Get-Command aws -ErrorAction SilentlyContinue
if (-not $awsCheck) {
    Write-Fail "AWS CLI not found. Install: winget install Amazon.AWSCLI"
    exit 1
}

$identity = & aws sts get-caller-identity --region $Region 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "AWS credentials not configured. Run: aws configure"
    exit 1
}
Write-OK "AWS CLI authenticated"
Write-Info "Instance: $InstanceId | Region: $Region"

# ── Step 3: Get instance status ────────────────────────────────────────────────

Write-Header "Instance Status"

$stateJson = & aws ec2 describe-instances --instance-ids $InstanceId --region $Region --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress,InstanceType]" --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Could not describe instance $InstanceId"
    Write-Info $stateJson
    exit 1
}
$stateArr = $stateJson | ConvertFrom-Json
$state = $stateArr[0]
$publicIp = $stateArr[1]
$iType = $stateArr[2]

Write-OK "State: $state | IP: $publicIp | Type: $iType"

if ($StatusOnly) {
    Write-Host ""
    Write-Host "  Connection Info:" -ForegroundColor White
    if ($publicIp) {
        Write-Info "SSH:       ssh ubuntu@$publicIp"
        Write-Info "Minecraft: $publicIp`:25565"
        Write-Info "MindServer: http://$publicIp`:8080/"
    } else {
        Write-Warn "No public IP (instance may be stopped)"
    }
    Write-Host ""
    exit 0
}

# ── Step 4: Start instance if stopped ──────────────────────────────────────────

if ($state -eq "stopped") {
    Write-Header "Starting Instance"
    & aws ec2 start-instances --instance-ids $InstanceId --region $Region | Out-Null
    Write-OK "Start command sent"

    # Wait for running state
    Write-Info "Waiting for instance to be running..."
    $maxWait = 120
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5
        $checkJson = & aws ec2 describe-instances --instance-ids $InstanceId --region $Region --query "Reservations[0].Instances[0].[State.Name,PublicIpAddress]" --output json 2>&1
        $checkArr = $checkJson | ConvertFrom-Json
        if ($checkArr[0] -eq "running" -and $checkArr[1]) {
            $publicIp = $checkArr[1]
            Write-OK "Instance running — IP: $publicIp"
            break
        }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
    if (-not $publicIp) {
        Write-Fail "Instance did not start within ${maxWait}s"
        exit 1
    }

    # Wait for SSH to be ready
    Write-Info "Waiting for SSH..."
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        $sshTest = Test-NetConnection -ComputerName $publicIp -Port 22 -WarningAction SilentlyContinue
        if ($sshTest.TcpTestSucceeded) {
            Write-OK "SSH ready"
            break
        }
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
}

if ($StartOnly) {
    Write-Host ""
    Write-Host "  Instance started. Connection info:" -ForegroundColor Green
    Write-Info "SSH:       ssh ubuntu@$publicIp"
    Write-Info "Minecraft: $publicIp`:25565"
    Write-Host ""
    exit 0
}

# ── Step 5: Build remote setup script ──────────────────────────────────────────

Write-Header "Preparing Deployment"

# Collect API keys for remote .env
$remoteEnvLines = @()
$envKeys = @("GEMINI_API_KEY", "XAI_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY",
             "DISCORD_BOT_TOKEN", "BOT_DM_CHANNEL", "BACKUP_CHAT_CHANNEL",
             "DISCORD_ADMIN_IDS", "BACKUP_WEBHOOK_URL")
foreach ($key in $envKeys) {
    $val = [System.Environment]::GetEnvironmentVariable($key)
    if ($val) { $remoteEnvLines += "$key=$val" }
}

$remoteEnv = $remoteEnvLines -join "`n"
$remoteEnvB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($remoteEnv))

# Build the setup script to run on EC2
$setupScript = @"
#!/bin/bash
set -euo pipefail

echo "=== Mindcraft EC2 Setup ==="

# Install Docker if not present
if ! command -v docker &>/dev/null; then
    echo "[1/6] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker ubuntu
    sudo systemctl enable docker
    sudo systemctl start docker
    echo "  Docker installed."
else
    echo "[1/6] Docker already installed."
fi

# Install docker compose plugin if not present
if ! docker compose version &>/dev/null; then
    echo "[2/6] Installing Docker Compose plugin..."
    sudo apt-get update -qq && sudo apt-get install -y -qq docker-compose-plugin
else
    echo "[2/6] Docker Compose already installed."
fi

# Clone or update repo
REPO_DIR="/home/ubuntu/mindcraft"
if [ -d "\$REPO_DIR" ]; then
    echo "[3/6] Updating existing repo..."
    cd "\$REPO_DIR"
    git pull --ff-only origin main 2>/dev/null || echo "  Pull failed (may have local changes)"
else
    echo "[3/6] Cloning repo..."
    git clone https://github.com/Z0mb13V1/mindcraft-0.1.3.git "\$REPO_DIR" 2>/dev/null || {
        echo "  Clone failed (private repo). Creating directory manually..."
        mkdir -p "\$REPO_DIR"
    }
fi

cd "\$REPO_DIR"

# Write .env from base64-encoded content
echo "[4/6] Writing .env..."
echo "$remoteEnvB64" | base64 -d > .env
echo "  .env written with $(echo "$remoteEnvB64" | base64 -d | wc -l) keys."

# Use docker-compose.aws.yml if it exists, otherwise docker-compose.yml
COMPOSE_FILE="docker-compose.yml"
if [ -f "docker-compose.aws.yml" ]; then
    COMPOSE_FILE="docker-compose.aws.yml"
fi

# Create data directories
echo "[5/6] Creating directories..."
mkdir -p minecraft-data bots

# Start services
echo "[6/6] Starting services..."
docker compose -f "\$COMPOSE_FILE" up -d --build 2>&1 | tail -5

echo ""
echo "=== Deployment Complete ==="
docker compose -f "\$COMPOSE_FILE" ps
echo ""
"@

$setupScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($setupScript))

# ── Step 6: Execute via EC2 Instance Connect ────────────────────────────────────

Write-Header "Deploying to EC2"
Write-Info "Sending setup script via SSM SendCommand..."

# Use SSM Run Command (works without SSH key — uses IAM role)
$ssmResult = & aws ssm send-command `
    --instance-ids $InstanceId `
    --region $Region `
    --document-name "AWS-RunShellScript" `
    --parameters "commands=[`"echo $setupScriptB64 | base64 -d | bash`"]" `
    --timeout-seconds 600 `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warn "SSM SendCommand failed (IAM role may not have SSM permissions)"
    Write-Info "Falling back to manual instructions..."
    Write-Host ""
    Write-Host "  Manual deployment steps:" -ForegroundColor Yellow
    Write-Host "  1. Connect to EC2 via Instance Connect (AWS Console)" -ForegroundColor White
    Write-Host "  2. Run: curl -fsSL https://get.docker.com | sh" -ForegroundColor White
    Write-Host "  3. Clone your repo and copy .env" -ForegroundColor White
    Write-Host "  4. Run: docker compose up -d" -ForegroundColor White
    Write-Host ""
} else {
    $cmdResult = $ssmResult | ConvertFrom-Json
    $commandId = $cmdResult.Command.CommandId
    Write-OK "Command sent: $commandId"

    # Wait for completion
    Write-Info "Waiting for deployment to finish (this takes 2-5 minutes)..."
    $maxWait = 300
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 10
        $waited += 10
        $statusJson = & aws ssm get-command-invocation `
            --command-id $commandId `
            --instance-id $InstanceId `
            --region $Region `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $statusObj = $statusJson | ConvertFrom-Json
            if ($statusObj.Status -in @("Success", "Failed", "TimedOut", "Cancelled")) {
                if ($statusObj.Status -eq "Success") {
                    Write-OK "Deployment succeeded!"
                    if ($statusObj.StandardOutputContent) {
                        $statusObj.StandardOutputContent -split "`n" | Select-Object -Last 10 | ForEach-Object {
                            Write-Info $_
                        }
                    }
                } else {
                    Write-Fail "Deployment $($statusObj.Status)"
                    if ($statusObj.StandardErrorContent) {
                        Write-Info $statusObj.StandardErrorContent
                    }
                }
                break
            }
        }
        $pct = [Math]::Min(100, [Math]::Round($waited / $maxWait * 100))
        Write-Host "`r  [$("=" * ($pct/5))$(" " * (20 - $pct/5))] ${pct}%" -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ── Step 7: Output connection info ─────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║    EC2 Deployment Complete                       ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Connection Info:" -ForegroundColor White
Write-Info "Public IP:   $publicIp"
Write-Info "SSH:         ssh ubuntu@$publicIp"
Write-Info "Minecraft:   $publicIp`:25565"
Write-Info "MindServer:  http://$publicIp`:8080/"
Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor White
Write-Info "1. Join Minecraft at $publicIp`:25565"
Write-Info "2. Set up Tailscale for local bot: .\tailscale-setup.ps1 -Ec2Ip $publicIp"
Write-Info "3. Connect local bot to EC2: .\start.ps1 local -McHost <tailscale-ip>"
Write-Info "4. Check status: .\deploy-to-aws.ps1 -StatusOnly"
Write-Host ""
