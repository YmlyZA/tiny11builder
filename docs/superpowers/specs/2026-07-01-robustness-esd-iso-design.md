# tiny11 builders - robustness (ESD index + verified ISO) - design

- **Date:** 2026-07-01
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1` (kept at parity)
- **Branch:** `harden/core-error-handling`

## Context

Two robustness gaps surfaced during earlier reviews:

1. **ESD multi-edition index.** When the source is `install.esd` (no `install.wim`),
   each script exports the chosen source index into a fresh `install.wim`
   (Core L522, maker L367). In that new WIM the chosen edition becomes **index 1**,
   but the later mount still uses `/index:$imageIndex` (the source index, e.g. 3).
   For a multi-edition ESD with a chosen index != 1 this fails at mount
   (cryptic DISM `0xc1560111`). The pre-flight index check does not catch it
   because it validates against the source ESD's full index list.
2. **Unverified ISO creation.** Neither script checks `oscdimg`'s exit code or
   that `tiny11.iso` was actually written, so a failed ISO step still reaches
   "Creation completed!" and prints a BUILD SUMMARY reading `SUCCESS` with
   `0.00 GB`.

## Goals

1. Make a multi-edition **ESD** source with any valid chosen index build the
   correct edition (fix the mount-index mismatch).
2. Make "SUCCESS" truthful: fail loudly if `oscdimg` did not produce a valid ISO.
3. Make the summary's size field locale-safe.

## Non-goals

- Pre-existing `tiny11.iso` handling - `oscdimg` overwrites the output ISO
  (builds have repeatedly succeeded over an existing ISO); no fix needed.
- Interrupted-run cleanup - already handled at mount time (Cleanup-Mountpoints +
  discard-leftover-mount, from the earlier hardening).
- The amd64 default build - a user-run validation, not a code change.

## Design

### A. ESD index remap (both scripts, ESD branch only)

Immediately after the ESD->WIM export, set `$imageIndex = 1`, because the freshly
exported WIM holds the chosen edition as its only image (index 1). This runs ONLY
inside the `install.esd` conversion branch; WIM-based ISOs are untouched and keep
their real per-edition indices.

- Core: after `Invoke-Dism /Export-Image ... /SourceIndex:$imageIndex ...
  install.wim ...` (L522), add `$imageIndex = 1`.
- maker: after `Export-WindowsImage -SourceIndex $imageIndex ...
  install.wim ...` (L367), add `$imageIndex = 1`.

Not unit-testable (body wiring on a mounted image); verified by parse/lint + a
Windows run against a multi-edition ESD ISO. Reasoning: `Export-Image` /
`Export-WindowsImage` writes the single selected image as index 1 of the
destination.

### B. Verified ISO creation (both scripts)

Pure helper (byte-identical in both, unit-tested from both, CI-guarded):

```powershell
function Test-IsoResult {
    # The ISO step succeeded only if oscdimg exited 0 AND a non-empty file exists.
    param([int]$ExitCode, [bool]$IsoExists, [long]$IsoBytes)
    return ($ExitCode -eq 0 -and $IsoExists -and $IsoBytes -gt 0)
}
```

Wiring, immediately after the `& "$OSCDIMG" ... "$PSScriptRoot\tiny11.iso"` call
in each script:

```powershell
$isoExit   = $LASTEXITCODE
$isoResult = "$PSScriptRoot\tiny11.iso"
$isoOk     = Test-Path $isoResult
$isoLen    = if ($isoOk) { (Get-Item $isoResult).Length } else { [long]0 }
if (-not (Test-IsoResult -ExitCode $isoExit -IsoExists $isoOk -IsoBytes $isoLen)) {
    throw "ISO creation failed (oscdimg exit $isoExit); no valid tiny11.iso was produced at $isoResult."
}
```

Because this `throw` precedes the "Creation completed!" line and the BUILD SUMMARY
emit, a failed ISO step now aborts instead of printing a false SUCCESS. In Core the
throw is caught by the existing try/catch/finally (cleanup runs); in maker it
terminates the run. (The variable names differ from the summary block's
`$isoPath`/`$isoBytes` to avoid any interaction; the summary block is unchanged.)

### C. Locale-safe size formatting (both scripts)

In `Format-BuildSummary`, replace the culture-sensitive
`"{0:N2} GB" -f ($IsoBytes / 1GB)` with an InvariantCulture render so a
comma-decimal machine still prints `3.79 GB`:

```powershell
    $sizeText = "{0} GB" -f (($IsoBytes / 1GB).ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture))
```

The helper stays byte-identical across both scripts. The existing size assertions
(`3.79 GB`, `2.00 GB`, `1.00 GB`) still hold under invariant culture.

## Testing strategy

- **Static (every change):** `parse-check.ps1`, `linter.ps1`,
  `test-core-helpers.ps1` stay green; enforced by CI.
- **Unit tests:**
  - `Test-IsoResult`: `(0,true,100)->true`; `(1,true,100)->false` (bad exit);
    `(0,false,0)->false` (missing file); `(0,true,0)->false` (empty file).
    Loaded from BOTH scripts (parity).
  - `Format-BuildSummary`: existing size assertions continue to pass, now
    guaranteed locale-independent.
- **Runtime (Windows, user):**
  - a multi-edition ESD ISO with a chosen index != 1 now builds that edition
    (mount succeeds; the produced image is the chosen edition);
  - a normal build still ends with a valid ISO + the summary;
  - (optional) a forced `oscdimg` failure aborts with the new error instead of
    "Creation completed!".

## Sequencing

1. Core: `Test-IsoResult` helper + unit tests; A (ESD remap); B (wiring);
   C (locale fix in Core's `Format-BuildSummary`).
2. maker: `Test-IsoResult` helper (verbatim) + parity test; A; B; C.

All work continues on `harden/core-error-handling`.
