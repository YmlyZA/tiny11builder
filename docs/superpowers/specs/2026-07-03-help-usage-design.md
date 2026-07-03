# tiny11 builders - `-Help` / usage - design

- **Date:** 2026-07-03
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1`
- **Branch:** `harden/core-error-handling`

## Context

The scripts have grown many flags (`-DryRun`, `-Compress`, `-Fast`, `-User`,
`-Password`, `-TimeZone`, `-ZeroTouch`, ...) but there is no quick way to see
them. The comment-based help block at the top is also stale - it documents only
the original params. Users want a `-Help` flag that lists the options.

## Goal

`-Help` prints a concise, grouped usage block and exits; `Get-Help` / `-?` are
accurate. Bare invocation is UNCHANGED (still enters the interactive flow).

## Design

### `-Help` switch (both scripts)

- Add `[switch]$Help` to the `param()` block.
- Define a small `Show-Usage` function (prints the usage block for THAT script -
  Core lists `-Keep`/`-Remove`/`-EnableNet35`; maker does not) right after the
  `param()` block / the `-Keep`/`-Remove` normalization.
- Immediately after defining it: `if ($Help) { Show-Usage; exit 0 }`.
- **Placement is before** the execution-policy check and the UAC self-relaunch,
  so `-Help` never triggers an elevation prompt, never starts a transcript, and
  does no work. `-Help` is NOT added to the elevation arg-forwarding list (a
  `-Help` run exits before elevation).
- Bare invocation (no params) is untouched - it still falls through to the
  interactive path.

### Usage block content (grouped)

Core `Show-Usage` prints: a one-line description; USAGE line; REQUIRED (`-ISO`,
`-Index`); COMMON (`-Yes`, `-DryRun`, `-Fast`, `-Compress`, `-SCRATCH`); OPTIONAL
UTILITIES (`-Keep`, `-Remove`, `-EnableNet35`); UNATTENDED (`-User`, `-Password`,
`-TimeZone`, `-ZeroTouch`); `-Help`; and 3 EXAMPLES (a `-DryRun`, a normal build,
a `-ZeroTouch` custom-account build). maker's block is the same minus the
Core-only OPTIONAL UTILITIES group, and describes it as the regular serviceable
builder. ASCII only; the `-TimeZone` line notes it needs a Windows time-zone id
(`tzutil /l`).

### Refresh the comment-based help

Update the top `<# .SYNOPSIS ... #>` block to add the missing `.PARAMETER`
entries (`DryRun`, `Compress`, `Fast`, `User`, `Password`, `TimeZone`,
`ZeroTouch`, `Help`) and two `.EXAMPLE` blocks, so `Get-Help .\tiny11Coremaker.ps1`
and `-?` are complete.

## Non-goals

- No change to bare/interactive behavior.
- `Show-Usage` is static print text, not a unit-tested pure helper, and is
  intentionally NOT byte-identical across the two scripts (their flag sets
  differ) - so no cross-script parity test for it.
- No `-h`/`-?` alias beyond what PowerShell already provides (`-?` maps to
  comment-based help automatically).

## Testing strategy

- **Static (every change):** `parse-check.ps1`, `linter.ps1`,
  `test-core-helpers.ps1` (117) stay green; CI enforces on Windows PS 5.1.
- No new unit tests (static help text).
- **Manual (any OS with pwsh):** `pwsh -File tiny11Coremaker.ps1 -Help` prints
  the usage block and exits 0 without prompting/elevating; same for maker.
  (Note: this is the one script path that IS macOS-runnable, since `-Help` exits
  before any Windows-only call.)

## Sequencing

1. Core: `-Help` param + `Show-Usage` + early `if ($Help)` guard + comment-help refresh.
2. maker: same (maker-specific usage text).

All work continues on `harden/core-error-handling`.
