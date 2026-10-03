# Developer Procedures

This document is the working agreement for contributors who create issues, open pull requests, and publish updates for AI Usage Overlay.

## Repository Basics

- Default branch: `master`
- Primary app entry point: `unified-overlay.ps1`
- Shared modules: `src/*.ps1`
- Tests: `tests/*.Tests.ps1`
- Installer: `packaging/inno/AIUsageOverlay.iss`
- Release workflow: `.github/workflows/release-installer.yml`

Keep runtime files out of commits. Files such as `unified-overlay-state.json`, `overlay-history.json`, `stats-cache.json`, `codex-cache.json`, `*.log`, `*.pid`, and generated installer artifacts are local state.

## Local Setup

Clone the repo, then run the test suite before making changes:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests"
```

To run the overlay from a checkout:

```powershell
pwsh -STA -NoLogo -NoProfile -File .\unified-overlay.ps1
```

To build the installer locally, install Inno Setup 6 and run:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-installer.ps1 -Version 0.1.2
```

## Creating Issues

Create an issue before starting non-trivial work. Small typo fixes can go straight to a PR, but bugs, UI behavior changes, provider integrations, update behavior, and packaging changes should have an issue.

Use this structure:

```md
## Summary
One or two sentences describing the change or problem.

## Why
The user impact, reliability risk, or maintenance reason.

## Steps to reproduce
For bugs only. Include exact menu clicks, command lines, account/provider state, and Windows setup when relevant.

## Expected behavior
What should happen.

## Actual behavior
What happens now.

## Suggested approach
Optional. Point to likely files or tradeoffs without over-prescribing the implementation.

## Acceptance criteria
- Concrete, testable result
- User-facing behavior or failure mode covered
- Tests or manual verification path identified
```

Label issues by area when possible:

- `ui` for overlay, tray, menu, alerts, and user-facing behavior
- `claude`, `cursor`, or `codex` for provider-specific work
- `reliability` for polling, async jobs, backoff, file watchers, and resilience
- `packaging` for installer, autostart, updater, and release workflow
- `cli` for command-line or JSON output
- `architecture` for migration or cross-module design work

Priority labels should mean scheduling pressure, not issue size:

- `high priority`: important to prioritize soon
- `medium priority`: useful after high-priority work
- `low priority`: exploratory or nice-to-have

## Branches

Use short-lived branches for normal development:

```powershell
git checkout master
git pull --ff-only origin master
git checkout -b codex/short-description
```

Use a concise branch name tied to the issue or behavior, for example:

- `codex/claude-account-identity`
- `codex/snap-corner-positioning`
- `codex/update-verification-docs`

Do not commit unrelated local runtime files. Check before staging:

```powershell
git status --short
```

## Implementing Changes

Keep changes scoped to the issue. Prefer the existing module boundaries:

- Claude live usage, profile, and transcript aggregation: `src/Data.ps1`
- Codex session parsing: `src/CodexData.ps1`
- Cursor local/API reads: `src/CursorData.ps1`
- Unified WPF shell and rendering: `src/Shell.ps1`
- Unified tray/menu behavior: `src/UnifiedTray.ps1`
- Unified state, positioning, and clipboard output: `src/UnifiedState.ps1`
- Installer/update behavior: `src/Update.ps1`, `packaging/`, `.github/workflows/`

Add focused tests when the behavior can be exercised without launching the full WPF app. For UI changes, combine parser/XAML checks with manual verification notes.

Useful validation commands:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests"
pwsh -NoLogo -NoProfile -Command 'Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml; . .\src\Shell.ps1; [void][System.Windows.Markup.XamlReader]::Parse($xaml); "xaml ok"'
git diff --check
```

## Opening Pull Requests

Push the branch:

```powershell
git push -u origin codex/short-description
```

Open a PR against `master`. The PR description should include:

```md
## Summary
- What changed
- Any user-facing behavior

## Issues
Closes #123

## Verification
- `Invoke-Pester -Path tests`
- Manual UI/installer check, if applicable

## Notes
Known limitations, follow-up work, or release implications.
```

For UI changes, include the exact manual checks performed. For packaging or updater changes, include whether the local installer was built and whether the GitHub release workflow needs to be exercised.

## Reviewing Pull Requests

Review for:

- Behavior matching the issue acceptance criteria
- Tests covering parser, state, and failure-path behavior where practical
- No accidental runtime data or generated artifacts
- No unrelated refactors
- Windows PowerShell 5.1 compatibility unless the change intentionally requires PowerShell 7
- WPF/XAML parsing still succeeds after shell edits
- Installer/update changes preserving user state and autostart behavior

Before merge, the PR should pass:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests"
git diff --check
```

## Pushing Updates

Use this procedure when publishing a new app update for users.

1. Make sure `master` is clean and up to date:

```powershell
git checkout master
git pull --ff-only origin master
git status --short
```

2. Pick the next semantic version. Patch releases are appropriate for fixes and small user-facing improvements. Minor releases are for larger features. Current releases use tags like `v0.1.2`.

3. Update the fallback version in `src/Config.ps1`:

```powershell
$script:AppVersion = '0.1.3'
```

The installer workflow also writes `app-version.txt`, but the source fallback should still match the release.

4. Run verification:

```powershell
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path tests"
pwsh -NoLogo -NoProfile -Command 'Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml; . .\src\Shell.ps1; [void][System.Windows.Markup.XamlReader]::Parse($xaml); "xaml ok"'
git diff --check
```

5. Commit and push:

```powershell
git add README.md docs packaging src tests unified-overlay.ps1
git commit -m "Describe the release change"
git push origin master
```

6. Push `master`. That push is the release. The `Release Installer` workflow builds `AIUsageOverlaySetup.exe` from the commit and publishes it as the latest GitHub release, stamped with `Revision: <sha>`.

The first publish of a version uses the tag `v{AppVersion}`. A later `master` commit with the same version uses `v{AppVersion}.{run}` so already-installed copies still see a newer release. Do not create that tag by hand.

7. Confirm the release workflow:

```powershell
gh run list --repo CosmonautJones/ai-usage-overlays --workflow "Release Installer" --limit 5
gh release view --repo CosmonautJones/ai-usage-overlays --json tagName,url,assets
```

The release is not complete until `AIUsageOverlaySetup.exe` is attached and the release notes contain `Revision:` plus the `master` commit SHA.

8. Close shipped issues with a short release note comment:

```md
Shipped in v0.1.3.

Summary of what changed.

Verification: `Invoke-Pester -Path tests` passed.
```

## Updater Verification

For changes that touch `src/Update.ps1`, installer hooks, release workflow, app versioning, or autostart behavior, run or document this manual procedure:

1. Install an older release with `AIUsageOverlaySetup.exe`.
2. Launch the overlay.
3. Push a newer commit to `master` and wait until its release contains `AIUsageOverlaySetup.exe`.
4. Use **Check for updates** from the tray menu.
5. Confirm **Install update** becomes enabled.
6. Choose **Install update** and wait for setup to finish.
7. Confirm the old overlay process exits and a new one starts.
8. Confirm the Startup shortcut still launches `Start-Unified.vbs`.
9. Confirm `app-version.txt` contains the new version and `app-revision.txt` contains the new master SHA.
10. Confirm local state/cache/history files are preserved.

## Release Notes Template

Use concise user-facing release notes:

```md
## What's Changed

- Fixed ...
- Added ...
- Improved ...

## Verification

- `Invoke-Pester -Path tests` passed.
- Installer workflow completed successfully.
```

