# Robustness (ESD index + verified ISO) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the multi-edition ESD mount-index mismatch, make "SUCCESS" truthful by verifying the ISO was produced, and make the summary's size field locale-safe — in both scripts, at parity.

**Architecture:** (A) one line remapping `$imageIndex = 1` after the ESD->WIM export; (B) a pure `Test-IsoResult` helper plus a post-`oscdimg` throw when no valid ISO exists; (C) an InvariantCulture render in the existing `Format-BuildSummary`.

**Tech Stack:** Windows PowerShell 5.1, DISM, oscdimg.

## Global Constraints

- **Target runtime Windows PowerShell 5.1** — no PS7-only syntax (no ternary `? :`, no `??`). Inline `$(if(){}else{})`, `[long]`, `.ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture)` are valid.
- **ASCII only.**
- **Parity:** `Test-IsoResult` and `Format-BuildSummary` must be BYTE-IDENTICAL in both scripts. The ESD remap and the ISO-verification wiring behave identically (allowing Core's `Invoke-Dism`/`Write-Host` vs maker's `Export-WindowsImage`/`Write-Output`).
- **Variable names are CASE-INSENSITIVE** — the ISO-verification block uses `$isoExit`/`$isoResult`/`$isoOk`/`$isoLen` (deliberately distinct from the summary block's `$isoPath`/`$isoBytes`). Never introduce a lowercase `$index`.
- **ESD remap runs in the `install.esd` branch only** — WIM-based ISOs keep their real per-edition indices.

---

### Task 1: Core — `Test-IsoResult` helper + tests, ESD remap, ISO verification, locale-safe size

**Files:**
- Modify: `tiny11Coremaker.ps1`
- Modify: `scripts/test-core-helpers.ps1`

**Interfaces:**
- Produces: `Test-IsoResult([int]$ExitCode, [bool]$IsoExists, [long]$IsoBytes) -> [bool]` (consumed by the ISO-verification wiring and Task 2).

- [ ] **Step 1: Write the failing tests**

In `scripts/test-core-helpers.ps1`, immediately AFTER the last `Format-BuildSummary` Check line (`Check 'summary elapsed 5m 3s' ...`) and BEFORE the `Write-Host '== maker parity ...'` line, insert:

```powershell
Write-Host '== Test-IsoResult =='
Check 'iso ok'           (Test-IsoResult -ExitCode 0 -IsoExists $true  -IsoBytes 100)
Check 'iso bad exit'     (-not (Test-IsoResult -ExitCode 1 -IsoExists $true  -IsoBytes 100))
Check 'iso missing file' (-not (Test-IsoResult -ExitCode 0 -IsoExists $false -IsoBytes 0))
Check 'iso empty file'   (-not (Test-IsoResult -ExitCode 0 -IsoExists $true  -IsoBytes 0))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'Test-IsoResult' is not recognized".

- [ ] **Step 3: Add the helper**

In `tiny11Coremaker.ps1`, immediately after the closing `}` of the `Format-BuildSummary` function, insert:

```powershell
function Test-IsoResult {
    # The ISO step succeeded only if oscdimg exited 0 AND a non-empty file exists.
    param([int]$ExitCode, [bool]$IsoExists, [long]$IsoBytes)
    return ($ExitCode -eq 0 -and $IsoExists -and $IsoBytes -gt 0)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (n = prior 90 + 4 new = 94).

- [ ] **Step 5: (A) Remap the index after the ESD->WIM export**

Find the ESD conversion line (inside the `if ((Test-Path "$DriveLetter\sources\install.esd") ...)` branch):

```powershell
        Invoke-Dism /Export-Image /SourceImageFile:"$DriveLetter\sources\install.esd" /SourceIndex:$imageIndex /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.wim" /Compress:max /CheckIntegrity
```

Immediately AFTER that line (same indentation, still inside the branch), insert:

```powershell
        # The exported WIM holds the chosen edition as its only image (index 1);
        # mount and re-export must target index 1, not the source ESD's index.
        $imageIndex = 1
```

- [ ] **Step 6: (C) Locale-safe size in `Format-BuildSummary`**

In the `Format-BuildSummary` function, replace:

```powershell
    $sizeText    = "{0:N2} GB" -f ($IsoBytes / 1GB)
```

with:

```powershell
    $sizeText    = "{0} GB" -f (($IsoBytes / 1GB).ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture))
```

- [ ] **Step 7: (B) Verify the ISO after oscdimg**

Find the oscdimg invocation:

```powershell
& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"
```

Immediately AFTER that line, insert:

```powershell
$isoExit   = $LASTEXITCODE
$isoResult = "$PSScriptRoot\tiny11.iso"
$isoOk     = Test-Path $isoResult
$isoLen    = if ($isoOk) { (Get-Item $isoResult).Length } else { [long]0 }
if (-not (Test-IsoResult -ExitCode $isoExit -IsoExists $isoOk -IsoBytes $isoLen)) {
    throw "ISO creation failed (oscdimg exit $isoExit); no valid tiny11.iso was produced at $isoResult."
}
```

(`$isoExit = $LASTEXITCODE` MUST be the first statement after the oscdimg call so nothing else overwrites `$LASTEXITCODE`.)

- [ ] **Step 8: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11Coremaker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for Core (skip locally if PSScriptAnalyzer absent — CI enforces it)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`

Note: the body calls `dism`/`oscdimg`/`Get-Item`, unavailable on macOS — the script body is not runnable here; the helper is unit-tested and the wiring is parse/lint-gated + CI + real-Windows validated.

- [ ] **Step 9: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "fix(core): ESD index remap + verify ISO created + locale-safe size"
```

---

### Task 2: maker — `Test-IsoResult` (parity) + parity test, ESD remap, ISO verification, locale-safe size

**Files:**
- Modify: `tiny11maker.ps1`
- Modify: `scripts/test-core-helpers.ps1`

**Interfaces:**
- Consumes (from Task 1): `Test-IsoResult` (copy the exact committed body from `tiny11Coremaker.ps1`) and the updated `Format-BuildSummary` `$sizeText` line.

- [ ] **Step 1: Write the failing parity test**

In `scripts/test-core-helpers.ps1`, extend the maker-parity extraction `Where-Object` filter to also include `'Test-IsoResult'`:

```powershell
    Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded', 'Get-AvailableImageIndex', 'Test-ImageIndexAvailable', 'Get-RequiredScratchBytes', 'Test-SufficientScratch', 'Resolve-OscdimgSource', 'Format-BuildSummary', 'Test-IsoResult' } |
```

Then add, after the last existing maker-parity Check line:

```powershell
Check 'maker iso ok'       (maker_Test-IsoResult -ExitCode 0 -IsoExists $true -IsoBytes 100)
Check 'maker iso bad exit' (-not (maker_Test-IsoResult -ExitCode 1 -IsoExists $true -IsoBytes 100))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'maker_Test-IsoResult' is not recognized".

- [ ] **Step 3: Add the helper (verbatim from Core)**

Open `tiny11Coremaker.ps1`, copy its `Test-IsoResult` function VERBATIM, and paste it into `tiny11maker.ps1` immediately after the closing `}` of `Format-BuildSummary`. Byte-identical.

- [ ] **Step 4: (C) Make maker's `Format-BuildSummary` size line match Core**

In maker's `Format-BuildSummary`, replace:

```powershell
    $sizeText    = "{0:N2} GB" -f ($IsoBytes / 1GB)
```

with (identical to Core's Task 1 Step 6):

```powershell
    $sizeText    = "{0} GB" -f (($IsoBytes / 1GB).ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture))
```

The two `Format-BuildSummary` copies must remain byte-identical.

- [ ] **Step 5: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (n grows by the 2 maker parity checks).

- [ ] **Step 6: (A) Remap the index after the ESD->WIM export**

Find maker's ESD conversion line (inside the `install.esd` branch):

```powershell
        Export-WindowsImage -SourceImagePath $DriveLetter\sources\install.esd -SourceIndex $imageIndex -DestinationImagePath $ScratchDisk\tiny11\sources\install.wim -Compressiontype Maximum -CheckIntegrity
```

Immediately AFTER that line (same indentation, still inside the branch), insert:

```powershell
        # The exported WIM holds the chosen edition as its only image (index 1);
        # mount and re-export must target index 1, not the source ESD's index.
        $imageIndex = 1
```

- [ ] **Step 7: (B) Verify the ISO after oscdimg**

Find maker's oscdimg invocation:

```powershell
& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"
```

Immediately AFTER that line, insert (identical to Core, no functional difference):

```powershell
$isoExit   = $LASTEXITCODE
$isoResult = "$PSScriptRoot\tiny11.iso"
$isoOk     = Test-Path $isoResult
$isoLen    = if ($isoOk) { (Get-Item $isoResult).Length } else { [long]0 }
if (-not (Test-IsoResult -ExitCode $isoExit -IsoExists $isoOk -IsoBytes $isoLen)) {
    throw "ISO creation failed (oscdimg exit $isoExit); no valid tiny11.iso was produced at $isoResult."
}
```

- [ ] **Step 8: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11maker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for maker (skip locally if module absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`

- [ ] **Step 9: Commit**

```bash
git add tiny11maker.ps1 scripts/test-core-helpers.ps1
git commit -m "fix(maker): ESD index remap + verify ISO created + locale-safe size"
```

---

## Notes for the executor

- Base for the increment: current `harden/core-error-handling` HEAD.
- After both tasks: final whole-branch review, then finishing-a-development-branch (push/PR/merge to fork main; CI gates the PR). The `YmlyZA` account is the persistent active account for this repo (do NOT restore thunderbird-ns); it has the `workflow` scope.
- Real-machine close-out (user, Windows): a multi-edition ESD ISO with a chosen index != 1 now builds the chosen edition; a normal build still ends with a valid ISO + summary; a forced oscdimg failure now aborts with the new error instead of "Creation completed!".
