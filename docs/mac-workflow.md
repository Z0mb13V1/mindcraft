# MacBook Pro Workflow

Quick reference for operating the Mindcraft hybrid rig from your Mac.

## Prerequisites

- SSH key: `~/.ssh/mindcraft-ec2.pem` (chmod 600)
- AWS CLI configured: `aws configure --profile mindcraft` (use Mindcraft-AI-Bot-AdministratorAccess creds)
- Git clone: `git clone git@github.com:Z0mb13V1/mindcraft-0.1.3.git`

## Daily Commands

### Quick redeploy (code changes only)
```bash
git push origin main
bash aws/ec2-go.sh
```

### Full redeploy (rebuild + secrets)
```bash
bash aws/ec2-go.sh --full
```

### Check bot status
```bash
ssh -i ~/.ssh/mindcraft-ec2.pem ubuntu@54.152.239.117 \
  'docker compose -f /app/docker-compose.aws.yml logs --tail 20 mindcraft'
```

### Restart just the bots
```bash
ssh -i ~/.ssh/mindcraft-ec2.pem ubuntu@54.152.239.117 \
  'cd /app && docker compose -f docker-compose.aws.yml restart mindcraft discord-bot'
```

### Restart everything
```bash
ssh -i ~/.ssh/mindcraft-ec2.pem ubuntu@54.152.239.117 \
  'cd /app && docker compose -f docker-compose.aws.yml up -d --force-recreate'
```

## API Key Rotation

When a key expires, update it in SSM from your Mac:

```bash
# Gemini
aws ssm put-parameter --profile mindcraft --region us-east-1 \
  --name /mindcraft/GEMINI_API_KEY --type SecureString \
  --value "NEW_KEY_HERE" --overwrite

# XAI (Grok)
aws ssm put-parameter --profile mindcraft --region us-east-1 \
  --name /mindcraft/XAI_API_KEY --type SecureString \
  --value "NEW_KEY_HERE" --overwrite
```

Then redeploy secrets to EC2:
```bash
bash aws/ec2-go.sh --secrets
```

## Monitoring

| Service     | URL                              |
|-------------|----------------------------------|
| MindServer  | http://54.152.239.117:8080       |
| Grafana     | http://54.152.239.117:3004       |
| Prometheus  | http://54.152.239.117:9090       |
| Minecraft   | 54.152.239.117:25565             |

## Tailscale + Local 3090

Your Windows PC (RTX 3090) runs Ollama at `100.122.190.4:11434`.
The socat proxy on EC2 forwards `127.0.0.1:11435` → Tailscale → your 3090.

To set up the proxy on EC2:
```bash
ssh -i ~/.ssh/mindcraft-ec2.pem ubuntu@54.152.239.117 \
  'sudo bash /app/aws/setup-ollama-proxy.sh'
```

## Browser SSH (no .pem needed)

If you don't have the .pem file handy:
1. AWS Console → EC2 → Instances → select instance
2. Click **Connect** → **EC2 Instance Connect** → **Connect**
3. Run commands directly in the browser terminal

## Troubleshooting

**Bots not connecting:** Check Minecraft server is healthy first:
```bash
ssh ... 'docker inspect --format "{{.State.Health.Status}}" minecraft-server'
```

**API key errors:** Check keys.json on EC2:
```bash
ssh ... 'cat /app/keys.json | python3 -m json.tool'
```

**Container OOM:** Check memory usage:
```bash
ssh ... 'docker stats --no-stream'
```
