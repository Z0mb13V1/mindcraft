# Tailscale Setup — Connect Local Bot to EC2 Minecraft

## Overview

Tailscale creates a secure mesh VPN between your Windows 11 desktop and the EC2
instance. This lets the **local RTX 3090 bot** (running on your desktop) join the
same Minecraft world as the **cloud ensemble bot** (running on EC2) — even though
they're on different networks.

Without Tailscale, both bots connect to a local Minecraft server (running in Docker
on your desktop). With Tailscale, you can connect the local bot to the EC2 Minecraft
server so both bots share one persistent world.

---

## Step 1 — Install Tailscale on Windows 11

1. Download from https://tailscale.com/download/windows
2. Install and sign in with a Tailscale account (free tier supports 100 devices)
3. Tailscale runs in the system tray. Click it to see your Tailscale IP.
4. Verify your IP:
   ```powershell
   tailscale ip -4
   # → 100.x.x.x
   ```

---

## Step 2 — Install Tailscale on EC2

SSH to EC2 via Instance Connect (browser), then:

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate and enable SSH access
sudo tailscale up --ssh

# Note the EC2 Tailscale IP
tailscale ip -4
# → 100.y.y.y
```

After this, you can SSH to EC2 directly via Tailscale:
```powershell
ssh ubuntu@100.y.y.y   # no security group changes needed
```

---

## Step 3 — Allow Minecraft Port Through EC2 Security Group

The Minecraft server on EC2 listens on port 25565. Allow the Tailscale subnet:

1. Go to EC2 → Security Groups → Select the mindcraft security group
2. Add Inbound Rule:
   - Type: Custom TCP
   - Port: 25565
   - Source: 100.64.0.0/10  (Tailscale CGNAT range)
   - Description: Tailscale Minecraft access

Or allow just your desktop's Tailscale IP: `100.x.x.x/32`

---

## Step 4 — Verify Connectivity

```powershell
# Ping EC2 via Tailscale
ping 100.y.y.y

# Test MC port is reachable
Test-NetConnection -ComputerName 100.y.y.y -Port 25565
```

You should see `TcpTestSucceeded: True`.

---

## Step 5 — Connect Local Bot to EC2 World

```powershell
# Start local RTX 3090 bot → connects to EC2 Minecraft server
.\start.ps1 local -McHost 100.y.y.y
```

The `-McHost` flag overrides the Minecraft server address in SETTINGS_JSON,
so the local bot connects to `100.y.y.y:25565` instead of the local Docker server.

---

## Step 6 — Both Bots in EC2 World

The cloud ensemble bot is already running on EC2 (via `docker-compose.aws.yml`).
The local bot joins the same world via Tailscale:

```powershell
# Just the local bot joining the EC2 world
.\start.ps1 local -McHost 100.y.y.y
```

In Minecraft client, join `100.y.y.y:25565` (or the EC2 public IP from your `.env` `EC2_PUBLIC_IP:25565`)
to see both bots in the same world.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `tailscale: command not found` | Restart terminal after install |
| Ping times out | Check Tailscale status: `tailscale status` |
| MC connection refused | Verify security group allows 25565 from Tailscale subnet |
| Slow connection (DERP relay) | Ensure UDP port 41641 is open on both machines |
| Bot can't connect | Verify `ONLINE_MODE: FALSE` in EC2 docker-compose.aws.yml |

### Tailscale Diagnostic Commands

```bash
tailscale status          # Show connected devices and their IPs
tailscale ping 100.y.y.y  # Test direct vs DERP relay path
tailscale netcheck        # Check NAT type and relay availability
```

---

## ACL Configuration (Optional)

If you use Tailscale ACLs, allow these ports between your devices:

```json
{
    "action": "accept",
    "src": ["autogroup:member"],
    "dst": ["autogroup:member:25565", "autogroup:member:8080", "autogroup:member:3000-3003"]
}
```

This allows Minecraft, MindServer UI, and bot cameras between your desktop and EC2.
