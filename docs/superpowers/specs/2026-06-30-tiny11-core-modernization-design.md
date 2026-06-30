# tiny11 Core modernization — design

- **Date:** 2026-06-30
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` (fork maintained by the user)
- **Branch:** `harden/core-error-handling`

## Context

`tiny11Coremaker.ps1` is the "Core" builder: a deliberately minimal, **non-serviceable**,
throwaway Windows 11 image for running scripts, testing, and VMs. The original author has
not updated it in ~18 months and it is still labelled BETA. Earlier in this effort we fixed
seven confirmed bugs and added DISM error handling (O4/O5). This design covers the next round
of improvements while **preserving the author's Core trade-offs** — we are not turning Core
into a general-purpose desktop image.

The user's environment and constraints:
- Use case: running scripts / testing / batch installs (not a daily-driver machine).
- Maintains their own fork.
- Size is already satisfactory (~3 GB ISO, < 10 GB installed); networking during build is acceptable.
- Tested only on **25H2 arm64** (builds 26200.x from the 2512 and 2602 ISO releases). The
  **amd64 path has never been exercised by the user.**

## Goals

1. **WinSxS cross-version robustness** — detect a broken WinSxS rebuild and abort, rather than
   silently shipping a non-bootable ISO.
2. **Parameterization / unattended operation** — allow batch, non-interactive builds.
3. **Removal-list modernization** — refresh the bloat lists; align with the maker baseline plus
   18 months of new packages.
4. **Document the by-design limitations** — Store, Defender, Windows Update, serviceability.

## Non-goals (explicitly out of scope)

- **Making the Microsoft Store install apps.** This requires Windows Update access, retained
  framework dependencies (VCLibs / .NET.Native / UI.Xaml), and serviceability — all of which
  Core deliberately destroys. Any real fix converts Core back into maker. Store availability is
  therefore documented as a known, by-design limitation. Users who need the Store use
  `tiny11maker.ps1`.
- Re-enabling Windows Update or Defender.
- Restoring serviceability (`/ResetBase` + the WinSxS rebuild stay).
- Tier-3 work (reg-tweak data-table refactor, build-speed micro-optimizations) — deferred to a
  later round.

## Design

### Goal 1 — WinSxS integrity gate (highest priority)

**Problem.** The `$dirsToCopy` allowlists (separate for amd64 and arm64) hardcode
servicing-stack component names and metadata folders. When Microsoft ships a build that renames
or adds a servicing component not in the list, the rebuilt WinSxS silently omits it, producing an
image that may fail to boot or sysprep. The README advertises "works on ANY Windows 11 release,"
but the amd64 list is untested by the user and both lists are version-shaped.

**Approach (chosen): post-rebuild integrity gate — abort on missing critical components.**
We do not try to be smarter about *what* to keep (that is maker's serviceable path). Instead, after
copying the allowlist into `WinSxS_edit` and **before** deleting the old `WinSxS`, we verify the
rebuild looks viable:

1. **Per-pattern zero-match logging.** For each `$dirsToCopy` pattern, if `Get-ChildItem -Filter`
   matched 0 directories, `Write-Warning` the pattern. This surfaces "a new build renamed this."
2. **Critical-category assertion.** Require, in `WinSxS_edit`:
   - at least one directory whose name matches `*servicingstack*` (servicing stack is mandatory
     for boot/sysprep), and
   - the metadata folders that are always present in both arch lists: `Catalogs`, `Manifests`,
     `Fusion`, `FileMaps`.
3. **Abort on failure.** If any critical category is missing, `throw` a clear message. This rides
   the existing try/catch/finally (O5): the finally unloads hives, discards the still-mounted
   image, and the script exits 1 — so we never delete the real WinSxS or commit a broken image.

Validation runs against the copied `WinSxS_edit` directory, so it is testable on any filesystem
(see Testing) without a real Windows image.

**Rejected alternative.** Dynamically querying the image for the servicing-stack package and
copying its actual folders would be "more correct," but DISM does not expose a clean
package→WinSxS-folder mapping; it is complex and risky and clashes with Core's simplicity. The
gate buys ~90% of the protection for ~5% of the cost.

### Goal 2 — parameterization / unattended operation

**Approach.** Mirror `tiny11maker.ps1`'s pattern: a `param()` block where each value falls back to
an interactive prompt when the parameter is absent. Fully backward compatible — running with no
arguments reproduces today's interactive behavior.

Parameters:
- `-ISO <letter>` — drive letter of the mounted Windows 11 image (validated `^[c-zC-Z]$`).
- `-SCRATCH <letter>` — scratch/work drive (name kept identical to maker for fork-wide
  consistency). Defaults to `$env:SystemDrive` when omitted, preserving current behavior.
- `-Index <int>` — image index to build.
- `-EnableNet35` — switch; enables .NET 3.5 without prompting.
- `-Yes` — switch; skips the two `y/n` confirmation prompts (continue, and — when `-EnableNet35`
  is not given — the .NET prompt defaults to "no").

Non-interactive rules:
- When a prompt's parameter is supplied, use it; otherwise prompt as today.
- Under `-Yes` (treated as non-interactive intent), if a required value is missing (e.g. `-ISO`
  or `-Index`), **throw a clear error and exit** instead of blocking on `Read-Host` — so a batch
  run fails fast rather than hanging.

The admin/UAC self-relaunch must **forward the supplied parameters** (the same `-File "..."` +
argument-forwarding fix already applied to maker), so elevation does not drop them and fall back
to prompting.

### Goal 3 — removal-list modernization

**Observation.** Core's provisioned-Appx removal list is actually *older* than maker's — it omits
several packages maker already removes. Approach:

1. **Align to the maker baseline** as a superset, except retentions noted below.
2. **Add recent bloat** (verified against a live 25H2 provisioned-package dump during
   implementation): current Copilot package name(s), Phone Link, widgets/web-experience, and any
   new AI/Recall-related provisioned packages that are present.
3. **De-duplicate** the list (the maker list, for reference, repeats `WindowsTerminal` and
   `Windows.Copilot`).

**Deliberate retention — Windows Terminal.** Core currently keeps `Microsoft.WindowsTerminal`
(maker removes it). We **keep** it, because the user's primary use case is running scripts and
testing — removing the terminal from a script-testing image is counterproductive. This is an
intentional divergence from the maker baseline, documented in the script.

The system-package (`/Remove-Package`) list and the language-feature removals are unchanged this
round.

### Goal 4 — document by-design limitations

- Add a "tiny11 Core — limitations by design" subsection to `README.md`: no Microsoft Store app
  installation, no Defender, no Windows Update, not serviceable. Direct users who need any of
  these to `tiny11maker.ps1`.
- Add a matching short header comment block to `tiny11Coremaker.ps1`.

## Testing strategy

- **Static (every change):** `scripts/parse-check.ps1` and `scripts/linter.ps1` (already in use;
  must stay parse-clean and free of non-stylistic lint findings).
- **Integrity-gate unit test (macOS-friendly):** construct a fake `WinSxS_edit` directory tree
  and assert the gate (a) passes when critical categories are present, (b) throws when
  `servicingstack` or a metadata folder is missing, (c) logs zero-match patterns. No real image
  needed; runnable under pwsh on macOS like the existing helper tests.
- **Real build (Windows):** the user's existing Layer 2/3 flow. This round must include **one
  amd64 build** (the user's blind spot) to confirm the integrity gate does not false-positive on
  the amd64 allowlist and that the produced ISO boots.
- **Unattended smoke:** run with full `-ISO/-SCRATCH/-Index/-EnableNet35/-Yes` and confirm no
  `Read-Host` is hit; run with a missing required parameter under `-Yes` and confirm a clean
  fail-fast error.

## Sequencing

1. Goal 2 (parameterization) and Goal 3 (removal list) first — low risk, independently testable.
2. Goal 1 (integrity gate) next — needs the amd64 build run to validate.
3. Goal 4 (docs) last, reflecting the final behavior.

All work continues on `harden/core-error-handling`. `tiny11maker.ps1` is not modified by this
round (it does not rebuild WinSxS and already has parameters).
