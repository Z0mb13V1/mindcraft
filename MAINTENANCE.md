# Mindcraft Maintenance Guide

## Regular Cleanup Tasks

### Automated Cleanup Script

Run the cleanup script regularly to remove old logs and temporary files:

```powershell
# Preview what will be deleted (dry run)
.\cleanup.ps1 -DaysToKeep 7 -DryRun

# Actually delete old files
.\cleanup.ps1 -DaysToKeep 7
```

**What gets cleaned:**
- Bot conversation logs (`.txt`, `.log` files)
- Old action code (`.js` files in `action-code/` directories)
- Old conversation histories (`.json` files in `histories/` directories)
- Old screenshots (`.png` files in `screenshots/` directories)
- Temporary files in `tmp/` directory

### Manual Cleanup

**Bot runtime data** (already in `.gitignore`):
- `bots/*/logs/` - Conversation logs
- `bots/*/histories/` - Conversation histories
- `bots/*/action-code/` - Generated action code
- `bots/*/screenshots/` - Vision screenshots
- `bots/*/memory.json` - Bot memory state

**To clean all bot data:**
```powershell
# WARNING: This deletes ALL bot histories and logs
Remove-Item -Recurse -Force bots\*\logs\*, bots\*\histories\*, bots\*\action-code\*, bots\*\screenshots\*
```

## Storage Optimization

### Git LFS Configuration

Large files (>50MB) are configured to use Git LFS:
- `tasks/construction_tasks/*.json`
- `test/construction_tasks/*.json`

**Verify LFS is working:**
```powershell
git lfs ls-files
git lfs status
```

### Ignored Directories

The following directories are automatically ignored by Git (see `.gitignore`):
- `node_modules/` - NPM dependencies (~500MB)
- `bots/**/` - All bot runtime data
- `tmp/` - Temporary files
- `wandb/` - Weights & Biases logs
- `experiments/` - Experiment results
- `server_data*/` - Minecraft server data

## Performance Optimization

### Node.js Dependencies

**Check for outdated packages:**
```powershell
npm outdated
```

**Update dependencies:**
```powershell
# Update minor/patch versions
npm update

# Update all to latest (check for breaking changes first!)
npm install <package>@latest
```

**Audit security vulnerabilities:**
```powershell
npm audit
npm audit fix
```

### Clean npm cache (if having issues):
```powershell
npm cache clean --force
rm -rf node_modules package-lock.json
npm install
```

## Code Quality

### Linting

**Run ESLint:**
```powershell
npx eslint src/
```

**Auto-fix linting issues:**
```powershell
npx eslint src/ --fix
```

### Markdown Linting

All markdown files follow strict linting rules:
- Single H1 heading per document
- Blank lines around headings and code blocks
- No trailing spaces
- Code blocks must specify language
- Descriptive link text (no "click here")

## Monitoring

### Current Project Size

**Check total project size:**
```powershell
Get-ChildItem -Recurse -File | 
    Where-Object { $_.FullName -notlike '*node_modules*' -and $_.FullName -notlike '*.git*' } | 
    Measure-Object -Property Length -Sum | 
    ForEach-Object { "Total: $([math]::Round($_.Sum/1MB,2)) MB" }
```

**Check bot data size:**
```powershell
Get-ChildItem -Path bots -Recurse -File | 
    Measure-Object -Property Length -Sum | 
    ForEach-Object { "Bots: $([math]::Round($_.Sum/1MB,2)) MB" }
```

## Recommended Schedule

- **Daily:** Run cleanup script for logs older than 7 days
- **Weekly:** Check `npm outdated` and update dependencies
- **Monthly:** Run `npm audit` and fix vulnerabilities
- **Quarterly:** Archive old experiment results and bot histories

## Troubleshooting

### Disk Space Issues

1. Run `.\cleanup.ps1 -DaysToKeep 3` for aggressive cleanup
2. Check `node_modules` size - delete and reinstall if bloated
3. Clean Git history with LFS migration for large files
4. Archive old server data: compress `server_data*/` directories

### Build Issues

1. Delete `node_modules` and `package-lock.json`
2. Clear npm cache: `npm cache clean --force`
3. Reinstall: `npm install`
4. Reapply patches: `npm run postinstall`

### Git Issues

If repository size is too large:
1. Use `git lfs migrate` for files >50MB
2. Run `git gc` to garbage collect
3. Consider using `.git/info/exclude` for local ignores

## Best Practices

1. **Never commit bot runtime data** - already ignored in `.gitignore`
2. **Use Git LFS for large files** - configured for construction task JSONs
3. **Clean logs regularly** - use the cleanup script
4. **Keep dependencies updated** - but test thoroughly
5. **Monitor disk usage** - bot logs can grow quickly
