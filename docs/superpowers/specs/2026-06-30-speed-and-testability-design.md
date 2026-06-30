# tiny11 builders — speed & testability — design

- **Date:** 2026-06-30
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1` (kept at parity)
- **Branch:** `harden/core-error-handling` (same fork branch as the modernization work)

## Context

Each real-machine build takes ~30 minutes, which makes iterating on the scripts painful, and
the user runs builds across many machines. Investigation shows the wall-clock is dominated by
**inherently serial DISM/CBS operations and compression**, not by anything PowerShell could
overlap:

- Within a single mounted image, CBS is transactional/locked — concurrent `/Remove-Package` or
  `/Remove-ProvisionedAppxPackage` against the same image is unsupported.
- The slow steps are: the recursive `takeown`/`icacls` over WinSxS, deleting the old WinSxS,
  `Cleanup-Image /StartComponentCleanup /ResetBase`, unmount `/commit`, and the final
  `/Compress:recovery` (ESD) export.

So "parallelize the script" is a non-goal. The leverage is: **don't do the expensive work when
testing logic** (a dry run), **do less expensive work for smoke builds** (fast/no compression,
skip ResetBase), and **use a faster copy + faster scratch** for all builds.

## Goals

1. **Fast logic iteration** — a `-DryRun` mode that validates inputs and prints the plan in
   seconds, without copying or mounting anything.
2. **Faster smoke + production builds** — `-Compress` choice and a `-Fast` preset; a multithreaded
   copy; guidance for fast scratch storage.
3. **Parity** — both scripts get the same speed/test features (and the minimal parameters maker
   needs to use them unattended), so the two scripts don't drift apart.

## Non-goals

- Parallelizing DISM/CBS work (unsupported; would corrupt the image).
- Automating a RAMDisk (Windows has no built-in RAMDisk; automating one needs a third-party tool,
  which violates the "Microsoft tools only" principle). Documented as manual guidance via `-SCRATCH`.
- Giving maker the Core optional-utility picker / `-Keep` / `-Remove` (Core-specific feature;
  maker has a different, fixed removal list). Out of scope.
- Skipping the WinSxS rebuild in `-Fast` (rejected: it would stop exercising the integrity gate).

## Design

### 1. `-DryRun` (both scripts)

A switch that resolves everything cheap and prints the plan, then exits 0 **before** the copy/mount.

Flow when `-DryRun` is set:
1. Run the normal input resolution (params or prompts) and the drive/scratch validations — so a
   dry run also catches bad `-ISO`/`-SCRATCH`/index input.
2. (Core) Resolve optional utilities (defaults + `-Keep`/`-Remove`, or the picker if interactive).
3. Print:
   - the resolved options (ISO drive, scratch, index, compression, fast/skip flags, EnableNet35);
   - (Core) kept vs removed optional utilities;
   - the always-remove provisioned-Appx list (count + names);
   - the ordered list of major steps the real run *would* execute, annotated with the chosen
     compression and any skipped steps.
4. Exit 0 without copying or mounting.

Note: the system-*package* removal list and language/arch are derived from the mounted image, so
dry-run reports the **static** plan (params, optional-utility resolution, Appx list, step order) —
which is exactly the logic that changes most often. This is a test aid, not a build.

### 2. `-Compress <recovery|fast|none>` (both scripts; default `recovery`)

Controls the final image export. Default `recovery` preserves today's behavior.

- **Core:** Core currently runs TWO compressing exports — the post-edit `install.wim` re-export
  (`/compress:max`) and then the final ESD conversion (`/Compress:recovery`). The `-Compress`
  values resolve both stages:
  - `recovery` → both stages as today (re-export `/compress:max`, then `install.esd`
    `/Compress:recovery`). Current behavior.
  - `fast` → re-export `install.wim` with `/compress:fast` and **skip the ESD conversion** (ISO
    ships `install.wim`).
  - `none` → re-export `install.wim` with `/compress:none`, skip the ESD conversion.
- **maker:**
  - maker already exports `install.wim` via `/Compress:recovery`; `-Compress` maps directly to
    that export's compression value (`recovery` default, or `fast`/`none`).
- When the format changes to WIM (fast/none), the ISO simply carries `install.wim` instead of
  `install.esd`; both are bootable by setup.

### 3. `-Fast` preset (both scripts)

A convenience switch equivalent to: `-Compress fast` **plus** skip
`Cleanup-Image /StartComponentCleanup /ResetBase`. It **keeps** the WinSxS rebuild (Core) and all
real image edits, so a `-Fast` smoke build still exercises the integrity gate and produces a
genuine, bootable image — it only drops the slowest size-only steps. An explicit `-Compress`
overrides the preset's compression (e.g. `-Fast -Compress none`).

### 4. Multithreaded copy (both scripts)

Replace `Copy-Item -Path "<drive>\*" -Destination "<scratch>\tiny11" -Recurse -Force` with
`robocopy "<drive>\" "<scratch>\tiny11" /E /MT /R:3 /W:3` (quiet flags), via a small wrapper that
treats robocopy exit codes **0–7 as success** and **>=8 as failure** (robocopy uses low exit codes
for normal "files copied" status). robocopy is a built-in Microsoft tool, so it respects the
"Microsoft tools only" principle. Applies to all modes (pure speed win on the copy step).

### 5. maker unattended parameters (parity)

So maker can use `-DryRun`/`-Fast`/`-Compress` unattended like Core, add the minimal missing
parameters to maker:
- `-Index <int>` — skip maker's interactive index prompt when supplied and valid.
- `-Yes` — skip maker's terminal "Press Enter to continue" pause (and any other y/n) for
  unattended runs.
These mirror Core's parameters; maker's existing interactive fallback is preserved when they are
omitted. (maker already has `-ISO`/`-SCRATCH` and UAC forwarding; extend the forwarding to the new
params.)

### 6. Fast-scratch documentation (both)

README guidance: point `-SCRATCH` at an SSD or a manually-created RAMDisk to speed the I/O-bound
copy/delete/mount steps. No script automation.

## Parameter interactions

- `-DryRun` short-circuits before any build, regardless of other flags; it reports what the other
  flags *would* do.
- `-Fast` sets compression to `fast` and the skip-cleanup flag; an explicit `-Compress` wins over
  `-Fast`'s compression.
- All new params are forwarded across the UAC self-relaunch in both scripts.

## Testing strategy

- **Static (every change):** `scripts/parse-check.ps1` + `scripts/linter.ps1` (cover both scripts);
  `scripts/test-core-helpers.ps1` still green.
- **New pure logic:** if compression/step planning is extracted into a helper, add unit tests to
  `scripts/test-core-helpers.ps1` (e.g. `-Fast` ⇒ compress=fast + skipCleanup; explicit `-Compress`
  overrides; robocopy exit-code classifier 0–7 vs >=8).
- **`-DryRun` is itself the primary new test aid:** `-DryRun -ISO D -Index N -Keep X` returns the
  full plan in seconds — the controller and the user can diff plans without a 30-minute build.
- **Real build (Windows):** one `-Fast` smoke per script (confirms fast compression + skipped
  cleanup still yields a bootable ISO and, for Core, the integrity gate still runs); one default
  (`recovery`) build occasionally to confirm parity with today.

## Sequencing

Both scripts, but feature order favors the user's stated priority (A then B):
1. `-DryRun` (Core, then maker) — biggest iteration win.
2. `-Fast` + `-Compress` (Core, then maker).
3. robocopy copy (both).
4. maker `-Index`/`-Yes` parity.
5. Docs.

All work continues on `harden/core-error-handling`.
