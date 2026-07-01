# CI Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the three existing gate scripts automatically on every push/PR under Windows PowerShell 5.1, and show a CI status badge in the README.

**Architecture:** A single GitHub Actions workflow (`.github/workflows/ci.yml`) with one job on `windows-latest` whose steps invoke `scripts/parse-check.ps1`, `scripts/linter.ps1`, and `scripts/test-core-helpers.ps1` via `shell: powershell` (the runner's Windows PowerShell 5.1). Each gate script already `exit 1`s on failure. Plus a README badge pointing at the fork's workflow.

**Tech Stack:** GitHub Actions, Windows PowerShell 5.1, PSScriptAnalyzer.

## Global Constraints

- **Runner/runtime:** `runs-on: windows-latest`; every gate step uses `shell: powershell` (Windows PowerShell 5.1 Desktop), NOT `shell: pwsh` (PowerShell 7). 5.1 is the project's only target runtime.
- **Do NOT modify** the three gate scripts (`scripts/parse-check.ps1`, `scripts/linter.ps1`, `scripts/test-core-helpers.ps1`) — the workflow calls them as-is.
- **Triggers:** `push` to `main` and `harden/**`; `pull_request` targeting `main`.
- **No ubuntu/pwsh7 job, no matrix, no caching, no real image build in CI.**
- **Badge URL targets the fork:** `YmlyZA/tiny11builder` (where the workflow runs).
- ASCII only.

---

### Task 1: CI workflow + README badge

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md` (insert a badge line just below the top-level `# ...` title)

**Interfaces:**
- Consumes: the three existing scripts under `scripts/` (already present, already `exit 1` on failure). No new code interfaces.
- Produces: a workflow named `CI` with a job `gates`; a README badge referencing `actions/workflows/ci.yml/badge.svg`.

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/ci.yml` with EXACTLY this content:

```yaml
name: CI

on:
  push:
    branches: [main, 'harden/**']
  pull_request:
    branches: [main]

jobs:
  gates:
    runs-on: windows-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install PSScriptAnalyzer
        shell: powershell
        run: |
          Set-PSRepository PSGallery -InstallationPolicy Trusted
          Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

      - name: Parse check (Windows PowerShell 5.1)
        shell: powershell
        run: .\scripts\parse-check.ps1

      - name: Lint (PSScriptAnalyzer)
        shell: powershell
        run: .\scripts\linter.ps1

      - name: Unit tests (helpers + cross-script parity)
        shell: powershell
        run: .\scripts\test-core-helpers.ps1
```

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('yaml ok')"`
Expected: `yaml ok` (no traceback).

- [ ] **Step 3: Confirm every referenced script path exists**

Run: `for f in scripts/parse-check.ps1 scripts/linter.ps1 scripts/test-core-helpers.ps1; do test -f "$f" && echo "ok $f" || echo "MISSING $f"; done`
Expected: three `ok` lines, no `MISSING`.

- [ ] **Step 4: Add the README badge**

In `README.md`, locate the first top-level heading (the line beginning with `# ` at the top of the file). Immediately after that heading line, insert a blank line followed by this exact badge line (then keep a blank line before the existing content):

```
[![CI](https://github.com/YmlyZA/tiny11builder/actions/workflows/ci.yml/badge.svg)](https://github.com/YmlyZA/tiny11builder/actions/workflows/ci.yml)
```

Do not change any other README content.

- [ ] **Step 5: Verify the badge line is present exactly once**

Run: `grep -c 'actions/workflows/ci.yml/badge.svg' README.md`
Expected: `1`

- [ ] **Step 6: Confirm the three gate scripts still pass locally (unchanged)**

These prove the workflow will have green gates to run (they are unmodified, but re-confirm nothing else regressed):
Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both scripts
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: 78 passed, 0 failed`

Note: `scripts/linter.ps1` needs the PSScriptAnalyzer module; run it only if the module is available locally — CI is the authoritative lint run. Do not modify the script.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "ci: run parse/lint/unit gates on windows PS5.1 + README badge"
```

---

## Notes for the executor

- The workflow itself cannot be executed locally; Steps 2-3 validate its shape (YAML well-formed, referenced scripts exist) and Steps 5-6 validate the badge and that the gates are green. The authoritative proof is the first Actions run on the fork after the branch is pushed.
- After the task: final whole-branch review over this increment (base = the spec commit `2f1ae47`), then finishing-a-development-branch. Push/PR/merge uses the `YmlyZA` account (switch before, restore after); after merge, the `CI` workflow's first run can be checked with `gh run list` under the YmlyZA account.
