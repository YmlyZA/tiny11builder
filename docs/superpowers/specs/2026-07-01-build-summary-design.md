# tiny11 builders - end-of-build summary - design

- **Date:** 2026-07-01
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1` (kept at parity)
- **Branch:** `harden/core-error-handling`

## Context

A successful build ends with hundreds of log lines and a single `"Creation
completed!"`. Across many machines the user wants an at-a-glance verdict per run
without scrolling the transcript: did it finish, how long did it take, how big is
the ISO, how many apps were removed, and did any (benign) warnings occur. The
scripts already do warn-and-continue at their removal loops (the same mechanism
that turns the benign IE "package not applicable" error into a one-line warning),
so the warning count is derivable by instrumenting those sites.

## Goal

Print a compact BUILD SUMMARY block at the end of a successful build in both
scripts, showing: result, elapsed time, output ISO path + size, provisioned Appx
removed (of total), and non-fatal warning count.

## Design

### Pure helper: `Format-BuildSummary` (both scripts, byte-identical)

Formatting is pure and unit-tested on macOS from both scripts (guarded by CI):

```powershell
function Format-BuildSummary {
    param(
        [timespan]$Elapsed,
        [long]$IsoBytes,
        [string]$IsoPath,
        [int]$AppsRemoved,
        [int]$AppsTotal,
        [int]$Warnings
    )
    $elapsedText = "{0}m {1}s" -f [int][math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds
    $sizeText    = "{0:N2} GB" -f ($IsoBytes / 1GB)
    $warnText    = if ($Warnings -eq 0) { 'none' } else { "$Warnings non-fatal (see log)" }
    return @(
        "===== BUILD SUMMARY =====",
        "  Result        : SUCCESS",
        "  Elapsed       : $elapsedText",
        "  Output ISO    : $IsoPath  ($sizeText)",
        "  Apps removed  : $AppsRemoved of $AppsTotal provisioned Appx",
        "  Warnings      : $warnText",
        "========================="
    )
}
```

Returns the block as a `[string[]]`; the caller writes each line (Core `Write-Host`,
maker `Write-Output`).

### Raw-value gathering (thin, script-body glue)

- **Start time:** `$buildStart = Get-Date` captured right after `Start-Transcript`
  (Core ~L341, maker ~L226). Placed before the dry-run block, which harmlessly
  never reaches the summary.
- **Warning counter:** `$script:buildWarnings = 0` initialised next to
  `$buildStart`, incremented at every existing warn-and-continue site:
  - Core: the oscdimg pre-flight `Write-Warning`; the provisioned-Appx removal
    failure branch; the system-package removal failure branch; the WinSxS
    allowlist `Write-Warning`.
  - maker: the oscdimg pre-flight `Write-Warning`; the provisioned-Appx removal
    failure branch (and any other warn-and-continue the file has).
  The plan enumerates the exact line of each site.
- **Apps removed:** in the provisioned-Appx loop, set `$appsTotal =
  $packagesToRemove.Count` before the loop and `$appsRemoved = 0`; on each
  iteration, increment `$appsRemoved` when the removal succeeds
  (`$LASTEXITCODE -eq 0`) and `$script:buildWarnings` when it fails. "Apps
  removed" counts provisioned Appx only (a clean number); system-package and
  Edge/OneDrive/WinRE removals are not folded in.
- **ISO size:** after `oscdimg` creates `"$PSScriptRoot\tiny11.iso"`,
  `(Get-Item $isoPath).Length` (0 if somehow absent).

### Emit point

Immediately before the existing `"Creation completed!"` line (Core ~L1047,
maker ~L686), on the success path only:

```powershell
$elapsed  = (Get-Date) - $buildStart
$isoPath  = "$PSScriptRoot\tiny11.iso"
$isoBytes = if (Test-Path $isoPath) { (Get-Item $isoPath).Length } else { 0 }
Format-BuildSummary -Elapsed $elapsed -IsoBytes $isoBytes -IsoPath $isoPath `
    -AppsRemoved $appsRemoved -AppsTotal $appsTotal -Warnings $script:buildWarnings |
    ForEach-Object { Write-Host $_ }   # maker: Write-Output
```

## Non-goals

- No summary on the failure path (a failed build already surfaces its abort via
  the existing error handling; the summary asserts SUCCESS).
- No machine-readable output (JSON/CSV) - human-readable block only.
- No timing of individual phases - one wall-clock elapsed figure.
- No change to what gets removed - only counting what already happens.

## Testing strategy

- **Static (every change):** `parse-check.ps1`, `linter.ps1`,
  `test-core-helpers.ps1` stay green; now also enforced by CI.
- **Unit tests (`Format-BuildSummary`, from BOTH scripts via the parity
  harness):**
  - elapsed formatting: a `New-TimeSpan` of 0h27m41s renders `27m 41s`.
  - size: `4070127616` bytes renders `3.79 GB`.
  - counts: `AppsRemoved 31`, `AppsTotal 33` renders `31 of 33 provisioned Appx`.
  - warnings zero renders `none`; warnings 2 renders `2 non-fatal (see log)`.
  - the block has the SUCCESS header/footer lines.
- **Runtime (Windows, user):** a real build prints the summary before "Creation
  completed!" with sane values; cross-check elapsed/size against the log.

## Sequencing

1. `Format-BuildSummary` helper + unit tests (Core), then wire Core (start time,
   counters, emit).
2. Same helper + parity tests (maker), then wire maker.

All work continues on `harden/core-error-handling`.
