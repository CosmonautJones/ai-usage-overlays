# AI Usage Overlay

Always-on-top Windows HUD for **Claude Code**, **Codex**, **Cursor**, and **Grok** - live quotas, local totals, and history sparks in one tray app.

![Unified overlay preview](docs/preview.png)

Built as a TravOS portfolio piece. Each provider is an independent adapter: one missing login does not take the others down.

## What it shows

| Provider | Live | Local / extra |
| --- | --- | --- |
| **Claude Code** | 5-hour, weekly, optional Fable/Opus windows | Identity, estimated cost, tokens, sessions |
| **Codex** | Weekly % + reset credits; **5-hour % when ChatGPT returns it** | Tokens, cost, today / after-hours, lifetime sessions |
| **Cursor** | **Cursor Models** % and plan used/limit from Plan & Usage, **Other Models** %, On-demand Off/$ | 30-day / today edits, top model, AI lines when analytics returns them (otherwise `--`) |
| **Grok** | SuperGrok / CLI weekly % and reset time | Plan / prepaid only if xAI sends them |

Optional **history sparks** sit under each real bar (Claude, Codex, Grok, Cursor Models). They record on every poll, including when Claude is signed out. The Cursor spark is plan utilization from usage-summary when that series exists (limit > 0 / a real %); it does not invent points from the legacy included-requests fields.

Hide Claude from the tray (**Show/Hide → Claude**) and the top chrome stays quiet: no **Auth expired** / **Not logged in** in the header, and the status dot is not red from Claude auth alone. Turn Claude back on for the previous chrome behavior.

Grok Bot chat and Cursor-Grok are **not** a fifth tile - they stay under Cursor so nothing is double-counted.

## Install

Windows 10/11, PowerShell 5.1 or 7+.

```powershell
irm https://raw.githubusercontent.com/CosmonautJones/ai-usage-overlays/master/install.ps1 | iex
```

That installs under `%LOCALAPPDATA%\AIUsageOverlay` and starts the unified overlay.

Or clone and run `Install.bat`. Login autostart uses `Start-Unified.vbs`.

## First login (new users)

The overlay does **not** store passwords. It launches the real CLI so that tool writes its own `auth.json`.

1. Install a provider CLI if you want that tile (optional - skip any you do not use):
   - Claude: [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
   - Codex: ChatGPT Codex CLI
   - Grok: `irm https://x.ai/cli/install.ps1 | iex` then restart the overlay
   - Cursor: sign in to Cursor IDE
2. Right-click the **AI** tray icon → **Log in** → Claude / Codex / Grok.
3. Finish the browser / device prompt in the visible terminal. The HUD stays up and refreshes that provider when the CLI exits.

Missing CLIs show as disabled (`grok not installed`) instead of crashing. Grok also resolves `~\.grok\bin\grok.exe` when it is installed but not on PATH.

## Your own mark

Footer defaults to the TravOS slab-T. Drop a PNG at:

`%LOCALAPPDATA%\AIUsageOverlay\brand.png`

Restart the overlay. If that file is present, it is the footer mark (keep it small - tray-sized). No file = TravOS.

## Usage

| Action | How |
| --- | --- |
| Show / hide overlay | Left-click the **AI** tray icon |
| Log in a provider | Right-click → Log in |
| Show / hide a section | Right-click → Show/Hide provider |
| Expand / collapse | Click the section header |
| History sparks | Right-click → Show history graph |
| Refresh now | Right-click → Refresh now |
| JSON snapshot | `pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json` |
| One provider | `pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json -Provider Grok` |
| Theme / opacity / snap | Right-click menu |
| Start at login / start hidden | Right-click menu |
| Updates | Right-click → Check for updates |

Position, theme, opacity, graph, and visible sections persist.

## How it works

PowerShell + WPF. Reads credentials you already have - it does not mint tokens.

- Claude quota: Anthropic OAuth usage, token under `~\.claude`
- Claude stats: JSONL under `~\.claude\projects`
- Codex live: `chatgpt.com/backend-api/wham/usage` via local Codex OAuth
- Codex stats: `~\.codex\sessions`
- Cursor: local auth DB + dashboard APIs (`usage-summary` for Plan & Usage; `sqlite3.exe` is bundled)
- Grok: `cli-chat-proxy.grok.com/v1/billing` via `~\.grok\auth.json` (OIDC `key`)

No admin rights. Snapshot schema stays `ai-usage.snapshot.v1` with a `providers` envelope (`claude`, `codex`, `cursor`, `grok`).

## Uninstall

**Settings → Apps → AI Usage Overlay**, or `Uninstall.bat` from `%LOCALAPPDATA%\AIUsageOverlay`.

## Development

See [docs/developer-procedures.md](docs/developer-procedures.md).

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests"
```

Default branch is `master`. Short-lived feature branches, PRs, personal account only ([CosmonautJones/ai-usage-overlays](https://github.com/CosmonautJones/ai-usage-overlays)).
