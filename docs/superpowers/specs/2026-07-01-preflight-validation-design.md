# tiny11 builders - pre-flight validation - design

- **Date:** 2026-07-01
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1` (kept at parity)
- **Branch:** `harden/core-error-handling` (same fork branch as the prior work)

## Context

Real-machine testing surfaced a class of failures that share one shape: **the
check that would have caught the problem happens *after* the expensive work.**
A wrong `-Index` fails at DISM mount (cryptic `0xc1560111`) *after* the multi-
minute image copy; an undersized scratch drive fails partway through the copy
or an export; a missing `oscdimg` (no ADK, bundled download unreachable) is not
discovered until the very end, wasting the entire ~30-minute build.

The existing scripts already fail-fast on several inputs (scratch drive exists,
image drive exists, `install.wim`/`.esd` present, `-Keep`/`-Remove` names,
`-Yes` requires `-ISO`+`-Index`). This work extends that discipline to the three
gaps above by hoisting every "can this run even succeed?" check into a single
**pre-flight phase that runs before the copy** - and is exactly what `-DryRun`
executes, so the user can catch these in seconds without a build.

## Goals

1. **Fail before the copy, not after** - validate the requested image index,
   free space, and ISO-builder availability up front.
2. **Friendly, actionable messages** - e.g. list the image's real editions when
   the index is wrong; state how many GB are needed vs. free.
3. **`-DryRun` runs the same checks** - reading indices/size directly off the
   source ISO (no copy), so `-DryRun -ISO D -Index 3` reports the problem
   instantly.
4. **Parity** - both scripts get the same pre-flight phase and the same
   unit-tested helpers, so they do not drift.

## Non-goals

- Validating anything that genuinely requires a mounted image (system-package
  list, language/arch) - those stay where they are, post-mount.
- Auto-fixing (e.g. freeing disk space, installing the ADK). Pre-flight reports
  and aborts/warns; it does not remediate.
- Checking the ISO *output* drive separately from scratch (the ISO is written to
  the script folder; the scratch-drive free-space check is the primary guard).

## Design

### Shared, unit-testable helpers (duplicated across both scripts at parity)

All pure helpers get unit tests in `scripts/test-core-helpers.ps1`, loaded from
BOTH scripts via the existing AST-extraction harness (parity test).

- **`Get-AvailableImageIndex`** *(pure)* - input: the text output of
  `dism /English /Get-WimInfo /wimfile:<path>` (the no-index enumeration).
  Output: an array of `[pscustomobject]@{ Index=[int]; Name=[string];
  SizeBytes=[long] }`, one per image. Parses the repeated `Index : N`,
  `Name : ...`, and `Size : 12,345 bytes` lines (commas stripped). Empty/garbage
  input yields an empty array.

- **`Test-ImageIndexAvailable`** *(pure)* - `param([int]$Index, $Available)`;
  returns `$true` iff `$Index` is among `$Available.Index`. Used to decide the
  abort.

- **`Get-RequiredScratchBytes`** *(pure)* - `param([long]$ImageApparentBytes)`;
  returns `[long]( [math]::Max($FloorBytes, $ImageApparentBytes * $Factor) )`.
  Named constants: `$Factor = 1.5`, `$FloorBytes = 20GB`. (Peak scratch usage is
  the mounted image view plus the coexisting `install.wim`/`install2.wim`/
  `install.esd` exports; 1.5x the apparent size with a 20 GB floor covers it.)

- **`Test-SufficientScratch`** *(pure)* - `param([long]$RequiredBytes,
  [long]$FreeBytes)`; returns `[pscustomobject]@{ Ok=[bool]; RequiredBytes;
  FreeBytes }`. Keeps the comparison and the GB rounding for the message
  testable.

- **`Resolve-OscdimgSource`** *(pure)* - `param([bool]$AdkExists,
  [bool]$BundledExists)`; returns `'adk' | 'bundled' | 'download'`
  (ADK preferred, then bundled, else download-at-build-time). The `Test-Path`
  calls stay in the caller so the decision itself is unit-tested.

### The pre-flight phase (both scripts)

Runs after input resolution (drive letters validated, `install.wim`/`.esd`
located) and **before the copy**. In `-DryRun` it reads the SOURCE image on the
ISO (`$DriveLetter\sources\install.wim` or `install.esd`); in a real run it uses
the same source before copying. Steps:

1. `dism /Get-WimInfo` on the source -> `Get-AvailableImageIndex`.
2. **Index check (abort):** if `-Index` was supplied and
   `-not Test-ImageIndexAvailable`, `throw` a message listing every available
   `Index = Name`. If `-Index` was omitted (interactive), skip the abort here;
   the existing post-`Get-WimInfo` prompt loops until the entry is valid (Core
   gains maker's `while ($ImagesIndex -notcontains ...)` loop for parity).
3. **Free-space check (abort):** `Get-RequiredScratchBytes` on the chosen
   index's `SizeBytes` (or, if interactive, the largest index's size);
   `Test-SufficientScratch` against the scratch drive's free bytes
   (`(Get-PSDrive <letter>).Free`). If not `Ok`, `throw` "needs ~N GB free on
   `<drive>`, only M GB available."
4. **oscdimg pre-flight (warn):** `Resolve-OscdimgSource` from
   `Test-Path <ADK oscdimg>` and `Test-Path <bundled oscdimg.exe>`. If the
   result is `'download'`, `Write-Warning` that neither the ADK nor a bundled
   `oscdimg.exe` was found and the ISO step will attempt a download at the end.
   Never aborts (the end-of-run chain still tries ADK/bundled/download).

### `-DryRun` integration

The dry-run block runs steps 1-4 and folds the results into its printed plan:

```
  Image index (-Index) : 3   -> ERROR: not found; available: 1 = Windows 11 IoT Enterprise LTSC Evaluation
  Scratch free space   : 41 GB free, ~29 GB required  [OK]
  ISO builder (oscdimg): system ADK   [OK]
```

A dry run with a bad index or insufficient space prints the failure line and
exits non-zero (so scripted callers can detect it), instead of the current
always-`exit 0`. A clean dry run still exits 0.

## Behavior summary

| Check | Provided `-Index` | Interactive | On failure |
|---|---|---|---|
| Index valid | abort with edition list | re-prompt loop (parity) | abort (provided) |
| Free space | abort | abort | abort |
| oscdimg source | warn | warn | warn (never blocks) |

## Testing strategy

- **Static (every change):** `scripts/parse-check.ps1` + `scripts/linter.ps1`
  cover both scripts; `scripts/test-core-helpers.ps1` stays green.
- **New pure logic:** unit tests for `Get-AvailableImageIndex` (single- and
  multi-index sample text; comma-separated sizes; empty input),
  `Test-ImageIndexAvailable` (hit/miss), `Get-RequiredScratchBytes`
  (floor vs. factor branches), `Test-SufficientScratch` (ok/short), and
  `Resolve-OscdimgSource` (adk/bundled/download precedence) - loaded from BOTH
  scripts (parity).
- **`-DryRun` as the manual test aid:** `-DryRun -ISO D -Index <bad>` prints the
  friendly index error and exits non-zero; `-DryRun -ISO D -Index 1` prints
  `[OK]` lines - both verifiable without a real build.
- **Real build (Windows):** one `-Fast -Index 1` build confirms the pre-flight
  passes and the build proceeds (closes out the earlier `-Fast` validation).

## Sequencing

1. Helpers + unit tests (both scripts).
2. Core pre-flight phase + index re-prompt loop parity.
3. maker pre-flight phase (hoist its existing index check earlier; guard the ESD
   export path).
4. `-DryRun` integration (both) + non-zero exit on pre-flight failure.
5. Docs (README note on the pre-flight checks).

All work continues on `harden/core-error-handling`.
