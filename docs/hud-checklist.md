# HUD Overlay Verification Checklist

The HUD overlay is built into `src/mindcraft/public/index.html` and displays real-time bot status via socket.io.

## Visual Elements to Verify

Open: `http://<host>:8080/`

- [ ] **Runtime badge** — Top-right corner shows MM:SS uptime counter, updates every second
- [ ] **Agent cards** — One card per bot (CloudGrok, LocalAndy) with:
  - Bot name and status indicator (green dot = connected)
  - Current task/goal text
  - Last action command
  - Viewer camera link (port 3000, 3001, etc.)
- [ ] **Command log** — Scrollable panel showing recent bot commands (max 100 entries)
- [ ] **Dark theme** — Background #1a1a1a, cards #2d2d2d/#363636
- [ ] **Responsive layout** — Cards stack vertically on narrow screens

## Socket.io Events

The HUD listens for these events from MindServer:

| Event            | Data                      | HUD Action                        |
|------------------|---------------------------|-----------------------------------|
| `agents-update`  | Array of agent objects    | Refresh all agent cards           |
| `chat`           | `{agentName, message}`    | Append to command log             |
| `connect`        | -                         | Show "Connected" status           |
| `disconnect`     | -                         | Show "Disconnected" warning       |

## Functional Tests

1. **Load page** → Should show "Mindcraft" header and agent cards within 5s
2. **Bot joins Minecraft** → Agent card should appear/update automatically
3. **Bot runs command** → Command log should update in real time
4. **Refresh page** → Runtime badge resets, agent state reloads
5. **Kill a bot** → Agent card should show disconnected state
6. **Viewer links** → Click camera link → opens prismarine-viewer in iframe/tab

## Prismarine-Viewer Patch

The patch at `patches/prismarine-viewer+1.33.0.patch` suppresses `Unknown entity` errors that spam the console. Without it, the viewer throws on custom/modded entities.

To verify the patch is applied:
```bash
# Inside the mindcraft-agents container:
docker exec mindcraft-agents grep -l "Unknown entity" node_modules/prismarine-viewer/ 2>/dev/null
# Should return nothing if patch is applied (the error log line is removed)
```

## Common Issues

- **Blank page:** Check that mindcraft-agents container is running and port 8080 is exposed
- **No agents showing:** Bots haven't connected to Minecraft yet — wait for server health check
- **Stale data:** Hard-refresh (Ctrl+Shift+R) to clear socket.io cache
- **Camera not loading:** Check prismarine-viewer ports (3000-3003) are mapped in docker-compose
