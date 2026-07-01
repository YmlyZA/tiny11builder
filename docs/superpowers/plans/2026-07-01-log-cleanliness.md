# Log Cleanliness / Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A successful build produces a clean log — robust transcript across interrupted reruns, no false red errors from absent optional components, and no dead-pattern WinSxS warnings on arm64.

**Architecture:** Three plumbing changes — (#1) guard the transcript lifecycle, (#2) make optional-component removals silent on absence, (#3) delete dead `arm_` WinSxS allowlist patterns (Core only). No new logic, no new tests.

**Tech Stack:** Windows PowerShell 5.1.

## Global Constraints

- **Target runtime Windows PowerShell 5.1** — `-ErrorAction SilentlyContinue`, `2>$null`, `Stop-Transcript` are all valid on 5.1. No PS7-only syntax.
- **ASCII only.**
- **Parity for #1 and #2:** the transcript guard and the removal guards behave identically in both scripts (allowing Core's `> $null` vs maker's `| Out-Null` idiom). **#3 is Core-only** (maker has no WinSxS allowlist).
- **Only visibility/robustness changes** — do NOT change WHICH components are removed or copied.
- **Do not** add a guard to the structural WinSxS delete (Core L859) or the end-of-run scratchdir cleanup — those are out of scope.
- No new unit tests; the existing 96 must stay green.

---

### Task 1: Core — transcript guard, best-effort removals, WinSxS arm cleanup

**Files:** Modify `tiny11Coremaker.ps1`.

- [ ] **Step 1: (#1) Pre-stop guard before Start-Transcript**

Replace:
```powershell
Start-Transcript -Path "$PSScriptRoot\tiny11.log"
```
with:
```powershell
# Close any transcript leaked by a prior aborted run in this same session,
# so this run always starts its own clean transcript.
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
Start-Transcript -Path "$PSScriptRoot\tiny11.log"
```

- [ ] **Step 2: (#1) Silence the dry-run Stop-Transcript**

In the `if ($DryRun)` block, the bare `Stop-Transcript` sits just before the dry-run's exit logic:
```powershell
    Stop-Transcript
    if ($dryRunFailed) { exit 1 } else { exit 0 }
```
Change only that `Stop-Transcript` to:
```powershell
    Stop-Transcript -ErrorAction SilentlyContinue
    if ($dryRunFailed) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: (#1) Silence the finally Stop-Transcript**

In the `finally { ... }` block, replace:
```powershell
    Dismount-OfflineImage -MountDir "$mainOSDrive\scratchdir"
    Stop-Transcript
}
```
with:
```powershell
    Dismount-OfflineImage -MountDir "$mainOSDrive\scratchdir"
    Stop-Transcript -ErrorAction SilentlyContinue
}
```

- [ ] **Step 4: (#2) Guard the optional-component Remove-Item calls**

Apply these exact edits (append `-ErrorAction SilentlyContinue` immediately before any trailing redirect):

- `Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force > $null`
  → `Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue > $null`
- `Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force > $null`
  → `...\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue > $null`
- `Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force > $null`
  → `...\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue > $null`
- `Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force`
  → append ` -ErrorAction SilentlyContinue`
- `Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -Recurse -Force`
  → append ` -ErrorAction SilentlyContinue`
- `Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" -Force > $null`
  → `...\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue > $null`

- [ ] **Step 5: (#2) Suppress native error stream on the paired takeown/icacls**

Append ` 2>$null` to each of these (Edge-Webview + OneDrive ownership calls):

- `& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r'`
  → append ` 2>$null`
- `& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C'`
  → append ` 2>$null`
- `& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" > $null`
  → `& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" > $null 2>$null`
- `& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' > $null`
  → append ` 2>$null`  (i.e. `... '/C' > $null 2>$null`)

- [ ] **Step 6: (#3) Delete the dead arm_ WinSxS allowlist lines**

In the `elseif ($architecture -eq "arm64")` `$dirsToCopy` block, DELETE these five lines exactly:
```powershell
        "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        "arm_microsoft.windows.common-controls_6595b64144ccf1df_*"
        "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*"
        "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
        "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
```
Leave the `arm64_microsoft.windows.*` twin lines (immediately below them) untouched. Do not add/remove commas from other lines (this array is newline-delimited without trailing commas in the arm64 branch).

- [ ] **Step 7: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11Coremaker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for Core (skip locally if PSScriptAnalyzer absent — CI enforces it)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: 96 passed, 0 failed` (unchanged — no logic touched)

Also confirm the arm_ lines are gone:
Run: `grep -c 'arm_microsoft' tiny11Coremaker.ps1` → `0`

Note: the script body isn't runnable on macOS; these are the gates. Do NOT run the script.

- [ ] **Step 8: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "fix(core): robust transcript + best-effort removals + drop dead arm_ WinSxS patterns"
```

---

### Task 2: maker — transcript guard, best-effort removals

**Files:** Modify `tiny11maker.ps1`. (No WinSxS allowlist in maker, so no #3.)

- [ ] **Step 1: (#1) Pre-stop guard before Start-Transcript**

Replace:
```powershell
Start-Transcript -Path "$PSScriptRoot\tiny11_$(get-date -f yyyyMMdd_HHmms).log"
```
with:
```powershell
# Close any transcript leaked by a prior aborted run in this same session,
# so this run always starts its own clean transcript.
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
Start-Transcript -Path "$PSScriptRoot\tiny11_$(get-date -f yyyyMMdd_HHmms).log"
```

- [ ] **Step 2: (#1) Silence the dry-run Stop-Transcript**

In the `if ($DryRun)` block, change its `Stop-Transcript` to `Stop-Transcript -ErrorAction SilentlyContinue` (leave the surrounding `exit` line as-is).

- [ ] **Step 3: (#1) Silence the end-of-run Stop-Transcript**

Change the final top-level `Stop-Transcript` (the last line region of the script) to `Stop-Transcript -ErrorAction SilentlyContinue`.

- [ ] **Step 4: (#2) Guard the optional-component Remove-Item calls**

Append `-ErrorAction SilentlyContinue` immediately before the trailing `| Out-Null` on each:

- `Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force | Out-Null`
  → `...\Edge" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null`
- `Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force | Out-Null`
  → `...\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null`
- `Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force | Out-Null`
  → `...\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null`
- `Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force | Out-Null`
  → `...\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null`
- `Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" -Force | Out-Null`
  → `...\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue | Out-Null`

- [ ] **Step 5: (#2) Suppress native error stream on the paired takeown/icacls**

Insert ` 2>$null` immediately before the `| Out-Null` on each:

- `& 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r' | Out-Null`
  → `... '/r' 2>$null | Out-Null`
- `& 'icacls' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null`
  → `... '/C' 2>$null | Out-Null`
- `& 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" | Out-Null`
  → `...\OneDriveSetup.exe" 2>$null | Out-Null`
- `& 'icacls' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null`
  → `... '/C' 2>$null | Out-Null`

- [ ] **Step 6: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11maker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for maker (skip locally if module absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: 96 passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
git add tiny11maker.ps1
git commit -m "fix(maker): robust transcript + best-effort optional-component removals"
```

---

## Notes for the executor

- Base for the increment: current `harden/core-error-handling` HEAD.
- After both tasks: final whole-branch review, then finishing-a-development-branch (push/PR/merge to fork main; CI gates the PR). The `YmlyZA` account is the persistent active account for this repo (do NOT restore thunderbird-ns); it has the `workflow` scope.
- Real-machine close-out (user, Windows): interrupt-then-rerun yields a complete `tiny11.log` with no `Stop-Transcript` error; an LTSC build shows no red OneDrive/Edge removal errors; an arm64 build shows no `arm_...` WinSxS warnings.
