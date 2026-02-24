# 🚨 IMMEDIATE ACTION REQUIRED - Security Incident Response Plan

**Date**: February 24, 2026  
**Severity**: HIGH  
**Status**: Files cleaned, awaiting user action

---

## 📊 Summary

Discord detected your bot token exposed in your public GitHub repository. I've scanned all files and found **3 types of exposed secrets**:

1. ✅ **Discord Bot Token** - Already invalidated by Discord
2. ⚠️ **Discord Webhook URL** - STILL ACTIVE, must revoke immediately
3. ✅ **API Keys (keys.json)** - Safe (never committed due to .gitignore)

---

## ✅ What I've Already Done

1. **Created Security Report**: [SECURITY-INCIDENT-REPORT.md](SECURITY-INCIDENT-REPORT.md)
2. **Updated .gitignore**: Added .env and secret file patterns
3. **Removed All Hardcoded Secrets** from:
   - docker-compose.yml
   - bot-test.js
   - discord-bot.js.bak
   - check-backup.ps1
4. **Created .env.example**: Template for environment variables
5. **Created Cleanup Tools**:
   - passwords.txt (for BFG/git-filter-repo)
   - clean-git-history.ps1 (automated cleanup script)

---

## 🎯 YOUR ACTION ITEMS (DO THESE NOW)

### Step 1: Get New Bot Token (5 minutes)
```
1. Visit: https://discord.com/developers/applications/1475823096467423311/bot
2. Click "Reset Token"
3. Copy the new token
4. Save it temporarily (we'll add it to .env in Step 3)
```

### Step 2: Revoke Webhook (3 minutes)
```
1. Open Discord
2. Go to your server → Server Settings → Integrations → Webhooks
3. Find the webhook used for backup alerts
4. Click "Delete Webhook"
5. Create a new webhook
6. Copy the new webhook URL
```

### Step 3: Create .env File (2 minutes)
```powershell
# Copy the template
Copy-Item .env.example .env

# Edit .env and add your NEW credentials:
# - DISCORD_BOT_TOKEN=<paste new token from Step 1>
# - BACKUP_WEBHOOK_URL=<paste new webhook from Step 2>
# - Everything else can stay as-is

# Example .env contents:
# DISCORD_BOT_TOKEN=MTQ3NTgyM0...your_new_token_here
# BACKUP_WEBHOOK_URL=https://discord.com/api/webhooks/...your_new_webhook
# BOT_DM_CHANNEL=1475829585164632184
# BACKUP_CHAT_CHANNEL=1475821409363034266
# MINDSERVER_HOST=mindcraft-013-mindcraft-1
# MINDSERVER_PORT=8080
```

### Step 4: Clean Git History (5-10 minutes)
```powershell
# OPTION A: Automated Script (Recommended)
.\clean-git-history.ps1

# OPTION B: Manual Nuclear Option (if script fails)
git checkout --orphan new-main
git add -A
git commit -m "Clean repository - removed exposed secrets"
git branch -D main
git branch -m main
git push --force origin main
```

### Step 5: Commit Security Fixes (3 minutes)
```powershell
# Stage all security changes
git add .gitignore bot-test.js check-backup.ps1 discord-bot.js.bak docker-compose.yml .env.example SECURITY-INCIDENT-REPORT.md ACTION-ITEMS.md

# Commit the security fixes
git commit -m "SECURITY: Remove all hardcoded secrets, use environment variables

- Removed Discord bot token from docker-compose.yml, bot-test.js, discord-bot.js.bak
- Removed Discord webhook URL from check-backup.ps1
- Updated .gitignore with comprehensive secret patterns
- Created .env.example template for secure configuration
- All secrets now loaded from .env file
- Added security incident documentation

Ref: Discord Security Alert - Token exposure detected"

# Push to GitHub
git push origin main
```

### Step 6: Rebuild Docker Containers (2 minutes)
```powershell
# Stop all containers
docker-compose down

# Rebuild with new environment variables
docker-compose up -d --build

# Check logs
docker-compose logs discord-bot --tail=50
```

### Step 7: Verify Everything Works (5 minutes)
```
1. Check Discord bot is online
2. Send a test message in Discord: "!status"
3. Bot should respond (it now uses the new token from .env)
4. Test backup webhook:
   .\check-backup.ps1 -NotifyOnSuccess
5. Check webhook fires in Discord channel
```

---

## 📋 Quick Checklist

Copy this and check off as you complete:

```
[ ] Step 1: Got new Discord bot token
[ ] Step 2: Revoked old webhook, created new one
[ ] Step 3: Created .env file with new credentials
[ ] Step 4: Cleaned Git history (ran clean-git-history.ps1)
[ ] Step 5: Committed security fixes to Git
[ ] Step 6: Rebuilt Docker containers
[ ] Step 7: Tested bot and webhook
[ ] Bonus: Verified GitHub repo (no secrets visible in files)
[ ] Bonus: Deleted passwords.txt and clean-git-history.ps1 (no longer needed)
```

---

## ⏱️ Total Time Required: ~25-35 minutes

---

## 🆘 If You Get Stuck

**Bot won't start?**
- Check .env file exists and has DISCORD_BOT_TOKEN
- Run: `docker-compose logs discord-bot`
- Verify token is valid (test at Discord Developer Portal)

**Webhook not working?**
- Check .env has BACKUP_WEBHOOK_URL
- Test manually: `Invoke-RestMethod -Method Post -Uri $env:BACKUP_WEBHOOK_URL -ContentType "application/json" -Body '{"content":"test"}' | ConvertTo-Json`

**Git history cleanup failed?**
- Use the nuclear option (creates fresh history)
- This destroys all commit history but ensures secrets are gone

---

## 🛡️ Prevent This in the Future

1. **Never commit .env files** (already in .gitignore)
2. **Always use environment variables** for secrets
3. **Enable GitHub secret scanning**:
   - Go to: https://github.com/Z0mb13V1/mindcraft-0.1.3/settings/security_analysis
   - Enable "Secret scanning"
4. **Consider pre-commit hooks**:
   ```powershell
   npm install -D @commitlint/cli husky
   npx husky init
   ```

---

## 📞 Resources

- Read full details: [SECURITY-INCIDENT-REPORT.md](SECURITY-INCIDENT-REPORT.md)
- Discord Developer Portal: https://discord.com/developers/applications/1475823096467423311
- GitHub Secret Scanning Docs: https://docs.github.com/en/code-security/secret-scanning

---

**Next**: Start with Step 1 above ☝️
