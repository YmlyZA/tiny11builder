# `-Help` / Usage Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `-Help` switch to both scripts that prints a grouped usage block and exits, and refresh the stale comment-based help. Bare invocation stays interactive.

**Architecture:** A `Show-Usage` function defined right after `param()`, guarded by `if ($Help) { Show-Usage; exit 0 }` before the execution-policy / elevation logic. Per-script usage text.

**Tech Stack:** Windows PowerShell 5.1 (also runs on pwsh 7 for the `-Help` path).

## Global Constraints

- **Windows PowerShell 5.1** compatible; ASCII only.
- The `-Help` guard MUST run before the execution-policy check and the UAC self-relaunch (so `-Help` never prompts, elevates, or starts a transcript).
- Do NOT add `-Help` to the elevation arg-forwarding block.
- Do NOT change bare/interactive behavior.
- Use a **single-quoted here-string** (`@'...'@`) for the usage text so nothing interpolates.
- Usage text is per-script (Core lists `-Keep`/`-Remove`/`-EnableNet35`; maker does not) — not shared, no parity test.

---

### Task 1: Core — `-Help` switch, `Show-Usage`, comment-help refresh

**Files:** Modify `tiny11Coremaker.ps1`.

- [ ] **Step 1: Add the `-Help` param**

In the `param()` block, change the last line `    [switch]$ZeroTouch` to:
```powershell
    [switch]$ZeroTouch,
    [switch]$Help
```

- [ ] **Step 2: Refresh the comment-based help**

In the top `<# ... #>` block, insert these lines immediately after the `.PARAMETER Yes` block (the two lines ending with "...requires -ISO and -Index.") and before the closing `#>`:
```
.PARAMETER DryRun
    Print the build plan and exit without copying or mounting (fast sanity check).
.PARAMETER Compress
    Image compression: recovery (default), fast, or none.
.PARAMETER Fast
    'fast' compression plus skip component cleanup; keeps the WinSxS rebuild.
.PARAMETER User
    Local administrator account created by the unattended answer file (default: User).
.PARAMETER Password
    Password for that account (default: blank; AutoLogon is always enabled).
.PARAMETER TimeZone
    Windows time-zone id set during OOBE (default: UTC; e.g. "China Standard Time").
.PARAMETER ZeroTouch
    Also wipe disk 0 and install with zero clicks (DESTRUCTIVE; VMs/test machines only).
.PARAMETER Help
    Show usage and exit.
.EXAMPLE
    .\tiny11Coremaker.ps1 -ISO D -Index 1 -Yes -DryRun
.EXAMPLE
    .\tiny11Coremaker.ps1 -ISO D -Index 1 -Yes -Fast -ZeroTouch -User Bob -TimeZone "China Standard Time"
```

- [ ] **Step 3: Add `Show-Usage` + the guard**

Immediately AFTER the `-Keep`/`-Remove` normalization block (the two `$Keep = ...` / `$Remove = ...` lines) and BEFORE the `if ((Get-ExecutionPolicy) -eq 'Restricted')` line, insert:
```powershell
function Show-Usage {
    Write-Output @'
tiny11 Core builder - build a minimal, NON-SERVICEABLE Windows 11 image (testing / VMs).

USAGE:
  .\tiny11Coremaker.ps1 -ISO <drive> -Index <n> [options]

REQUIRED (or you will be prompted):
  -ISO <letter>        Drive letter of the mounted Windows 11 ISO (e.g. D)
  -Index <n>           Image index to build (an ISO can hold several editions)

COMMON:
  -Yes                 Non-interactive; requires -ISO and -Index
  -DryRun              Print the build plan and exit (no copy/mount) - fast sanity check
  -Fast                'fast' compression + skip component cleanup (keeps the WinSxS rebuild)
  -Compress <recovery|fast|none>   Image compression (default: recovery)
  -SCRATCH <letter>    Scratch/work drive (default: system drive)

OPTIONAL UTILITIES:
  -Keep <a,b>          Keep utilities that default to removed (e.g. -Keep Clock,Paint)
  -Remove <a,b>        Remove utilities that default to kept (e.g. -Remove Photos)
  -EnableNet35         Enable .NET 3.5

UNATTENDED INSTALL (baked into the image):
  -User <name>         Local admin account (default: User)
  -Password <pwd>      Account password (default: blank; AutoLogon is always on)
  -TimeZone <id>       Windows time-zone id (default: UTC; e.g. "China Standard Time"). List: tzutil /l
  -ZeroTouch           Also WIPE DISK 0 and install with zero clicks (DESTRUCTIVE; VMs/test only)

  -Help                Show this help and exit

EXAMPLES:
  .\tiny11Coremaker.ps1 -ISO D -Index 1 -Yes -DryRun
  .\tiny11Coremaker.ps1 -ISO D -Index 1 -Keep Clock -Yes
  .\tiny11Coremaker.ps1 -ISO D -Index 1 -Yes -Fast -ZeroTouch -User Bob -Password "P@ssw0rd" -TimeZone "China Standard Time"
'@
}
if ($Help) { Show-Usage; exit 0 }

```

- [ ] **Step 4: Verify**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11Coremaker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for Core (skip locally if PSScriptAnalyzer absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: 117 passed, 0 failed` (unchanged)
Run the actual `-Help` path (it exits before any Windows-only call, so it runs on macOS):
`pwsh -NoProfile -File tiny11Coremaker.ps1 -Help` → prints the usage block and exits 0. Confirm it contains the key flags:
`pwsh -NoProfile -File tiny11Coremaker.ps1 -Help | grep -E -- '-ZeroTouch|-User|-DryRun|EXAMPLES'` → four matches.

- [ ] **Step 5: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): add -Help usage output; refresh comment-based help"
```

---

### Task 2: maker — `-Help` switch, `Show-Usage`, comment-help refresh

**Files:** Modify `tiny11maker.ps1`.

- [ ] **Step 1: Add the `-Help` param**

In the `param (` block, change the last line `    [switch]$ZeroTouch` to:
```powershell
    [switch]$ZeroTouch,
    [switch]$Help
```

- [ ] **Step 2: Refresh the comment-based help**

In the top `<# ... #>` block, insert these lines immediately after the `.PARAMETER SCRATCH` block and before the `.EXAMPLE` line:
```
.PARAMETER Index
    Image index to build.
.PARAMETER Yes
    Non-interactive: skip prompts; requires -ISO and -Index.
.PARAMETER DryRun
    Print the build plan and exit without copying or mounting (fast sanity check).
.PARAMETER Compress
    Image compression: recovery (default), fast, or none.
.PARAMETER Fast
    'fast' compression plus skip component cleanup.
.PARAMETER User
    Local administrator account created by the unattended answer file (default: User).
.PARAMETER Password
    Password for that account (default: blank; AutoLogon is always enabled).
.PARAMETER TimeZone
    Windows time-zone id set during OOBE (default: UTC; e.g. "China Standard Time").
.PARAMETER ZeroTouch
    Also wipe disk 0 and install with zero clicks (DESTRUCTIVE; VMs/test machines only).
.PARAMETER Help
    Show usage and exit.
```

- [ ] **Step 3: Add `Show-Usage` + the guard**

Immediately AFTER the `param ( ... )` block's closing `)` and BEFORE the `if (-not $SCRATCH)` line, insert:
```powershell
function Show-Usage {
    Write-Output @'
tiny11 builder - build a trimmed-down, still-serviceable Windows 11 image.

USAGE:
  .\tiny11maker.ps1 -ISO <drive> -Index <n> [options]

REQUIRED (or you will be prompted):
  -ISO <letter>        Drive letter of the mounted Windows 11 ISO (e.g. D)
  -Index <n>           Image index to build (an ISO can hold several editions)

COMMON:
  -Yes                 Non-interactive; requires -ISO and -Index
  -DryRun              Print the build plan and exit (no copy/mount) - fast sanity check
  -Fast                'fast' compression + skip component cleanup
  -Compress <recovery|fast|none>   Image compression (default: recovery)
  -SCRATCH <letter>    Scratch/work drive (default: the script folder's drive)

UNATTENDED INSTALL (baked into the image):
  -User <name>         Local admin account (default: User)
  -Password <pwd>      Account password (default: blank; AutoLogon is always on)
  -TimeZone <id>       Windows time-zone id (default: UTC; e.g. "China Standard Time"). List: tzutil /l
  -ZeroTouch           Also WIPE DISK 0 and install with zero clicks (DESTRUCTIVE; VMs/test only)

  -Help                Show this help and exit

EXAMPLES:
  .\tiny11maker.ps1 -ISO D -Index 1 -Yes -DryRun
  .\tiny11maker.ps1 -ISO D -Index 1 -Yes
  .\tiny11maker.ps1 -ISO D -Index 1 -Yes -Fast -ZeroTouch -User Bob -Password "P@ssw0rd" -TimeZone "China Standard Time"
'@
}
if ($Help) { Show-Usage; exit 0 }

```

- [ ] **Step 4: Verify**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11maker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for maker (skip locally if module absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: 117 passed, 0 failed`
Run the `-Help` path (runs on macOS — exits before Windows-only calls):
`pwsh -NoProfile -File tiny11maker.ps1 -Help` → prints usage, exits 0.
`pwsh -NoProfile -File tiny11maker.ps1 -Help | grep -E -- '-ZeroTouch|-User|-DryRun|EXAMPLES'` → four matches.

- [ ] **Step 5: Commit**

```bash
git add tiny11maker.ps1
git commit -m "feat(maker): add -Help usage output; refresh comment-based help"
```

---

## Notes for the executor

- Base for the increment: current `harden/core-error-handling` HEAD.
- After both tasks: final whole-branch review, then finishing-a-development-branch (push/PR/merge to fork main; CI gates the PR). `YmlyZA` is the persistent active account (do NOT restore thunderbird-ns); it has the `workflow` scope.
- Both `Show-Usage` outputs are static text and intentionally differ between scripts; the parity harness does not cover them.
