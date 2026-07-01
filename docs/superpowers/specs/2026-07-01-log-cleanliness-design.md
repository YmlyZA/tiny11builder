# tiny11 builders - log cleanliness / robustness - design

- **Date:** 2026-07-01
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1` (#1, #2 both; #3 Core only)
- **Branch:** `harden/core-error-handling`

## Context

A real, successful build (24m40s, valid 2.73 GB ISO) produced a log full of
scary-but-benign noise, which defeats the "glance at the log per machine"
workflow. Three sources, all benign absence:

1. **Transcript fragility.** Interrupting a run (Ctrl-C at the confirm prompt,
   before the try/finally) leaves the session transcript open. The next run's
   `Start-Transcript` then fails silently ("already started"), so that run has NO
   transcript: its `tiny11.log` is stale/incomplete and `Stop-Transcript` at the
   end throws "The host is not currently transcribing".
2. **Best-effort removals error on absent targets.** On an LTSC/IoT image (no
   OneDrive), `Remove-Item ...\OneDriveSetup.exe -Force` (no `-ErrorAction`)
   throws a red `ItemNotFoundException`; the paired `takeown`/`icacls` print
   native "file not found" errors. Same risk for Edge / Edge-Webview / winre.wim
   on SKUs that lack them.
3. **WinSxS allowlist arm32 leftovers on arm64.** Core's arm64 allowlist branch
   contains 5 `arm_microsoft.windows.*` patterns that never match an arm64 image
   (its components are `arm64_...`). Each already has an `arm64_` twin in the same
   list, so the `arm_` lines are dead - they only emit "allowlist pattern matched
   nothing" warnings.

## Goal

A successful build produces a clean log: no false red errors, no benign-absence
warning spam, and a complete transcript even after an interrupted-then-rerun.

## Design

### #1 Transcript lifecycle (both scripts)

- Immediately BEFORE `Start-Transcript`, close any transcript leaked by a prior
  aborted run in the same session:
  `Stop-Transcript -ErrorAction SilentlyContinue | Out-Null`
  This guarantees the current run starts its own clean transcript (so `tiny11.log`
  always reflects THIS run).
- Add `-ErrorAction SilentlyContinue` to EVERY `Stop-Transcript` (the dry-run
  block and the finally/end), so it never throws when nothing is transcribing.

Sites: Core `Start-Transcript` L372; `Stop-Transcript` L488 (dry-run), L1126
(finally). maker `Start-Transcript` L257; `Stop-Transcript` L339 (dry-run), L803
(end).

### #2 Best-effort optional-component removals (both scripts)

The Edge / Edge-Webview / winre.wim / OneDrive removals are best-effort (the
target legitimately may not exist on a given SKU). Make them silent on absence:

- Add `-ErrorAction SilentlyContinue` to each optional-component `Remove-Item`.
  - Core: L729, L730, L731 (Edge/EdgeUpdate/EdgeCore), L742 (Edge-Webview),
    L746 (winre.wim), L751 (OneDriveSetup).
  - maker: L523, L524, L525 (Edge/EdgeUpdate/EdgeCore), L528 (Edge-Webview),
    L532 (OneDriveSetup).
- Suppress the native error stream of the paired `takeown`/`icacls` in that block
  by appending `2>$null` (they emit "file not found" to stderr on an absent
  target).
  - Core: L740, L741 (Edge-Webview), L749, L750 (OneDrive).
  - maker: L526, L527 (Edge-Webview), L530, L531 (OneDrive).

Out of scope for the guard: the structural `Remove-Item` on the old WinSxS
(Core L859) and the end-of-run scratchdir cleanup stay as-is - those are not
optional-component removals.

### #3 WinSxS allowlist arm32 cleanup (Core only)

Delete the 5 dead `arm_microsoft.windows.*` lines (Core L822-826). Each has an
existing `arm64_microsoft.windows.*` twin (L829-833) that actually matches on
arm64, so deletion removes exactly the 5 warnings with ZERO change to what is
copied into `WinSxS_edit`. maker has no WinSxS allowlist, so this fix is
Core-only.

## Non-goals

- The 7 system-package "name variant" warnings (IE/MediaPlayer/StepsRecorder) -
  each package IS removed via its correct variant; quieting the multi-variant
  strategy is a separate, larger change (deferred).
- "Apps removed: 0 of 0" wording - correct for LTSC (no provisioned Appx);
  wording tweak deferred (user chose 1/2/3, not 4).
- Any change to WHAT is removed or copied - this increment only changes error/
  warning visibility and transcript robustness.

## Testing strategy

- No new pure logic, so no new unit tests. `parse-check.ps1`, `linter.ps1`,
  `test-core-helpers.ps1` (96) stay green; CI enforces them on Windows PS 5.1.
- **Runtime (Windows, user):**
  - Interrupt a run at the confirm prompt, then rerun in the same window ->
    `tiny11.log` reflects the second run and no `Stop-Transcript` error appears.
  - An LTSC/IoT build -> no red `OneDriveSetup.exe` / Edge removal errors.
  - An arm64 build -> the 5 "WinSxS allowlist pattern matched nothing: arm_..."
    warnings are gone (and the summary's warning count drops accordingly).

## Sequencing

1. Core: #1 transcript, #2 removals, #3 WinSxS arm_ cleanup.
2. maker: #1 transcript, #2 removals.

All work continues on `harden/core-error-handling`.
