<#
.SYNOPSIS
    Full Tailscale setup automation for Windows 11 — install, login, detect IPs, save to .env.
.DESCRIPTION
    Automates the entire Tailscale setup process:
    1. Check/install Tailscale on Windows
    2. Start Tailscale service
    3. Authenticate (opens browser)
    4. Detect local Tailscale IP
    5. (Optional) Verify EC2 Tailscale IP connectivity
    6. Save Tailscale IPs to .env for use by start.ps1
    7. Test Minecraft port connectivity

.PARAMETER Ec2Ip
    Public or Tailscale IP of EC2 instance to test connectivity.
.PARAMETER SkipInstall
    Skip the Tailscale install check.
.PARAMETER SaveToEnv
    Save detected Tailscale IPs to .env automatically. Default: true.
.EXAMPLE
    .\tailscale-setup.ps1                          # Install + detect local IP
    .\tailscale-setup.ps1 -Ec2Ip 100.64.0.2       # Full setup + verify EC2
    .\tailscale-setup.ps1 -SkipInstall             # Just detect IPs
#>
param(
    [string]$Ec2Ip,
    [switch]$SkipInstall,
    [bool]$SaveToEnv = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Header { param([string]$m) Write-Host "" ; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Write-OK     { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn   { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail   { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Info   { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║    Tailscale Setup — Windows 11                  ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan

$pass = 0; $fail = 0

# ── Step 1: Check/Install Tailscale ────────────────────────────────────────────

Write-Header "Step 1: Tailscale Installation"

if (-not $SkipInstall) {
    $tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($tsCmd) {
        $tsVersion = & tailscale version 2>&1 | Select-Object -First 1
        Write-OK "Tailscale installed: $tsVersion"
        $pass++
    } else {
        Write-Warn "Tailscale not found. Installing via winget..."
        $wingetCheck = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetCheck) {
            & winget install Tailscale.Tailscale --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            # Refresh PATH
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH", "User")
            $tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
            if ($tsCmd) {
                Write-OK "Tailscale installed successfully"
                $pass++
            } else {
                Write-Fail "Tailscale installed but not in PATH. Restart your terminal and re-run."
                $fail++
                Write-Info "Or manually add to PATH: C:\Program Files\Tailscale"
            }
        } else {
            Write-Fail "winget not available. Install Tailscale manually from https://tailscale.com/download/windows"
            $fail++
        }
    }
} else {
    Write-Info "Skipping install check (-SkipInstall)"
}

# ── Step 2: Ensure Tailscale is running ────────────────────────────────────────

Write-Header "Step 2: Tailscale Service"

$tsStatus = & tailscale status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Tailscale not running. Starting service..."
    try {
        Start-Service -Name "Tailscale" -ErrorAction Stop
        Start-Sleep -Seconds 3
        $tsStatus = & tailscale status 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Tailscale service started"
            $pass++
        } else {
            Write-Warn "Service started but tailscale status failed. You may need to log in."
        }
    } catch {
        Write-Fail "Could not start Tailscale service. Open Tailscale from Start Menu."
        $fail++
    }
} else {
    Write-OK "Tailscale service running"
    $pass++
}

# ── Step 3: Authentication ─────────────────────────────────────────────────────

Write-Header "Step 3: Authentication"

# Check if already logged in by looking for an IP
$localTsIp = $null
try {
    $ipOutput = & tailscale ip -4 2>&1
    if ($LASTEXITCODE -eq 0 -and $ipOutput -match '^\d+\.\d+\.\d+\.\d+$') {
        $localTsIp = $ipOutput.Trim()
        Write-OK "Already logged in — Local Tailscale IP: $localTsIp"
        $pass++
    } else {
        Write-Warn "Not logged in. Opening browser for authentication..."
        Write-Info "Sign in to your Tailscale account in the browser window that opens."
        & tailscale up 2>&1
        Start-Sleep -Seconds 5

        $ipOutput = & tailscale ip -4 2>&1
        if ($LASTEXITCODE -eq 0 -and $ipOutput -match '^\d+\.\d+\.\d+\.\d+$') {
            $localTsIp = $ipOutput.Trim()
            Write-OK "Authenticated — Local Tailscale IP: $localTsIp"
            $pass++
        } else {
            Write-Fail "Could not get Tailscale IP after login. Check Tailscale system tray."
            $fail++
        }
    }
} catch {
    Write-Fail "Error checking Tailscale status: $_"
    $fail++
}

# ── Step 4: Show connected devices ────────────────────────────────────────────

Write-Header "Step 4: Connected Devices"

$devices = & tailscale status 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    $devices -split "`n" | ForEach-Object {
        if ($_ -match '\S') { Write-Info $_ }
    }
    Write-Host ""
} else {
    Write-Warn "Could not list devices"
}

# ── Step 5: EC2 Connectivity Test ──────────────────────────────────────────────

$ec2TsIp = $null

if ($Ec2Ip) {
    Write-Header "Step 5: EC2 Connectivity"

    # Ping test
    Write-Info "Testing connectivity to $Ec2Ip..."
    $pingResult = Test-NetConnection -ComputerName $Ec2Ip -WarningAction SilentlyContinue
    if ($pingResult.PingSucceeded) {
        Write-OK "Ping to $Ec2Ip succeeded"
        $ec2TsIp = $Ec2Ip
        $pass++
    } else {
        Write-Warn "Ping to $Ec2Ip failed (may be blocked by firewall — checking Minecraft port)"
    }

    # Minecraft port test
    Write-Info "Testing Minecraft port (25565)..."
    $mcTest = Test-NetConnection -ComputerName $Ec2Ip -Port 25565 -WarningAction SilentlyContinue
    if ($mcTest.TcpTestSucceeded) {
        Write-OK "Minecraft port 25565 reachable on $Ec2Ip"
        $ec2TsIp = $Ec2Ip
        $pass++
    } else {
        Write-Fail "Minecraft port 25565 not reachable on $Ec2Ip"
        Write-Info "Add inbound rule to EC2 security group:"
        Write-Info "  Type: Custom TCP | Port: 25565 | Source: 100.64.0.0/10 (Tailscale CGNAT)"
        $fail++
    }

    # SSH test
    Write-Info "Testing SSH port (22)..."
    $sshTest = Test-NetConnection -ComputerName $Ec2Ip -Port 22 -WarningAction SilentlyContinue
    if ($sshTest.TcpTestSucceeded) {
        Write-OK "SSH port 22 reachable — ssh ubuntu@$Ec2Ip"
        $pass++
    } else {
        Write-Info "SSH not reachable via Tailscale (may need --ssh flag on EC2)"
    }
} else {
    Write-Header "Step 5: EC2 Connectivity (skipped)"
    Write-Info "Pass -Ec2Ip <tailscale-ip> to test EC2 connectivity"
}

# ── Step 6: Save to .env ──────────────────────────────────────────────────────

if ($SaveToEnv -and $localTsIp) {
    Write-Header "Step 6: Saving to .env"

    $envPath = Join-Path $PSScriptRoot ".env"
    $envContent = if (Test-Path $envPath) { Get-Content $envPath -Raw } else { "" }

    # Update or add TAILSCALE_LOCAL_IP
    if ($envContent -match 'TAILSCALE_LOCAL_IP=') {
        $envContent = $envContent -replace 'TAILSCALE_LOCAL_IP=.*', "TAILSCALE_LOCAL_IP=$localTsIp"
    } else {
        $envContent += "`nTAILSCALE_LOCAL_IP=$localTsIp"
    }

    # Update or add TAILSCALE_MC_HOST if EC2 IP detected
    if ($ec2TsIp) {
        if ($envContent -match 'TAILSCALE_MC_HOST=') {
            $envContent = $envContent -replace 'TAILSCALE_MC_HOST=.*', "TAILSCALE_MC_HOST=$ec2TsIp"
        } else {
            $envContent += "`nTAILSCALE_MC_HOST=$ec2TsIp"
        }
    }

    $envContent.TrimEnd() | Set-Content -Path $envPath -Encoding UTF8 -NoNewline
    Write-OK "Saved Tailscale IPs to .env"
    if ($localTsIp) { Write-Info "TAILSCALE_LOCAL_IP=$localTsIp" }
    if ($ec2TsIp)   { Write-Info "TAILSCALE_MC_HOST=$ec2TsIp" }
    $pass++
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
Write-Host "  ║  Tailscale Setup: $pass passed, $fail failed               ║" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Yellow" })
Write-Host ""

if ($localTsIp) {
    Write-Host "  Your Tailscale IP: $localTsIp" -ForegroundColor White
}
if ($ec2TsIp) {
    Write-Host "  EC2 Tailscale IP:  $ec2TsIp" -ForegroundColor White
    Write-Host ""
    Write-Host "  Connect local bot to EC2 world:" -ForegroundColor Green
    Write-Host "    .\start.ps1 local -McHost $ec2TsIp -Detach" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "  EC2 Tailscale Setup (run on EC2 via Instance Connect):" -ForegroundColor Yellow
    Write-Host "    curl -fsSL https://tailscale.com/install.sh | sh" -ForegroundColor White
    Write-Host "    sudo tailscale up --ssh" -ForegroundColor White
    Write-Host "    tailscale ip -4    # note this IP" -ForegroundColor White
    Write-Host ""
    Write-Host "  Then re-run: .\tailscale-setup.ps1 -Ec2Ip <ec2-tailscale-ip>" -ForegroundColor White
}
Write-Host ""
