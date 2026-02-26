# Changelog

All notable changes to this project will be documented here.

---

## [Unreleased]

> **Workflow:** Add entries here as changes are made.
> When committing, move entries to a new versioned
> section `[0.1.3-local.N] - YYYY-MM-DD` and bump
> the patch number.

### Added

- **HUD Overlay** — gaming-style dashboard in the
  MindServer web UI with per-bot runtime tracker
  (MM:SS), current goal / next action display with
  self-prompter state badges (Active/Paused/Stopped),
  and scrollable color-coded command log (`0913c223`)
- `full_state.js`: exposes `selfPrompter` (prompt +
  state) and `action.resumeName` in 1Hz state payload
- `mindserver.js`: tracks `loginTime` per agent for
  accurate runtime calculation across browser refreshes
- `rig-go.ps1` — one-command launcher for the full
  hybrid rig (server, bots, Discord, monitoring)
  (`bfbbc03d`)
- **GitHub Wiki** — 10 pages: Architecture,
  Ensemble Bot, Security, Compute Modes, Bot
  Configuration, Bot Commands, Discord Bot,
  CI/CD Pipeline, Setup & Installation,
  Troubleshooting

### Changed

- Deep audit fixes across code, config, Docker,
  and cleanup — 10 priorities resolved (`e5cf8b7a`)
- Repo cleanup: removed 6 unnecessary tracked files
  (stale scripts, temp artifacts) (`67161dcd`)
- Security section added to README with 7 hardening
  bullet points (`4625b6c4`)

### Fixed

- Viewer iframe used hardcoded `localhost` — now
  uses `window.location.hostname` so viewers load
  from any browser client (`153ada27`)
- Dockerfile: `patches/` dir not copied before
  `npm install` — `patch-package` postinstall
  couldn't apply prismarine-viewer entity fix,
  causing `Unknown entity` log spam (`ed8a8594`)
- Xvfb timing race: added 2s delay before node
  startup so WebGL context initializes correctly
  (`742b5551`)
- `grok.js`: null guard on `res` before `.replace()`
  — API can return null, causing TypeError crash
- `gemini.js` `sendVisionRequest`: used
  `generationConfig:` (old v0.x SDK field) instead
  of `config:` (v1.x SDK) — now matches `sendRequest`
- `discord-bot.js` HELP_TEXT: hardcoded old agent
  name `gemini:` updated to `Gemini_1:`
- `AVAILABLE-MODELS.md`: stale profile names and
  wrong Grok model (`grok-beta` → `grok-code-fast-1`)
- Resolved all markdownlint and PSScriptAnalyzer
  warnings across README, wiki, and PowerShell
  scripts (`1aee8110`)

---

## [0.1.3-local.3] - 2026-02-24

### Added

- `Grok_1` bot profile (`grok-code-fast-1` via xAI Cloud API)
- `Grok_1` added to active profiles in `settings.js`
- `gemini-embedding-001` embedding model on all
  three profiles (Gemini_1, Gemini_2, Grok_1)
- Identity facts block in each bot's conversing
  prompt (name, model, provider, compute type)
- `init_message` now requests name + model + compute type on spawn
- Discord bot now tracks all three agents (Gemini_1, Gemini_2, Grok_1)

### Changed

- Bot names renamed: `gemini` → `Gemini_1`,
  `gemini2` → `Gemini_2`, `Grok` → `Grok_1`
  - Underscores used (Minecraft requires alphanumeric + underscore only)
- Embedding model changed from `text-embedding-004` → `gemini-embedding-001`
  - `text-embedding-004` not available in `v1beta` API endpoint
- Grok profile model: `grok-3-mini-latest` →
  `grok-code-fast-1` (256K context, code specialist)
- Grok embedding: `"openai"` → `google/gemini-embedding-001`
- All bot conversing prompts updated to reference
  new names (Gemini_1/Gemini_2/Grok_1)

### Fixed

- `gemini.js` `embed()` return value:
  `result.embeddings` →
  `result?.embedding?.values ?? result?.embeddings`
  - `@google/genai` v1.x SDK returns
    `result.embedding.values`, not `result.embeddings`
- `skill_library.js` catch block now logs the actual error message (was silent)
- Grok conversing prompt: prevented code block
  output for conversational replies

---

## [0.1.3-local.2] - 2026-02-24

### Added

- `.env` system for all secrets
  (DISCORD_BOT_TOKEN, BACKUP_WEBHOOK_URL, etc.)
- `.env.example` template for new environments
- `AVAILABLE-MODELS.md` — reference for all Gemini and Grok model options
- `SECURITY-INCIDENT-REPORT.md` — full technical incident documentation
- `SECURITY-SUMMARY.txt` — quick reference security status
- `COMPLETION-STATUS.txt` — session completion tracking
- `ACTION-ITEMS.md` — step-by-step remediation guide

### Changed

- Container renamed: `minecraft-pc` → `minecraft-server`
- Container named explicitly: `mindcraft-agents` (was auto-named)
- `settings.js` host: `192.168.0.30` → `minecraft-server` (Docker network name)
- `settings.js` `allow_vision`: `true` → `false` (WebGL unavailable in Docker)
- `docker-compose.yml`: all secrets replaced with `${ENV_VAR}` references
- `check-backup.ps1`: moved `$env:USERPROFILE` and
  `$env:BACKUP_WEBHOOK_URL` out of `param()` defaults
  (PowerShell can't eval env vars at parse time)
- `start-gaming.ps1`: updated container name references to `minecraft-server`
- `.env.example`: updated `MINDSERVER_HOST` to `mindcraft-agents`
- Gemini profiles updated: `gemini-2.5-pro` + `text-embedding-004` embedding

### Fixed

- `bot-test.js`: removed hardcoded Discord bot token
- `discord-bot.js.bak`: removed hardcoded Discord bot token
- `server.properties`: `online-mode=false`
  (required for Mineflayer offline bot auth)

### Security

- **INCIDENT**: Discord scanner detected exposed
  credentials in public GitHub repo
- Discord bot token rotated (old token invalidated by Discord)
- Discord webhook URL revoked and regenerated
- Git history purged via orphan branch (nuclear option) — commit `4837479e`
- All secrets migrated to `.env` (gitignored)

---

## [0.1.3] - 2026-02-24 (Upstream baseline)

- Initial Mindcraft 0.1.3 release
- Base Minecraft AI bot framework
- Multi-agent support via profiles
- MindServer UI on port 8080
- Discord bot bridge
- Docker Compose stack

---

## Version Scheme

`[upstream].[local-major].[local-patch]`

- **upstream** — Mindcraft release version (0.1.3)
- **local-major** — breaking config or architecture changes
- **local-patch** — bug fixes, profile updates, minor additions
