# End-of-Build Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print a compact BUILD SUMMARY (result, elapsed, ISO path+size, provisioned Appx removed, non-fatal warnings) at the end of a successful build in both scripts.

**Architecture:** A pure `Format-BuildSummary` helper (unit-tested from both scripts) renders the block from primitives. Thin script-body glue captures a start time, increments an app-removed counter and a warning counter at existing sites, reads the ISO size, and emits the block right before "Creation completed!".

**Tech Stack:** Windows PowerShell 5.1, DISM.

## Global Constraints

- **Target runtime Windows PowerShell 5.1** — no PS7-only syntax (no ternary `? :`, no `??`). Inline `$(if(){}else{})`, `1GB`, `[math]::Floor`, `New-TimeSpan`, `-f` formatting are all fine.
- **ASCII only** — the summary block uses plain `=`, `:`, `()`.
- **Parity:** `Format-BuildSummary` must be BYTE-IDENTICAL in both scripts. The summary block, counters, and emit logic behave identically (allowing `Write-Host` in Core vs `Write-Output` in maker).
- **Variable names are CASE-INSENSITIVE** — do not introduce names colliding with params; use `$buildStart`, `$appsRemoved`, `$appsTotal`, `$script:buildWarnings`.
- **Success path only:** the summary asserts SUCCESS and is emitted only after the ISO is created. Do not add a summary to any failure/abort path.
- **Do not change what gets removed** — only count what already happens (maker gains a warn-and-continue on failed Appx removal, which adds visibility + a count, not a behavior change to removals).

---

### Task 1: Core — `Format-BuildSummary` helper, unit tests, and wiring

**Files:**
- Modify: `tiny11Coremaker.ps1` — add the helper; capture start time + init warning counter; add Appx-removed + warning counters at existing sites; emit the block before "Creation completed!".
- Modify: `scripts/test-core-helpers.ps1` — add `Format-BuildSummary` unit tests.

**Interfaces:**
- Produces (consumed by Task 2 and the emit site): `Format-BuildSummary([timespan]$Elapsed, [long]$IsoBytes, [string]$IsoPath, [int]$AppsRemoved, [int]$AppsTotal, [int]$Warnings)` -> `[string[]]` (the summary block lines).

- [ ] **Step 1: Write the failing tests**

In `scripts/test-core-helpers.ps1`, immediately AFTER the last `Resolve-OscdimgSource` Check line (`Check 'download last' ...`) and BEFORE the `Write-Host '== maker parity ...'` line, insert:

```powershell
Write-Host '== Format-BuildSummary =='
$bs = Format-BuildSummary -Elapsed (New-TimeSpan -Minutes 27 -Seconds 41) -IsoBytes 4070127616 -IsoPath 'C:\x\tiny11.iso' -AppsRemoved 31 -AppsTotal 33 -Warnings 2
Check 'summary result line'   ($bs -contains '  Result        : SUCCESS')
Check 'summary elapsed line'  ($bs -contains '  Elapsed       : 27m 41s')
Check 'summary iso/size line' ($bs -contains '  Output ISO    : C:\x\tiny11.iso  (3.79 GB)')
Check 'summary apps line'     ($bs -contains '  Apps removed  : 31 of 33 provisioned Appx')
Check 'summary warn line'     ($bs -contains '  Warnings      : 2 non-fatal (see log)')
Check 'summary header'        ($bs -contains '===== BUILD SUMMARY =====')
$bs0 = Format-BuildSummary -Elapsed (New-TimeSpan -Minutes 5 -Seconds 3) -IsoBytes 2147483648 -IsoPath 'C:\a.iso' -AppsRemoved 0 -AppsTotal 0 -Warnings 0
Check 'summary warn none'     ($bs0 -contains '  Warnings      : none')
Check 'summary size 2.00 GB'  ($bs0 -contains '  Output ISO    : C:\a.iso  (2.00 GB)')
Check 'summary elapsed 5m 3s' ($bs0 -contains '  Elapsed       : 5m 3s')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'Format-BuildSummary' is not recognized".

- [ ] **Step 3: Add the helper**

In `tiny11Coremaker.ps1`, immediately after the closing `}` of the `Resolve-OscdimgSource` function (the last helper before `Start-Transcript`), insert:

```powershell
function Format-BuildSummary {
    # Pure: renders the end-of-build summary block from primitives. Caller writes
    # each returned line (Write-Host in Core, Write-Output in maker).
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (n = prior 78 + 9 new).

- [ ] **Step 5: Capture start time and init the warning counter**

In `tiny11Coremaker.ps1`, immediately AFTER the `Start-Transcript -Path "$PSScriptRoot\tiny11.log"` line, insert:

```powershell
$buildStart = Get-Date
$script:buildWarnings = 0
```

- [ ] **Step 6: Count the oscdimg pre-flight warning**

Find the pre-flight oscdimg warn block and add the counter increment:

```powershell
if (-not $oscdimgOk) {
    Write-Warning "Neither the Windows ADK nor a bundled oscdimg.exe was found; the ISO step will attempt to download oscdimg.exe at the end of the build."
    $script:buildWarnings++
}
```

- [ ] **Step 7: Add Appx-removed + warning counters to the provisioned-Appx loop**

Replace the provisioned-Appx removal loop:

```powershell
foreach ($package in $packagesToRemove) {
    write-host "Removing $package :"
    & 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
    if ($LASTEXITCODE -ne 0) { Write-Host "  warning: could not remove $package (exit $LASTEXITCODE), continuing." }
}
```

with (capture the total before the loop, count successes and warnings):

```powershell
$appsTotal   = @($packagesToRemove).Count
$appsRemoved = 0
foreach ($package in $packagesToRemove) {
    write-host "Removing $package :"
    & 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  warning: could not remove $package (exit $LASTEXITCODE), continuing."
        $script:buildWarnings++
    } else {
        $appsRemoved++
    }
}
```

- [ ] **Step 8: Count the system-package removal warnings**

In the system-package removal loop, update the warn branch to also increment the counter:

```powershell
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  warning: could not remove $packageIdentity (exit $LASTEXITCODE), continuing."
            $script:buildWarnings++
        }
```

- [ ] **Step 9: Count the WinSxS allowlist warning**

In the WinSxS copy loop, update the allowlist-miss warning:

```powershell
        if ($sourceDirs.Count -eq 0) {
            Write-Warning "WinSxS allowlist pattern matched nothing: $dir"
            $script:buildWarnings++
        }
```

- [ ] **Step 10: Emit the summary before "Creation completed!"**

Immediately BEFORE the `# Finishing up` comment / `Write-Host "Creation completed! Press any key to exit the script..."` line, insert:

```powershell
$elapsed  = (Get-Date) - $buildStart
$isoPath  = "$PSScriptRoot\tiny11.iso"
$isoBytes = if (Test-Path $isoPath) { (Get-Item $isoPath).Length } else { 0 }
Format-BuildSummary -Elapsed $elapsed -IsoBytes $isoBytes -IsoPath $isoPath -AppsRemoved $appsRemoved -AppsTotal $appsTotal -Warnings $script:buildWarnings |
    ForEach-Object { Write-Host $_ }
```

- [ ] **Step 11: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11Coremaker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for Core (skip locally if PSScriptAnalyzer absent — CI enforces it)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`

Note: the body glue calls `dism`/`Get-Item`, unavailable on macOS — the script body is not runnable here; the helper is unit-tested and the wiring is parse/lint-gated + CI + real-Windows validated.

- [ ] **Step 12: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): end-of-build summary (elapsed/size/apps/warnings)"
```

---

### Task 2: maker — `Format-BuildSummary` helper (parity), parity test, and wiring

**Files:**
- Modify: `tiny11maker.ps1` — add the helper (copied verbatim from Core); capture start time + init warning counter; add exit-check + Appx-removed + warning counters to the Appx loop; count the oscdimg warning; emit the block before "Creation completed!".
- Modify: `scripts/test-core-helpers.ps1` — extend the maker-parity extraction list + add a `Format-BuildSummary` parity check.

**Interfaces:**
- Consumes (from Task 1): `Format-BuildSummary` (copy the exact committed body from `tiny11Coremaker.ps1`).

- [ ] **Step 1: Write the failing parity test**

In `scripts/test-core-helpers.ps1`, in the maker-parity section, extend the extraction `Where-Object` filter to also include `'Format-BuildSummary'`:

```powershell
    Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded', 'Get-AvailableImageIndex', 'Test-ImageIndexAvailable', 'Get-RequiredScratchBytes', 'Test-SufficientScratch', 'Resolve-OscdimgSource', 'Format-BuildSummary' } |
```

Then add, after the last existing maker-parity Check line:

```powershell
$mSummary = maker_Format-BuildSummary -Elapsed (New-TimeSpan -Minutes 1 -Seconds 2) -IsoBytes 1073741824 -IsoPath 'C:\a.iso' -AppsRemoved 5 -AppsTotal 5 -Warnings 0
Check 'maker summary success'  ($mSummary -contains '  Result        : SUCCESS')
Check 'maker summary size 1GB' ($mSummary -contains '  Output ISO    : C:\a.iso  (1.00 GB)')
Check 'maker summary apps 5/5' ($mSummary -contains '  Apps removed  : 5 of 5 provisioned Appx')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'maker_Format-BuildSummary' is not recognized".

- [ ] **Step 3: Add the helper (verbatim from Core)**

Open `tiny11Coremaker.ps1`, copy the ENTIRE `Format-BuildSummary` function body verbatim, and paste it into `tiny11maker.ps1` immediately after the closing `}` of the `Resolve-OscdimgSource` function. The two copies must be byte-identical.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (n grows by the 3 maker parity checks).

- [ ] **Step 5: Capture start time and init the warning counter**

In `tiny11maker.ps1`, immediately AFTER the `Start-Transcript -Path "$PSScriptRoot\tiny11_$(get-date -f yyyyMMdd_HHmms).log"` line, insert:

```powershell
$buildStart = Get-Date
$script:buildWarnings = 0
```

- [ ] **Step 6: Count the oscdimg pre-flight warning**

Update maker's pre-flight oscdimg warn block:

```powershell
if (-not $oscdimgOk) {
    Write-Warning "Neither the Windows ADK nor a bundled oscdimg.exe was found; the ISO step will attempt to download oscdimg.exe at the end of the build."
    $script:buildWarnings++
}
```

- [ ] **Step 7: Add exit-check + counters to the Appx loop**

Replace maker's provisioned-Appx removal loop:

```powershell
foreach ($package in $packagesToRemove) {
    & 'dism' '/English' "/image:$($ScratchDisk)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
}
```

with (adds a warn-and-continue for parity with Core, plus the counters):

```powershell
$appsTotal   = @($packagesToRemove).Count
$appsRemoved = 0
foreach ($package in $packagesToRemove) {
    & 'dism' '/English' "/image:$($ScratchDisk)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
    if ($LASTEXITCODE -ne 0) {
        Write-Output "  warning: could not remove $package (exit $LASTEXITCODE), continuing."
        $script:buildWarnings++
    } else {
        $appsRemoved++
    }
}
```

- [ ] **Step 8: Emit the summary before "Creation completed!"**

Immediately BEFORE the `# Finishing up` comment / `Write-Output "Creation completed!"` line, insert:

```powershell
$elapsed  = (Get-Date) - $buildStart
$isoPath  = "$PSScriptRoot\tiny11.iso"
$isoBytes = if (Test-Path $isoPath) { (Get-Item $isoPath).Length } else { 0 }
Format-BuildSummary -Elapsed $elapsed -IsoBytes $isoBytes -IsoPath $isoPath -AppsRemoved $appsRemoved -AppsTotal $appsTotal -Warnings $script:buildWarnings |
    ForEach-Object { Write-Output $_ }
```

- [ ] **Step 9: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11maker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for maker (skip locally if module absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`

- [ ] **Step 10: Commit**

```bash
git add tiny11maker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(maker): end-of-build summary (parity with core)"
```

---

## Notes for the executor

- Base for the increment: current `harden/core-error-handling` HEAD.
- After both tasks: final whole-branch review over the increment, then finishing-a-development-branch (push/PR/merge to fork main). The `YmlyZA` account is now the persistent active account for this repo (do NOT switch back to thunderbird-ns). It already has the `workflow` scope.
- Real-machine close-out (user, Windows): a build should end with the BUILD SUMMARY block showing sane elapsed/size/apps/warnings just before "Creation completed!".
