# Portfolio assessment: AI Usage Overlay

Reviewed September 9, 2026. This is an assessment and recommended scope, not a claim that the proposed work is complete. Audience: engineers evaluating an experienced software developer's public work.

## Recommendation

Use this as a focused developer-tool case study. It already demonstrates useful product execution, Windows integration, heterogeneous data sources, background processing, and regression testing. It is a credible supporting project for an experienced engineer. It does not, by itself, demonstrate the breadth of enterprise application development or an agent orchestration platform.

The fastest improvement is to make the existing engineering visible and make the public installation match the verified app. More providers, a new backend, and a language rewrite are lower priority.

Editorial assessment: B for the implemented utility; C+ for how clearly the public repository currently communicates senior-level engineering judgment. These are qualitative judgments, not standardized scores or hiring predictions.

## Evidence actually available

| Evidence | What it demonstrates | Limit |
| --- | --- | --- |
| Separate Claude, Codex, Cursor, and Grok modules | Integrating different authentication, storage, and usage semantics | Shared script state and inconsistent metric semantics remain |
| Background refresh jobs and watchdog tests | Keeping external work out of the WPF interaction path; recovering hung jobs | Some provider requests share a worker; stale state still needs work |
| WPF panel, WinForms tray, settings, first-run picker | A usable Windows utility beyond a command-line proof of concept | Onboarding still depends on provider accounts |
| Published v0.4.0 EXE and release workflow | Packaging and distribution exist | Clean-install/update lifecycle was not verified in this review; current release predates the menu correction |
| Commit dd47c282f19cfe533b4038a706d871b64e885ba1 | A reproducible DPI defect corrected at startup | The commit is on an open PR, not the default branch |
| 257 passing tests on the exact committed snapshot; successful GitHub Pester job | Reproducible regression checks for the published branch | Test count is not coverage, independent review, or correctness certification |
| User confirmation after the installed menu fix | The reported live UI problem was resolved | Does not prove all Windows configurations |

Sources: [repository](https://github.com/CosmonautJones/ai-usage-overlays), [PR 18](https://github.com/CosmonautJones/ai-usage-overlays/pull/18), [CI for the menu commit](https://github.com/CosmonautJones/ai-usage-overlays/actions/runs/34408270594), and [v0.4.0 release](https://github.com/CosmonautJones/ai-usage-overlays/releases/tag/v0.4.0). Local code reviewed includes the entry point, provider adapters, refresh/watchdog logic, updater, tests, developer procedures, migration proposal, and preview image.

## What weakens the impression

1. **The README describes controls before engineering decisions.** The opening identifies it as a portfolio piece rather than explaining the user's problem. Installation and setting details dominate. An evaluator must inspect the code to discover the stronger design work.
2. **The hero is oversized and out of date.** `docs/preview.png` is a tall desktop crop with background clutter and earlier styling. It consumes substantial reading space and does not explain a workflow. A clean current view and short demonstration would communicate more.
3. **The public delivery state is fragmented.** `master` remains at e421c823e0bcb75e9323da6b9e761f6350bde0f2. The menu fix and CI are on PR 18. Broader hardening and other features are still local. A reader using the default install command does not receive all the code discussed in this session.
4. **Data claims need clearer boundaries.** Local transcript totals, provider-reported quota, and estimated API-equivalent cost are different measurements. The screenshot's large token and cost totals should not be presented as productivity, billed spend, or complete account history.
5. **Tracking AI usage does not itself demonstrate an AI system.** The portfolio should distinguish this developer tool, its AI-assisted development process, and any separate agent-system project. Do not imply that the overlay performs orchestration or inference.
6. **Release trust needs work.** The updater downloads and executes the release EXE without digest or publisher-signature verification. The release workflow builds and attaches an installer without a test step. Fixing and testing the delivery path would be stronger evidence than adding visual polish alone.

## Smallest strong portfolio package

### First: make the existing work easy to evaluate

- Rewrite the README opening around the problem, intended user, current screenshot, and one clear installation path. Put detailed settings below the engineering overview or in usage documentation.
- Add a short engineering case study with a data-flow diagram, three actual decisions and tradeoffs, known limits, verification links, and explicit AI collaboration attribution.
- Use the DPI incident as the concrete debugging example: the first coordinate-only fix failed; user feedback triggered instrumentation; a fresh process reproduced double scaling; initializing WPF before WinForms corrected native window coordinates; regression tests and user confirmation closed the issue. Do not rewrite this as first-try success.
- Link CI and a specific tested commit. Keep local-only work labeled until it lands.

### Second: close the release gap

- Review and integrate the existing PR through the repository's normal process, then verify CI on the resulting default-branch commit. Merging is a separate action from this assessment.
- Review the local hardening changes as their own scope. Do not bulk-commit the remaining dirty tree as portfolio polish.
- Build a release from the tested commit and verify installation, launch, exit, relaunch, settings preservation, and uninstall in a clean Windows environment before calling the installation experience verified.
- Publish the new release only after the exact artifact has been checked. No new release was created during this assessment.

### Third: let an evaluator try it without accounts

Add one clearly labeled demo mode, using synthetic fixtures through the existing render path. Include healthy quota, a stale provider, and an unavailable provider. It must bypass credential discovery and provider network requests and must never write demo values into real history. This provides a repeatable screenshot/demo and demonstrates failure states without asking a recruiter to authenticate four services.

This is proposed functionality, not implemented behavior. It needs a bounded design before coding.

### Next engineering priority

Make source, freshness, scope, and estimate status explicit for displayed metrics; reject unknown pricing rather than silently implying precise dollars. Then harden artifact verification and the update lifecycle. Avoid claiming accounting-grade accuracy while the gaps in the hardening assessment remain.

## Positioning boundaries

- Show a finished, useful tool and explain why the implementation fits its scope. PowerShell/WPF is a reasonable Windows utility choice; changing languages is not evidence of seniority by itself.
- Describe the work as AI-assisted and be specific about the human direction and validation actually observed. Do not claim sole authorship, autonomous agent reliability, commercial adoption, measured productivity gains, or production scale without evidence.
- Use this project to support claims about integration, debugging, testing, and delivery. Pair it with a separately verified application or systems project for broader architectural evidence; that second project's readiness has not been evaluated here.
- Keep the repository and case study entirely personal-project based. No employer source, internal prompts, customer data, screenshots, or proprietary workflow reconstruction is needed.

## Completion criteria for the recommended pass

A visitor can understand the problem in the opening paragraph, inspect one clean current visual, find an engineering explanation and live test evidence, distinguish reported data from estimates, and reproduce a labeled demo without credentials. The recommended installer must correspond to the tested release. These outcomes matter more than a bigger feature list.
