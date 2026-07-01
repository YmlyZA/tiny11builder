# tiny11 builders - CI workflow - design

- **Date:** 2026-07-01
- **Status:** Approved (pending written-spec review)
- **Scope target:** new `.github/workflows/ci.yml` + a README status badge
- **Branch:** `harden/core-error-handling` (same fork branch as prior work)

## Context

The project has a real static-gate harness in `scripts/` - `parse-check.ps1`,
`linter.ps1` (PSScriptAnalyzer), and `test-core-helpers.ps1` (78 unit tests,
including cross-script parity checks that fail if `tiny11Coremaker.ps1` and
`tiny11maker.ps1` drift). Today these run only when someone runs them by hand.
The user builds across many machines and wants the gates enforced automatically
so regressions - especially Core<->maker drift and accidental PowerShell 7-only
syntax - are caught on every change without manual effort.

## Goal

Run the three existing gate scripts automatically on every push and pull request,
under the project's real target runtime (Windows PowerShell 5.1), and surface a
pass/fail badge in the README.

## Key decision: runner and runtime

Run on **`windows-latest`** with every gate step using **`shell: powershell`**
(Windows PowerShell 5.1 - the Desktop edition preinstalled on the runner), NOT
`shell: pwsh` (PowerShell 7). Rationale: the project's binding constraint is
5.1 compatibility (`#requires -Version 5.1`, no PS7-isms). A Linux+pwsh7 job
would pass syntax that fails on 5.1, defeating the point. Running under actual
5.1 makes CI catch PS7-isms and validates the helpers on the target runtime.
No second (ubuntu/pwsh7) job - pwsh7 compatibility is not a project goal, so it
would add cost and noise without value.

## Design

### Workflow file: `.github/workflows/ci.yml`

- **Name:** `CI`
- **Triggers:**
  - `push` to branches `main` and `harden/**`
  - `pull_request` targeting `main`
- **Single job `gates`**, `runs-on: windows-latest`, steps in order (each
  `shell: powershell` unless noted):
  1. `actions/checkout@v4` (default step, no shell).
  2. **Install PSScriptAnalyzer** - deterministic, non-interactive:
     `Set-PSRepository PSGallery -InstallationPolicy Trusted` then
     `Install-Module PSScriptAnalyzer -Scope CurrentUser -Force`. Pre-installing
     it here means `linter.ps1`'s own auto-install branch is skipped and the
     lint step is hermetic.
  3. **Parse check:** `.\scripts\parse-check.ps1`
  4. **Lint:** `.\scripts\linter.ps1`
  5. **Unit tests:** `.\scripts\test-core-helpers.ps1`

Each gate script already `exit 1`s on failure; the `powershell` shell propagates
a non-zero exit as a failed step, so a failure stops the job and shows in the UI.
Three separate steps (not one combined) so the failing gate is obvious at a
glance.

### README badge

Add a GitHub Actions status badge near the top of `README.md`:

```
[![CI](https://github.com/YmlyZA/tiny11builder/actions/workflows/ci.yml/badge.svg)](https://github.com/YmlyZA/tiny11builder/actions/workflows/ci.yml)
```

The badge points at the fork (`YmlyZA/tiny11builder`) where the workflow runs.

## Non-goals

- No ubuntu / PowerShell 7 job (5.1 is the only target that matters here).
- No real image build in CI (DISM offline servicing needs Windows admin + a
  multi-GB image + ~30 min; the unit tests cover the pure logic, and real builds
  are validated by the user on Windows).
- No caching, matrix, or release automation - one job, three gates.
- No change to the three gate scripts themselves (the workflow calls them as-is).

## Testing strategy

- **YAML validity:** the workflow is small and declarative; validate its shape
  with any available YAML/actionlint check, and by confirming every referenced
  script path exists and every step's runtime is `shell: powershell`.
- **Real proof:** after the branch is pushed, the workflow runs on the fork; a
  green `gates` job (parse [OK] both, linter 0 both, tests 78/0) is the
  acceptance signal. A deliberately-broken probe (e.g. a temporary PS7 ternary)
  is NOT part of this scope but would be the way to confirm the gate actually
  fails - left to the user if desired.
- The three gate scripts are already known-green locally, so a green first run
  confirms the workflow wiring, not the scripts.

## Sequencing

1. Add `.github/workflows/ci.yml`.
2. Add the README badge.

All work continues on `harden/core-error-handling`.
