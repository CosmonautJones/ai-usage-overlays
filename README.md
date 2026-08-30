# AI Usage Overlay

Always-on-top Windows HUD for Claude Code, Codex, and Cursor IDE usage in one tray app.

![Unified overlay preview](docs/preview.png)

## What It Shows

**Claude Code**
- Live 5-hour session and weekly quota usage
- Optional Fable and Opus weekly quota rows when Anthropic returns them
- Extra usage / overage spend when enabled
- Local transcript totals: estimated API-equivalent value, tokens, sessions, and messages

**Codex**
- Local session tokens from `~\.codex\sessions`
- Estimated API-equivalent value
- Session and message counts
- Today's tokens and messages
- 5-hour and weekly Codex rate-limit percentages when present in session logs

**Cursor IDE**
- On-demand spend
- Included request usage with OVER detection
- 30-day agent edits, today's edits, accepted lines, and top model

## Install

This copy lives at [CosmonautJones/ai-usage-overlays](https://github.com/CosmonautJones/ai-usage-overlays).

**PowerShell** — paste this into PowerShell, or hand it to your Claude / Cursor agent:

```powershell
irm https://raw.githubusercontent.com/CosmonautJones/ai-usage-overlays/master/install.ps1 | iex
```

This downloads the repo zip, installs the script app under `%LOCALAPPDATA%\AIUsageOverlay`, and launches the unified overlay automatically.

**Let your AI agent do it** — paste this into Claude Code or Cursor chat:
> Run this in PowerShell to install the AI usage overlay: `irm https://raw.githubusercontent.com/CosmonautJones/ai-usage-overlays/master/install.ps1 | iex`

**Manual developer install** — clone this repo and run `Install.bat`. Login autostart uses `Start-Unified.vbs`.

```powershell
git clone https://github.com/CosmonautJones/ai-usage-overlays.git
```

Installer EXEs from GitHub Releases are optional; use the PowerShell path above if no release asset is published yet on this account.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Claude Code CLI signed in (`claude auth login`)
- Codex installed if you want Codex stats; sessions are read from `~\.codex\sessions`
- Cursor IDE signed in if you want Cursor usage and analytics

Each provider is optional. If one source is unavailable, the overlay keeps showing the other sections.

## Usage

| Action | How |
|---|---|
| Show / hide overlay | Left-click the **AI** tray icon |
| Show / hide Claude, Codex, or Cursor section | Right-click -> Show/Hide provider |
| Expand / collapse a section | Click its section header |
| Refresh usage immediately | Right-click -> Refresh now |
| Print one JSON snapshot | `pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json` |
| Print only one provider | `pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json -Provider Codex` |
| Copy current stats | Right-click -> Copy stats to clipboard |
| Open Claude usage page | Right-click -> Open claude.ai/usage |
| Change theme or opacity | Right-click -> Theme / Opacity |
| Snap to a screen corner | Right-click -> Snap to corner |
| Start at login | Right-click -> Open at login |
| Start hidden | Right-click -> Start hidden to tray |
| Toggle alerts or graph | Right-click -> Threshold alerts / Show history graph |
| Check for app updates | Right-click -> Check for updates |
| Quit | Right-click -> Quit |

The overlay saves its position, opacity, theme, start-hidden setting, graph/alert preferences, and visible provider sections.

### JSON Snapshot Schema

`unified-overlay.ps1 -Json` prints one machine-readable snapshot and exits before any WPF HUD startup. The output contract is versioned with `schema: "ai-usage.snapshot.v1"` and all provider data lives under a normalized `providers` envelope:

```json
{
  "schema": "ai-usage.snapshot.v1",
  "generatedAt": "2026-07-09T12:34:56.0000000-05:00",
  "appVersion": "0.2.2",
  "request": {
    "providers": ["claude", "codex", "cursor"],
    "timeoutSec": {
      "claude": 20,
      "cursor": 20
    }
  },
  "providers": {
    "claude": {
      "selected": true,
      "status": "ok",
      "message": "",
      "lastFetch": "12:34",
      "identity": null,
      "usage": {},
      "stats": {},
      "error": null,
      "statsError": null
    },
    "codex": {
      "selected": true,
      "status": "unavailable",
      "stats": null,
      "error": null
    },
    "cursor": {
      "selected": true,
      "status": "unavailable",
      "message": "Cannot read Cursor token from state.vscdb",
      "lastFetch": "",
      "usage": null,
      "summary": null,
      "local": null,
      "error": null
    }
  }
}
```

Provider status is data, not the process result. Missing or unavailable providers are represented in JSON and do not make snapshot mode fail; providers excluded by a filter are still present with `selected: false` and `status: "skipped"`.

Provider and timeout controls:

```powershell
pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json -Provider Claude,Codex
pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json -ClaudeOnly
pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json -CursorOnly -TimeoutSec 5
pwsh -NoLogo -NoProfile -File .\unified-overlay.ps1 -Json -ClaudeTimeoutSec 3 -CursorTimeoutSec 8
```

`-Provider` accepts `Claude`, `Codex`, and `Cursor`. The `-ClaudeOnly`, `-CodexOnly`, and `-CursorOnly` switches are shortcuts; if any are supplied, they define the selected provider set. `-TimeoutSec` sets the default network timeout for Claude and Cursor. `-ClaudeTimeoutSec` and `-CursorTimeoutSec` override that default for their provider. Timeout values are clamped to 1-120 seconds.

## Uninstall

Use Windows **Settings -> Apps -> Installed apps -> AI Usage Overlay -> Uninstall**, or run **Uninstall AI Usage Overlay** from the Start Menu.

The fallback/manual install can still be removed by running `Uninstall.bat` from `%LOCALAPPDATA%\AIUsageOverlay` or from a cloned repo.

## Features

- **Always on top** - stays visible over other windows
- **Unified providers** - Claude Code, Codex, and Cursor in one process and one tray icon
- **Customizable sections** - hide providers you do not use, and expand/collapse individual sections
- **Fast startup** - cached transcript/session parsing makes warm starts quick
- **Async refresh jobs** - provider data loads in background jobs so the HUD can appear immediately
- **Color themes** - several built-in palettes (including dark studio looks)
- **Drag to reposition** - position is saved between restarts
- **Opacity control** - 100%, 80%, 60%, or 40%
- **Snap to corners** - top-left, top-right, bottom-left, or bottom-right
- **Threshold alerts** - warning and critical notifications for Claude quota thresholds
- **History graph** - optional sparkline for recent Claude quota movement
- **Optional release updates** - check for setup EXE updates from the tray when a release exists

## How It Works

The overlay is a PowerShell/WPF app that reads existing local credentials and usage artifacts:

- Claude live quota comes from Anthropic's OAuth usage endpoint using the Claude Code token stored under `~\.claude`.
- Claude local stats are computed from JSONL transcripts under `~\.claude\projects`.
- Codex stats are computed from JSONL sessions under `~\.codex\sessions`.
- Cursor usage is read from Cursor's local auth database and Cursor dashboard APIs.
- Cursor SQLite reads use the bundled `sqlite3.exe`.

No separate credentials are stored by the overlay, and no elevated permissions are required.

## Runtime Files

The app writes a few local state/cache files next to the scripts:

- `unified-overlay-state.json` - window position and UI preferences
- `overlay-history.json` - recent Claude quota samples for alerts and graphing
- `stats-cache.json` - Claude transcript parse cache
- `codex-cache.json` - Codex session parse cache
- `unified-overlay-error.log` - diagnostic log
- `unified-overlay.pid` - running process id used by uninstall/cleanup

These files are local runtime data and are not required in git.

## Development

Developer workflow documentation lives in [docs/developer-procedures.md](docs/developer-procedures.md). Start there for issue writing, branch/PR flow, release tagging, and update verification.

Run the Pester test suite from the repo root:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests"
```

Build the installer locally with Inno Setup 6 installed:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-installer.ps1
```

The installer artifact is written to `dist\AIUsageOverlaySetup.exe`. Release builds can publish this artifact from the `Release Installer` GitHub Actions workflow.

The default branch is `master`. Current development happens against the unified overlay on `master`. Use short-lived feature branches for normal work and merge through pull requests unless a maintainer is intentionally shipping a small release directly.
