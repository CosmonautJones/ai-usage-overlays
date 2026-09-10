# Packaging

This folder contains the first-pass Windows installer scaffolding for AI Usage Overlay.

For the full contributor workflow, including issue creation, pull requests, release tags, and update publishing, see [../docs/developer-procedures.md](../docs/developer-procedures.md).

## Current Behavior Captured

- Install target stays per-user at `%LOCALAPPDATA%\AIUsageOverlay`, matching `install.ps1`.
- Install copies the existing PowerShell app files, including `unified-overlay.ps1`, `Start-Unified.vbs`, `sqlite3.exe`, `src\*.ps1`, `README.md`, and `LICENSE`.
- Install verifies Windows PowerShell 5.1 or PowerShell 7+ is available, then runs `unified-overlay.ps1 -Install`.
- `unified-overlay.ps1 -Install` creates or updates the Startup-folder shortcut at `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\AIUsageOverlay.lnk`.
- Startup and Start Menu launches use `wscript.exe Start-Unified.vbs`, which prefers `pwsh` and falls back to Windows PowerShell 5.1 so no separate PowerShell install is required.
- Install and upgrade relaunch behavior is delegated to `unified-overlay.ps1 -Install`, which stops the previous background instance and starts a fresh hidden one.
- Uninstall removes the Startup shortcut by running `unified-overlay.ps1 -Uninstall`, then stops the running overlay by PID and command-line matching.
- Windows Apps & Features uninstall is provided by the Inno Setup uninstall entry.
- GitHub release updates use `AIUsageOverlaySetup.exe` from the latest release asset and hand off to the same installer path.

## Build Locally

Install Inno Setup 6, then run:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-installer.ps1
```

The setup executable is written to `dist\AIUsageOverlaySetup.exe`.

## Update Verification

Before closing update-related release work, verify a published installer handoff end to end:

1. Install an older release with `AIUsageOverlaySetup.exe`.
2. Launch the overlay and confirm the tray menu shows the older app version's update state.
3. Publish or select a newer GitHub release that includes `AIUsageOverlaySetup.exe`.
4. Use **Check for updates** from the tray menu and confirm **Install update** becomes enabled.
5. Choose **Install update** and wait for setup to finish.
6. Confirm the old overlay process exits, a new overlay process starts, the Startup shortcut still points at `Start-Unified.vbs`, and `app-version.txt` contains the newer version.
7. Confirm `unified-overlay-state.json`, `overlay-history.json`, `stats-cache.json`, and `codex-cache.json` are preserved.
