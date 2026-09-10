# Hardening and data reliability assessment

Date: September 9, 2026. Scope: the existing Windows PowerShell/WPF overlay and its four provider adapters. Changes are local and uncommitted; existing unrelated work was preserved. No release, installer replacement, or running-overlay restart was performed.

## Verdict

**B- as a personal usage utility; C for accounting-grade accuracy.** These are engineering judgments, not measured certification scores. The modular adapters, useful tray workflow, regression suite, and Windows compatibility are strengths. Provider access, account boundaries, incomplete local logs, estimated pricing, and release integrity keep this below an A.

**100% accurate and continuously reliable is not established.** A successful HTTP response establishes a provider observation at a moment in time. It does not prove that the provider's source is complete, that the account matches every local transcript, or that an estimated dollar amount equals an invoice.

| Area | Grade after this pass | Evidence and limitation |
| --- | --- | --- |
| Product and structure | B | Useful focused HUD; separate provider modules. Shared script state and duplicated legacy entry points increase maintenance work. No visual redesign or interactive UI audit performed. |
| Data correctness | C | Fixed day/model attribution and false zeroes. Remaining source, deduplication, cache-token, pricing, and account-scope gaps below. |
| Failure handling | B- | Corrected stale status and failed-poll history. Full per-metric freshness, deadlines, and uniform provider backoff remain incomplete. |
| Security and release | C+ | Removed profile-token duplication and unsafe diagnostic echoing. Updater verification and WSL credential handling need further work. |
| Automated verification | B+ | 300 tests pass under both PowerShell 7 and Windows PowerShell 5.1. CI now tests both. Some older tests inspect source strings instead of behavior; no remote CI or installed-app lifecycle proof. |

## Work completed

The baseline was 281 passing tests under PowerShell 7. Targeted regressions then reproduced defects before fixes. The final suite contains 300 tests, with no failures or skips under either supported shell.

1. **Codex day/model attribution:** cumulative token snapshots now yield per-event increments. A session spanning midnight or switching models no longer assigns all tokens to its start day and final model. User messages remain separate from token observations. Native `session_meta.payload.id` is recognized. This corrects the tested monotonic-counter case; it is not proof for forks or counter-reset boundaries.
2. **Codex cache:** bumped the parse-cache version and preserved that version when reloading, so the new representation replaces old session-level records and survives repeated reloads. Codex tests now keep their cache in the test directory rather than the real app directory.
3. **Codex quota:** live fetching works without a sessions directory; explicit `CODEX_HOME` controls the credential path. Only actual 300-minute and 10080-minute windows receive five-hour/weekly labels. Live nulls clear removed windows instead of resurrecting log-derived values.
4. **Cursor refresh:** usage-summary determines refresh health. Failed or unrecognized summary responses clear prior summary values and report stale/auth status. Failed analytics clears prior analytics. Missing numeric fields remain null through the HUD formatter instead of becoming zero.
5. **Cursor parsing:** remaining-percentage prose cannot be mistaken for usage. JWT decoding accepts base64url characters. The English display-message parser remains a compatibility fallback, not a stable public contract.
6. **Claude credential cache:** caches a SHA-256 token fingerprint rather than a reusable bearer token. Existing plaintext cache files migrate on read; this checkout's existing profile cache was migrated and verified to have no `Token` field. The upstream CLI credential store is unchanged.
7. **Provider diagnostics:** Codex/Grok reject unrecognized successful response envelopes. Their request and credential-read failures no longer copy arbitrary exception text into logs or exported messages. This is a scoped fix, not a complete historical-log or repository-secret audit.
8. **Freshness:** JSON keeps Codex/Grok stale status even when local stats exist. History stores null for adapters reporting failed/auth/stale polls instead of treating cached values as new measurements.
9. **Windows compatibility:** fixed encoding-sensitive punctuation that broke PowerShell 5.1 parsing in ProviderPicker and Pace. Added all-primary-script parser coverage and a two-shell CI matrix.
10. **Runtime hygiene:** ignored Claude backoff and credential-preference files.

## Live observations

Checked around 14:11-14:16 America/New_York on September 9. Only selected status/metric fields were displayed; credentials were not printed.

| Provider | Observed result | What was verified |
| --- | --- | --- |
| Codex | 0% weekly used; five-hour value absent | Overlay endpoint reading matched the Codex app's own 0% weekly reading. The app also exposed separate limit buckets, including Spark, which the current overlay does not represent. This was a single-value comparison, not a full account/model reconciliation. |
| Grok | 52% used; reset September 14 at 09:14 local | Authenticated billing endpoint returned parsable fields. No independent dashboard/invoice comparison was performed. |
| Cursor | Stale; no usable summary or analytics | A focused summary retry ended in `TaskCanceledException` with no HTTP response. No evidence establishes an expired login or a parser defect as the cause. |
| Claude | Auth required; no live utilization obtained | Normal credential discovery returned auth status. No forced retry, token refresh, or login was performed. |

## Highest-priority remaining improvements

These remain open. They are reasons to avoid presenting the overlay as an exact financial ledger.

### P1: Establish one trustworthy account/source/freshness contract

`src/CodexData.ps1` aggregates all candidate transcript directories, while live quota comes from one account. `src/Config.ps1` mirrors multiple WSL homes, including Claude credentials. Transcript totals can therefore cover a different scope than the live account; repeated session copies can inflate tokens even though the session count uses a set. Claude tokens exclude cache-read/write tokens from displayed input totals, while Codex input includes cached tokens (`Measure-Stats` versus `Measure-CodexStats`). The same "tokens" label is not currently comparable.

Recommended next change: a provider/metric envelope with account fingerprint, source, observed-at time, time window, unit, coverage, and quality (`reported`, `local`, `estimated`, `partial`, `unavailable`). Explicitly scope accounts; deduplicate copied/forked histories; define total versus uncached input tokens. Show local coverage rather than claiming complete account lifetime usage. Invalidate account-bound cached values on account changes.

### P1: Stop guessing prices and historical attribution

`Estimate-CodexCost` falls back to default/GPT-5.5 pricing for unknown models. `Pricing.ps1` classifies Claude by broad family, with no effective-date price history. Config price tables are dated June 2026. Model prices, cache durations, service tiers, tool charges, and plan allowances cannot be reconstructed reliably from those tables.

Recommended: exact model identifiers with effective dates and explicit unknown-price status. Keep API-equivalent estimates separate from billed spend. Use the provider's billing/usage API for reconciliation. Codex decreasing cumulative counters currently produce a diagnostic and skip that ambiguous boundary; expose partial coverage rather than claiming exact attribution. Test duplicate snapshots, compaction/reset boundaries, archived sessions, truncated files, and forked histories before claiming complete local totals.

### P1: Verify downloaded updates before execution

`src/Update.ps1:188` downloads an asset and `Install-AppUpdate` executes it without a verified digest or publisher signature. The current installer URL is trusted from release metadata. TLS is helpful but is not artifact verification.

Recommended: constrain release owner/repository and asset URL, require a trusted digest/signature policy, verify bytes before execution, and reject missing/mismatched verification. Test the installed app's update/restart/state-preservation flow. No update was downloaded or executed during this pass.

### P2: Complete stale-data handling and polling isolation

The new history guard honors adapter status, but status alone does not prove a fresh observation. A background worker that dies or hangs can leave a prior `ok` state. Add per-source observation times and deadlines at the worker boundary, clear/age data on timeout, and make stale age visible in the HUD and clipboard. Cursor legacy usage, summary, and analytics are still sequential; their combined latency can consume the worker budget. Apply bounded backoff and Retry-After handling consistently across providers.

Use atomic writes and schema versions for runtime caches. WSL's `cp -u` mirror is not an account-aware transaction and does not remove deleted source files. Treat interrupted sync as partial. Keep tokens out of mirrors where a direct CLI-owned read path can replace copying.

### P2: Treat forecasts and labels as estimates

Grok's generic `currentPeriod.end` is labeled weekly without validating its duration. Cursor's "today" analytics bucket is UTC, while local transcript today is the Windows timezone. ETA regression can span a quota reset and stale gaps. Pace has a hardcoded sampler path for a different workstation. Validate period semantics, label timezones, reset forecasts at period boundaries, and make the sampler path configurable before promoting those figures.

## Can every service provide similar stats?

**A common presentation is possible; identical data availability is not.** Keep subscription quota, locally observed work, and billed API usage separate. The provider hosting the request owns its usage: Claude models inside Cursor belong to Cursor's spend, not automatically to a Claude subscription.

| Service | Best-supported route to investigate | Boundary |
| --- | --- | --- |
| Codex | Documented `account/rateLimits/read` through Codex App Server, retaining `rateLimitsByLimitId` | Prefer this over the current private WHAM endpoint. Preserve separate model buckets and actual window durations. Local transcripts are still only local coverage. [Official documentation](https://learn.chatgpt.com/docs/app-server) |
| OpenAI API | Organization Usage and Costs endpoints | Separate API billing from ChatGPT/Codex subscriptions; credentials and organization scope need verification. [API reference](https://developers.openai.com/api/reference/python/resources/admin/subresources/organization/subresources/usage) |
| Claude | Console Usage/Cost Admin API; Enterprise Analytics for the corresponding enterprise product | Official organization reporting exists, with credential/plan requirements. It is not a drop-in personal Claude quota API. The current OAuth quota endpoint remains a compatibility integration. [Official documentation](https://platform.claude.com/docs/en/manage-claude/usage-cost-api) |
| Cursor | Team Admin API usage events and spend | Detailed events can include tokens and charged cents; use the billed field rather than reconstructing costs. Requires applicable team/admin access. This pass did not establish an equivalent supported personal-plan API. [Official documentation](https://prod.cursor.com/docs/account/teams/admin-api) |
| xAI API / Grok | Management billing usage endpoints for an authorized team | API billing is distinct from the current Grok CLI subscription endpoint. No public equivalent of every SuperGrok quota field was established. [Official documentation](https://docs.x.ai/developers/rest-api-reference/management/billing) |
| Gemini, possible future adapter | AI Studio usage and Cloud Billing reporting | Billing can lag; the consumer Gemini subscription is a different product. A callable account-specific integration still needs investigation. [Official documentation](https://ai.google.dev/gemini-api/docs/billing?hl=en) |
| GitHub Copilot, possible future adapter | Official Copilot usage metrics/reporting | Metrics and permissions depend on organization/enterprise access; activity metrics are not interchangeable with billed spend. [Official documentation](https://docs.github.com/en/copilot/concepts/copilot-usage-metrics/copilot-metrics) |

Recommended order: restore Claude/Cursor live access, move Codex to its documented account-limits interface, implement the shared metric contract, then add billing adapters only for accounts with appropriate reporting access. Do not expand the tile count before the existing figures have explicit provenance and coverage.

## Verification and delivery limits

- PowerShell 7: 300 passed, 0 failed, 0 skipped.
- Windows PowerShell 5.1 with Pester 5.7.1: 300 passed, 0 failed, 0 skipped.
- WPF XAML parsed successfully. Primary scripts parse in both tested runtimes.
- CI configuration now includes both shells, but remote CI was not run.
- No installer build, installed-app update test, or visual interaction test was performed.
- CodeRabbit 0.7.5 was available through WSL, but its browser authentication timed out (`authentication_failed`). No CodeRabbit review ran and no CodeRabbit issue count is claimed. To enable it, run `coderabbit auth login` in a user-controlled WSL terminal with the intended personal account.
- Git origin points at a different account than the configured personal project. No issue, commit, push, PR, or release was created.

The implementation plan for this pass was: preserve current work; baseline the suite; trace data sources; reproduce concrete defects; apply narrow fixes; test both Windows shells; record live evidence and remaining limitations. Those steps are complete. The open items above are the next reliability work, not completed capabilities.

## Follow-up: displaced context menu

The first pointer-coordinate change did not resolve the reported gap. Installed-app diagnostics confirmed panel right-clicks reached the expected handler. A fresh-process reproduction isolated the cause: WinForms initialized menu handles while DPI-unaware, then WPF lazily switched the process to system DPI awareness. At 250% scaling, a request for (623, 294) produced native window coordinates (1558, 735).

All three UI entry points now initialize WPF SystemParameters immediately after assembly loading, before creating WinForms controls. The same reproduction then reports native coordinates (623, 294). The regression probe executes each actual bootstrap in a fresh STA process and verifies native menu placement on both connected monitors, opening each menu twice. All three cases failed before the fix and pass afterward. Full PowerShell 7 suite: 305 passed. Windows PowerShell 5.1 placement suite: 5 passed.

The startup fix was also applied to the installed scripts with backups, and the installed unified overlay was restarted. Its bootstrap passes the native placement probe. Temporary event logging was removed; its geometry-only log remains locally for diagnosis. Final user confirmation of the live menu appearance is pending. This follow-up deployed only the menu startup fix, not the broader hardening changes above.
