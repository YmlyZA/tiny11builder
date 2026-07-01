# Speed & Testability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `-DryRun`, `-Compress`, `-Fast`, a multithreaded copy, and (maker) `-Index`/`-Yes` to BOTH `tiny11Coremaker.ps1` and `tiny11maker.ps1`, so script logic can be validated in seconds and builds run faster — without changing default behavior.

**Architecture:** Pure decision logic (compression/profile resolution, robocopy exit-code classification) lives in small functions added to each script and unit-tested on macOS via AST extraction (the existing `scripts/test-core-helpers.ps1` pattern). The interactive/Windows-only wiring (param blocks, robocopy, export/cleanup gating, dry-run print/exit) is gated by parse-check + linter + grep. Both scripts are kept at parity; helpers are duplicated (the project ships each script standalone — no shared module).

**Tech Stack:** Windows PowerShell 5.1 (runtime) / PowerShell 7.x (local static checks), DISM, robocopy, reg, oscdimg. Tests via `pwsh` + `scripts/parse-check.ps1` + `scripts/linter.ps1` + `scripts/test-core-helpers.ps1`.

## Global Constraints

- Target runtime is **Windows PowerShell 5.1**; all code must be 5.1-compatible (no PS7-only syntax).
- Scripts stay **ASCII-only**.
- Microsoft tools only (DISM/reg/oscdimg/robocopy — robocopy is built-in).
- **Default behavior must not change:** with no new flags, both scripts behave exactly as today (`-Compress` defaults to `recovery`; `-Fast`/`-DryRun` off).
- `-Compress` valid values are exactly `recovery`, `fast`, `none`.
- `-Fast` ⇒ compression `fast` + skip `Cleanup-Image /StartComponentCleanup /ResetBase`, but KEEPS the WinSxS rebuild (Core). An explicit `-Compress` overrides `-Fast`'s compression.
- `-DryRun` resolves inputs + validations + (Core) optional-utility resolution, prints the plan, and exits 0 **before** any copy/mount.
- robocopy exit codes **0–7 = success**, **>=8 = failure**.
- Non-goals: parallelizing DISM; automating a RAMDisk; giving maker the Core optional-utility picker/`-Keep`/`-Remove`.
- After every code change: `pwsh -NoProfile -File scripts/parse-check.ps1` prints `[OK]` for both scripts, `pwsh -NoProfile -File scripts/linter.ps1` shows `0 high-signal finding(s)` for both, and `pwsh -NoProfile -File scripts/test-core-helpers.ps1` reports `0 failed`.
- All work stays on branch `harden/core-error-handling`. `pwsh` is at `/opt/homebrew/bin/pwsh`.

---

## File Structure

- `tiny11Coremaker.ps1` — modified: add `Resolve-BuildProfile`, `Test-RobocopySucceeded`, `Invoke-Robocopy`, `Get-AlwaysRemovePackages` to the helper block; add `-DryRun`/`-Compress`/`-Fast` params; robocopy copy; profile-gated export/cleanup; dry-run print/exit.
- `tiny11maker.ps1` — modified: add the same four helpers; add `-DryRun`/`-Compress`/`-Fast`/`-Index`/`-Yes` params; robocopy copy; profile-gated export/cleanup; `-Index`/`-Yes` wiring; dry-run print/exit.
- `scripts/test-core-helpers.ps1` — modified: unit tests for the pure helpers, loaded from BOTH scripts (parity).

---

## Task 1: Pure helpers in Core (`Resolve-BuildProfile`, robocopy classifier) + tests

**Files:**
- Modify: `tiny11Coremaker.ps1` (helper-functions block, after `Assert-WinSxSRebuild`)
- Modify: `scripts/test-core-helpers.ps1` (append tests)

**Interfaces:**
- Produces: `Resolve-BuildProfile([string]$Compress, [switch]$Fast)` → `[pscustomobject]@{ Compress; SkipCleanup; UseEsd; WimExportCompress }`. Throws on an invalid `$Compress`.
- Produces: `Test-RobocopySucceeded([int]$ExitCode)` → `[bool]` (`$ExitCode -lt 8`).
- Produces: `Invoke-Robocopy([string]$Source, [string]$Destination)` → runs robocopy `/E /MT`; throws if `Test-RobocopySucceeded` is false; resets `$LASTEXITCODE` to 0 on success.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-core-helpers.ps1`, BEFORE the final `Write-Host ""`/RESULT block:

```powershell
Write-Host '== Resolve-BuildProfile =='
$p = Resolve-BuildProfile
Check 'default compress recovery'      ($p.Compress -eq 'recovery')
Check 'default does not skip cleanup'  ($p.SkipCleanup -eq $false)
Check 'default uses esd'               ($p.UseEsd -eq $true)
Check 'default wim export max'         ($p.WimExportCompress -eq 'max')
$p = Resolve-BuildProfile -Fast
Check '-Fast compress fast'            ($p.Compress -eq 'fast')
Check '-Fast skips cleanup'            ($p.SkipCleanup -eq $true)
Check '-Fast no esd'                   ($p.UseEsd -eq $false)
Check '-Fast wim export fast'          ($p.WimExportCompress -eq 'fast')
$p = Resolve-BuildProfile -Compress 'none'
Check '-Compress none'                 ($p.Compress -eq 'none')
Check '-Compress none no esd'          ($p.UseEsd -eq $false)
Check '-Compress none not skipclean'   ($p.SkipCleanup -eq $false)
$p = Resolve-BuildProfile -Compress 'none' -Fast
Check 'explicit compress overrides Fast' ($p.Compress -eq 'none')
Check 'Fast still skips cleanup w/ explicit compress' ($p.SkipCleanup -eq $true)
CheckThrows 'invalid compress throws'  { Resolve-BuildProfile -Compress 'zip' }

Write-Host '== Test-RobocopySucceeded =='
Check 'rc 0 success'  (Test-RobocopySucceeded 0)
Check 'rc 1 success'  (Test-RobocopySucceeded 1)
Check 'rc 7 success'  (Test-RobocopySucceeded 7)
Check 'rc 8 failure'  (-not (Test-RobocopySucceeded 8))
Check 'rc 16 failure' (-not (Test-RobocopySucceeded 16))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — `Resolve-BuildProfile` / `Test-RobocopySucceeded` not defined.

- [ ] **Step 3: Add the helpers**

In `tiny11Coremaker.ps1`, insert immediately AFTER `Assert-WinSxSRebuild`'s closing `}`:

```powershell
function Resolve-BuildProfile {
    # Resolve the effective image-compression settings from -Compress and -Fast.
    # Default is 'recovery' (current behavior). -Fast implies 'fast' unless -Compress
    # is given explicitly. WimExportCompress is the value for the intermediate WIM
    # re-export ('max' for the recovery profile, else the effective value); UseEsd is
    # true only for 'recovery' (the final ESD conversion stage).
    param([string]$Compress, [switch]$Fast)
    $valid = 'recovery', 'fast', 'none'
    if ($Compress -and ($valid -notcontains $Compress)) {
        throw "Invalid -Compress '$Compress'. Valid values: $($valid -join ', ')"
    }
    $effective = if ($Compress) { $Compress } elseif ($Fast) { 'fast' } else { 'recovery' }
    [pscustomobject]@{
        Compress          = $effective
        SkipCleanup       = [bool]$Fast
        UseEsd            = ($effective -eq 'recovery')
        WimExportCompress = if ($effective -eq 'recovery') { 'max' } else { $effective }
    }
}

function Test-RobocopySucceeded {
    # robocopy uses exit codes 0-7 for success (files copied, extras, etc.) and
    # >=8 for genuine failures.
    param([int]$ExitCode)
    return ($ExitCode -lt 8)
}

function Invoke-Robocopy {
    # Multithreaded recursive copy. robocopy is a built-in Microsoft tool and is far
    # faster than Copy-Item for the ~6 GB ISO copy. Throws on a real failure; resets
    # $LASTEXITCODE to 0 on success so downstream exit-code checks are not confused.
    param([Parameter(Mandatory = $true)][string]$Source,
          [Parameter(Mandatory = $true)][string]$Destination)
    & robocopy.exe $Source $Destination '/E' '/MT' '/R:3' '/W:3' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
    if (-not (Test-RobocopySucceeded $LASTEXITCODE)) {
        throw "robocopy failed (exit code $LASTEXITCODE) copying '$Source' -> '$Destination'."
    }
    $global:LASTEXITCODE = 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed`.

- [ ] **Step 5: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` for both scripts.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11Coremaker.ps1.

- [ ] **Step 6: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): build-profile + robocopy helpers (pure, tested)"
```

---

## Task 2: Core — params, build profile, and extract `Get-AlwaysRemovePackages`

**Files:**
- Modify: `tiny11Coremaker.ps1` (param block; UAC forwarding; after `$ScratchDisk`; the `$packagePrefixes` definition in the removal section)
- Modify: `scripts/test-core-helpers.ps1` (one test for `Get-AlwaysRemovePackages`)

**Interfaces:**
- Consumes: `Resolve-BuildProfile` (Task 1).
- Produces: script-scope `$DryRun`, `$Compress`, `$Fast`, `$buildProfile`; `Get-AlwaysRemovePackages()` → `string[]` (the always-remove provisioned-Appx prefixes, no optional-utility prefixes).

- [ ] **Step 1: Add the new parameters to the `param()` block**

In `tiny11Coremaker.ps1`, find the param block and add three entries. Find:
```
    [string[]]$Keep = @(),
    [string[]]$Remove = @(),
    [switch]$Yes
)
```
Replace with:
```
    [string[]]$Keep = @(),
    [string[]]$Remove = @(),
    [switch]$Yes,
    [switch]$DryRun,
    [ValidateSet('recovery', 'fast', 'none')][string]$Compress,
    [switch]$Fast
)
```

- [ ] **Step 2: Forward the new params across the UAC relaunch**

Find:
```
    if ($Yes)        { $argList += " -Yes" }
    $newProcess.Arguments = $argList;
```
Replace with:
```
    if ($Yes)        { $argList += " -Yes" }
    if ($DryRun)     { $argList += " -DryRun" }
    if ($Compress)   { $argList += " -Compress $Compress" }
    if ($Fast)       { $argList += " -Fast" }
    $newProcess.Arguments = $argList;
```

- [ ] **Step 3: Compute the build profile after `$ScratchDisk`**

Find:
```
$ScratchDisk = $mainOSDrive
```
Replace with:
```
$ScratchDisk = $mainOSDrive
$buildProfile = Resolve-BuildProfile -Compress $Compress -Fast:$Fast
```

- [ ] **Step 4: Extract the always-remove list into a function**

Add this function to the helper block (immediately AFTER `Invoke-Robocopy` from Task 1):
```powershell
function Get-AlwaysRemovePackages {
    # Always-remove provisioned-Appx prefixes (bloat). The optional standalone
    # utilities are handled separately via Get-OptionalUtilities / the picker /
    # -Keep / -Remove, so none of them appear here.
    @(
        'Clipchamp.Clipchamp_',
        'Microsoft.BingNews_',
        'Microsoft.BingSearch_',
        'Microsoft.BingWeather_',
        'Microsoft.GamingApp_',
        'Microsoft.GetHelp_',
        'Microsoft.Getstarted_',
        'Microsoft.MicrosoftOfficeHub_',
        'Microsoft.MicrosoftSolitaireCollection_',
        'Microsoft.People_',
        'Microsoft.PowerAutomateDesktop_',
        'Microsoft.Todos_',
        'microsoft.windowscommunicationsapps_',
        'Microsoft.WindowsFeedbackHub_',
        'Microsoft.WindowsMaps_',
        'Microsoft.Xbox.TCUI_',
        'Microsoft.XboxGamingOverlay_',
        'Microsoft.XboxGameOverlay_',
        'Microsoft.XboxSpeechToTextOverlay_',
        'Microsoft.XboxIdentityProvider_',
        'Microsoft.YourPhone_',
        'MicrosoftCorporationII.MicrosoftFamily_',
        'MicrosoftCorporationII.QuickAssist_',
        'MicrosoftTeams_',
        'MSTeams_',
        'Microsoft.Windows.Teams_',
        'Microsoft.549981C3F5F10_',
        'Microsoft.Copilot_',
        'Microsoft.Windows.Copilot',
        'Microsoft.Windows.DevHome_',
        'Microsoft.Windows.CrossDevice_',
        'Microsoft.OutlookForWindows_',
        'MicrosoftWindows.Client.WebExperience_'
    )
}
```

Then, in the removal section, find the inline base-list assignment (the block that begins with the comment `# Always-remove bloat.` and the `$packagePrefixes = @(` array literal ending in `'MicrosoftWindows.Client.WebExperience_'\n)`), and replace that whole block with:
```powershell
# Always-remove bloat comes from Get-AlwaysRemovePackages (single source of truth,
# also used by -DryRun). Optional utilities are merged in by the picker block below.
$packagePrefixes = Get-AlwaysRemovePackages
```

- [ ] **Step 5: Add a test for `Get-AlwaysRemovePackages`**

Append to `scripts/test-core-helpers.ps1` before the RESULT block:
```powershell
Write-Host '== Get-AlwaysRemovePackages =='
$base = Get-AlwaysRemovePackages
Check 'base list non-empty'          ($base.Count -gt 0)
Check 'base excludes Terminal'       (-not ($base -match 'WindowsTerminal'))
Check 'base excludes Calculator'     (-not ($base -match 'WindowsCalculator'))
Check 'base excludes Notepad'        (-not ($base -match 'WindowsNotepad'))
Check 'base excludes Photos'         (-not ($base -match 'Windows\.Photos'))
```

- [ ] **Step 6: Run tests + static checks**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed`.
Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11Coremaker.ps1.

- [ ] **Step 7: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): -DryRun/-Compress/-Fast params + Get-AlwaysRemovePackages extraction"
```

---

## Task 3: Core — robocopy copy + profile-gated export/cleanup

**Files:**
- Modify: `tiny11Coremaker.ps1` (the ISO copy; the Cleanup-Image step; the two export stages)

**Interfaces:**
- Consumes: `Invoke-Robocopy`, `$buildProfile` (Tasks 1-2).

- [ ] **Step 1: Replace the ISO copy with robocopy**

Find:
```
Write-Host "Copying Windows image..."
Copy-Item -Path "$DriveLetter\*" -Destination "$mainOSDrive\tiny11" -Recurse -Force > $null
```
Replace with:
```
Write-Host "Copying Windows image..."
Invoke-Robocopy -Source "$DriveLetter\" -Destination "$mainOSDrive\tiny11"
```

- [ ] **Step 2: Gate the Cleanup-Image/ResetBase on the profile**

Find:
```
Write-Host "Cleaning up image..."
& 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' > $null
Write-Host "Cleanup complete."
```
Replace with:
```
if ($buildProfile.SkipCleanup) {
    Write-Host "Skipping component cleanup (-Fast)."
} else {
    Write-Host "Cleaning up image..."
    & 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' > $null
    Write-Host "Cleanup complete."
}
```

- [ ] **Step 3: Apply the chosen compression to the intermediate WIM re-export**

Find:
```
Write-Host "Exporting image..."
Invoke-Dism '/English' '/Export-Image' "/SourceImageFile:$mainOSDrive\tiny11\sources\install.wim" "/SourceIndex:$imageIndex" "/DestinationImageFile:$mainOSDrive\tiny11\sources\install2.wim" '/compress:max'
```
Replace with:
```
Write-Host "Exporting image (compress: $($buildProfile.WimExportCompress))..."
Invoke-Dism '/English' '/Export-Image' "/SourceImageFile:$mainOSDrive\tiny11\sources\install.wim" "/SourceIndex:$imageIndex" "/DestinationImageFile:$mainOSDrive\tiny11\sources\install2.wim" "/compress:$($buildProfile.WimExportCompress)"
```

- [ ] **Step 4: Make the final ESD conversion conditional on the profile**

Find:
```
Clear-Host
Write-Host "Exporting ESD. This may take a while..."
Invoke-Dism /Export-Image /SourceImageFile:"$mainOSDrive\tiny11\sources\install.wim" /SourceIndex:1 /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.esd" /Compress:recovery
Remove-Item "$mainOSDrive\tiny11\sources\install.wim" > $null 2>&1
```
Replace with:
```
Clear-Host
if ($buildProfile.UseEsd) {
    Write-Host "Exporting ESD. This may take a while..."
    Invoke-Dism /Export-Image /SourceImageFile:"$mainOSDrive\tiny11\sources\install.wim" /SourceIndex:1 /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.esd" /Compress:recovery
    Remove-Item "$mainOSDrive\tiny11\sources\install.wim" > $null 2>&1
} else {
    Write-Host "Keeping install.wim (compress: $($buildProfile.Compress)); skipping ESD conversion."
}
```

- [ ] **Step 5: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11Coremaker.ps1.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed`.

- [ ] **Step 6: Grep assertions**

Run: `grep -c 'Invoke-Robocopy -Source' tiny11Coremaker.ps1` → `1`.
Run: `grep -c 'buildProfile.SkipCleanup\|buildProfile.UseEsd\|buildProfile.WimExportCompress' tiny11Coremaker.ps1` → `3`.

- [ ] **Step 7: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): robocopy copy + profile-gated compression/cleanup"
```

---

## Task 4: Core — `-DryRun` plan and early exit

**Files:**
- Modify: `tiny11Coremaker.ps1` (insert a dry-run block before the `try {`)

**Interfaces:**
- Consumes: `Resolve-OptionalUtilities`, `Get-AlwaysRemovePackages`, `$buildProfile`, `$DriveLetter`, `$Index`, `$EnableNet35` (Tasks 1-3 + prior plan).

- [ ] **Step 1: Insert the dry-run block before the build try-block**

Find:
```
# Everything from here on touches a mounted image and/or loaded offline hives.
# Wrap it so that ANY terminating failure still tears those down (see finally),
# instead of leaving the host with a stuck mount or loaded hives.
$script:buildFailed = $false
try {
```
Replace with:
```
if ($DryRun) {
    $drOpt = Resolve-OptionalUtilities -Keep $Keep -Remove $Remove
    $drBase = Get-AlwaysRemovePackages
    Write-Host ""
    Write-Host "===== DRY RUN (no copy / no mount performed) ====="
    Write-Host "  Image drive (-ISO)   : $DriveLetter"
    Write-Host "  Scratch (-SCRATCH)   : $mainOSDrive"
    Write-Host ("  Image index (-Index) : {0}" -f $(if ($Index) { $Index } else { '(prompt at build time)' }))
    Write-Host "  Compression          : $($buildProfile.Compress)  (ESD: $($buildProfile.UseEsd))"
    Write-Host "  Skip component cleanup: $($buildProfile.SkipCleanup)"
    Write-Host "  Enable .NET 3.5      : $([bool]$EnableNet35)"
    Write-Host "  Optional utilities KEPT   : $($drOpt.KeptNames -join ', ')"
    Write-Host "  Optional utilities REMOVED: $($drOpt.RemovePrefixes -join ', ')"
    Write-Host "  Always-remove Appx packages ($($drBase.Count)):"
    $drBase | ForEach-Object { Write-Host "    - $_" }
    Write-Host "  Planned steps: copy image -> mount install.wim -> remove Appx -> remove system packages -> (optional .NET) -> remove Edge/OneDrive/WinRE -> rebuild WinSxS -> registry tweaks -> $(if ($buildProfile.SkipCleanup) { 'skip cleanup' } else { 'component cleanup' }) -> unmount/commit -> export ($($buildProfile.Compress)) -> bypass boot.wim -> create ISO"
    Write-Host "===== END DRY RUN ====="
    Stop-Transcript
    exit 0
}

# Everything from here on touches a mounted image and/or loaded offline hives.
# Wrap it so that ANY terminating failure still tears those down (see finally),
# instead of leaving the host with a stuck mount or loaded hives.
$script:buildFailed = $false
try {
```

- [ ] **Step 2: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11Coremaker.ps1.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed`.

- [ ] **Step 3: Grep assertion (dry-run exits before the try)**

Run: `grep -n 'DRY RUN (no copy' tiny11Coremaker.ps1` and `grep -n '^try {' tiny11Coremaker.ps1`
Expected: the DRY RUN line number is SMALLER than the lifecycle `try {` line.

- [ ] **Step 4: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): -DryRun plan + early exit before copy/mount"
```

---

## Task 5: maker — helpers + params + build profile

**Files:**
- Modify: `tiny11maker.ps1` (Functions block; param block; UAC forwarding; after `$ScratchDisk`)
- Modify: `scripts/test-core-helpers.ps1` (parity test loading from maker)

**Interfaces:**
- Produces (in maker): `Resolve-BuildProfile`, `Test-RobocopySucceeded`, `Invoke-Robocopy` (identical to Core); script-scope `$DryRun`, `$Compress`, `$Fast`, `$Index`, `$Yes`, `$buildProfile`.

- [ ] **Step 1: Write the failing parity test**

Append to `scripts/test-core-helpers.ps1` before the RESULT block:
```powershell
Write-Host '== maker parity: Resolve-BuildProfile =='
$makerPath = Join-Path $repo 'tiny11maker.ps1'
$mtk = $null; $mer = $null
$mast = [System.Management.Automation.Language.Parser]::ParseFile($makerPath, [ref]$mtk, [ref]$mer)
$mast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded' } |
    ForEach-Object { Invoke-Expression ($_.Extent.Text -replace 'function\s+(\S+)', 'function maker_$1') }
$mp = maker_Resolve-BuildProfile -Fast
Check 'maker -Fast compress fast' ($mp.Compress -eq 'fast')
Check 'maker -Fast skips cleanup' ($mp.SkipCleanup -eq $true)
Check 'maker rc 8 failure' (-not (maker_Test-RobocopySucceeded 8))
```
(The rename to `maker_*` avoids clobbering Core's already-loaded functions.)

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — maker has no `Resolve-BuildProfile` yet.

- [ ] **Step 3: Add the three helpers to maker**

In `tiny11maker.ps1`, find the end of `Remove-RegistryValue` (its closing `}` that ends the `#---------[ Functions ]---------#` block) and insert AFTER it (before `#---------[ Execution ]---------#`):
```powershell
function Resolve-BuildProfile {
    # Resolve effective image-compression settings from -Compress and -Fast.
    # Default 'recovery' (current behavior). -Fast implies 'fast' unless -Compress is
    # explicit. SkipCleanup is set by -Fast. (maker exports a single WIM, so the
    # export uses Compress directly; UseEsd/WimExportCompress are provided for parity.)
    param([string]$Compress, [switch]$Fast)
    $valid = 'recovery', 'fast', 'none'
    if ($Compress -and ($valid -notcontains $Compress)) {
        throw "Invalid -Compress '$Compress'. Valid values: $($valid -join ', ')"
    }
    $effective = if ($Compress) { $Compress } elseif ($Fast) { 'fast' } else { 'recovery' }
    [pscustomobject]@{
        Compress          = $effective
        SkipCleanup       = [bool]$Fast
        UseEsd            = ($effective -eq 'recovery')
        WimExportCompress = if ($effective -eq 'recovery') { 'max' } else { $effective }
    }
}

function Test-RobocopySucceeded {
    param([int]$ExitCode)
    return ($ExitCode -lt 8)
}

function Invoke-Robocopy {
    param([Parameter(Mandatory = $true)][string]$Source,
          [Parameter(Mandatory = $true)][string]$Destination)
    & robocopy.exe $Source $Destination '/E' '/MT' '/R:3' '/W:3' '/NFL' '/NDL' '/NJH' '/NJS' '/NP' | Out-Null
    if (-not (Test-RobocopySucceeded $LASTEXITCODE)) {
        throw "robocopy failed (exit code $LASTEXITCODE) copying '$Source' -> '$Destination'."
    }
    $global:LASTEXITCODE = 0
}
```

- [ ] **Step 4: Add the new params to maker's `param()` block**

Find:
```
param (
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH
)
```
Replace with:
```
param (
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [int]$Index,
    [switch]$Yes,
    [switch]$DryRun,
    [ValidateSet('recovery', 'fast', 'none')][string]$Compress,
    [switch]$Fast
)
```

- [ ] **Step 5: Forward the new params across maker's UAC relaunch**

Find:
```
    if ($ISO)     { $argList += " -ISO $ISO" }
    if ($SCRATCH) { $argList += " -SCRATCH $SCRATCH" }
    $newProcess.Arguments = $argList;
```
Replace with:
```
    if ($ISO)      { $argList += " -ISO $ISO" }
    if ($SCRATCH)  { $argList += " -SCRATCH $SCRATCH" }
    if ($Index)    { $argList += " -Index $Index" }
    if ($Yes)      { $argList += " -Yes" }
    if ($DryRun)   { $argList += " -DryRun" }
    if ($Compress) { $argList += " -Compress $Compress" }
    if ($Fast)     { $argList += " -Fast" }
    $newProcess.Arguments = $argList;
```

- [ ] **Step 6: Compute the build profile after `$ScratchDisk` is set**

Find (the existing `$ScratchDisk` derivation block, then the validation added earlier):
```
if (-not (Test-Path "$ScratchDisk\")) {
    throw "Scratch location '$ScratchDisk' was not found. Pass -SCRATCH with an existing drive letter, or omit it to use the script folder."
}
```
Replace with:
```
if (-not (Test-Path "$ScratchDisk\")) {
    throw "Scratch location '$ScratchDisk' was not found. Pass -SCRATCH with an existing drive letter, or omit it to use the script folder."
}
$buildProfile = Resolve-BuildProfile -Compress $Compress -Fast:$Fast
```

- [ ] **Step 7: Run tests + static checks**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed` (incl. maker parity checks).
Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11maker.ps1.

- [ ] **Step 8: Commit**

```bash
git add tiny11maker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(maker): build-profile/robocopy helpers + -DryRun/-Compress/-Fast/-Index/-Yes params"
```

---

## Task 6: maker — robocopy + `-Index`/`-Yes` wiring + profile-gated export/cleanup

**Files:**
- Modify: `tiny11maker.ps1` (index while-loop; ISO copy; Cleanup-Image; export; final Read-Host)

**Interfaces:**
- Consumes: `Invoke-Robocopy`, `$buildProfile`, `$Index`, `$Yes` (Task 5).

- [ ] **Step 1: Honor `-Index` in the image-index resolution**

Find:
```
$ImagesIndex = (Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim).ImageIndex
while ($ImagesIndex -notcontains $index) {
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim
    $index = Read-Host "Please enter the image index"
}
```
Replace with:
```
$ImagesIndex = (Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim).ImageIndex
if ($Index) { $index = $Index }
while ($ImagesIndex -notcontains $index) {
    if ($Yes) { throw "Image index '$index' not found in install.wim; pass a valid -Index for unattended runs." }
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim
    $index = Read-Host "Please enter the image index"
}
```

Also handle the first (esd) index prompt. Find:
```
        Get-WindowsImage -ImagePath $DriveLetter\sources\install.esd
        $index = Read-Host "Please enter the image index"
```
Replace with:
```
        Get-WindowsImage -ImagePath $DriveLetter\sources\install.esd
        if ($Index) { $index = $Index } else { $index = Read-Host "Please enter the image index" }
```

- [ ] **Step 2: Replace the ISO copy with robocopy**

Find:
```
Write-Output "Copying Windows image..."
Copy-Item -Path "$DriveLetter\*" -Destination "$ScratchDisk\tiny11" -Recurse -Force | Out-Null
```
Replace with:
```
Write-Output "Copying Windows image..."
Invoke-Robocopy -Source "$DriveLetter\" -Destination "$ScratchDisk\tiny11"
```

- [ ] **Step 3: Gate Cleanup-Image on the profile**

Find:
```
Write-Output "Cleaning up image..."
dism.exe /Image:$ScratchDisk\scratchdir /Cleanup-Image /StartComponentCleanup /ResetBase
Write-Output "Cleanup complete."
```
Replace with:
```
if ($buildProfile.SkipCleanup) {
    Write-Output "Skipping component cleanup (-Fast)."
} else {
    Write-Output "Cleaning up image..."
    dism.exe /Image:$ScratchDisk\scratchdir /Cleanup-Image /StartComponentCleanup /ResetBase
    Write-Output "Cleanup complete."
}
```

- [ ] **Step 4: Apply the chosen compression to the export**

Find:
```
Write-Host "Exporting image..."
Dism.exe /Export-Image /SourceImageFile:"$ScratchDisk\tiny11\sources\install.wim" /SourceIndex:$index /DestinationImageFile:"$ScratchDisk\tiny11\sources\install2.wim" /Compress:recovery
```
Replace with:
```
Write-Host "Exporting image (compress: $($buildProfile.Compress))..."
Dism.exe /Export-Image /SourceImageFile:"$ScratchDisk\tiny11\sources\install.wim" /SourceIndex:$index /DestinationImageFile:"$ScratchDisk\tiny11\sources\install2.wim" /Compress:$($buildProfile.Compress)
```

- [ ] **Step 5: Honor `-Yes` at the final pause**

Find:
```
Write-Output "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"
```
Replace with:
```
Write-Output "Creation completed!"
if (-not $Yes) { Read-Host "Press Enter to continue" }
```

- [ ] **Step 6: Static checks + grep**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11maker.ps1.
Run: `grep -c 'Invoke-Robocopy -Source' tiny11maker.ps1` → `1`.
Run: `grep -c 'buildProfile.SkipCleanup\|buildProfile.Compress' tiny11maker.ps1` → at least `2`.

- [ ] **Step 7: Commit**

```bash
git add tiny11maker.ps1
git commit -m "feat(maker): robocopy + -Index/-Yes wiring + profile-gated compression/cleanup"
```

---

## Task 7: maker — `-DryRun` plan and early exit

**Files:**
- Modify: `tiny11maker.ps1` (insert dry-run block after the drive validation, before the boot.wim/esd check)

**Interfaces:**
- Consumes: `$buildProfile`, `$DriveLetter`, `$Index`, `$packagePrefixes` is defined later — so dry-run prints the static `$packagePrefixes` only if available; instead print the plan and options.

- [ ] **Step 1: Insert the dry-run block**

Find (the image-drive validation added earlier, then the boot.wim check):
```
if (-not (Test-Path "$DriveLetter\")) {
    throw "Image drive '$DriveLetter' was not found. Mount the Windows 11 ISO and pass its drive letter via -ISO (or at the prompt)."
}

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
```
Replace with:
```
if (-not (Test-Path "$DriveLetter\")) {
    throw "Image drive '$DriveLetter' was not found. Mount the Windows 11 ISO and pass its drive letter via -ISO (or at the prompt)."
}

if ($DryRun) {
    Write-Output ""
    Write-Output "===== DRY RUN (no copy / no mount performed) ====="
    Write-Output "  Image drive (-ISO)    : $DriveLetter"
    Write-Output "  Scratch (-SCRATCH)    : $ScratchDisk"
    Write-Output ("  Image index (-Index)  : {0}" -f $(if ($Index) { $Index } else { '(prompt at build time)' }))
    Write-Output "  Compression           : $($buildProfile.Compress)"
    Write-Output "  Skip component cleanup: $($buildProfile.SkipCleanup)"
    Write-Output "  Planned steps: copy image -> mount install.wim -> remove provisioned Appx -> remove Edge/OneDrive -> registry tweaks -> $(if ($buildProfile.SkipCleanup) { 'skip cleanup' } else { 'component cleanup' }) -> unmount/commit -> export ($($buildProfile.Compress)) -> bypass boot.wim -> create ISO"
    Write-Output "===== END DRY RUN ====="
    Stop-Transcript
    exit 0
}

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
```

Note: maker's `Start-Transcript` runs before this point, so `Stop-Transcript` here is valid.

- [ ] **Step 2: Static checks + grep**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for tiny11maker.ps1.
Run: `grep -n 'DRY RUN (no copy' tiny11maker.ps1` → exactly 1 match.

- [ ] **Step 3: Commit**

```bash
git add tiny11maker.ps1
git commit -m "feat(maker): -DryRun plan + early exit before copy/mount"
```

---

## Task 8: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Append a "Speed & testing" section to README**

Append to `README.md` (after the existing limitations section). The block below is wrapped in
FOUR backticks so the inner ```powershell``` fence is preserved — write the INNER content (from
`---` through the powershell example), NOT the outer four-backtick wrapper:

````markdown
---

## Speed & testing flags

Both `tiny11maker.ps1` and `tiny11Coremaker.ps1` accept:

- **`-DryRun`** — validate inputs and print the build plan (what will be removed/kept, the
  ordered steps) in seconds, without copying or mounting anything. Use it to check
  `-ISO`/`-SCRATCH`/`-Index` and (Core) `-Keep`/`-Remove` before a real build.
- **`-Compress recovery|fast|none`** — image compression. `recovery` (default) is smallest and
  slowest (current behavior); `fast` and `none` trade size for a much faster build.
- **`-Fast`** — preset: `fast` compression + skip component cleanup (`/ResetBase`). Keeps the full
  image edits (Core still rebuilds WinSxS and runs the integrity gate), so a `-Fast` build is a
  genuine, bootable image produced in a fraction of the time. An explicit `-Compress` overrides it.

Tip: builds are I/O-bound. Point **`-SCRATCH`** at an SSD or a manually-created RAMDisk to speed
the copy/delete/mount steps. (No RAMDisk is created for you — Windows has no built-in one.)

Example fast unattended Core build, keeping Paint:

```powershell
.\tiny11Coremaker.ps1 -ISO E -SCRATCH D -Index 1 -Fast -Keep Paint -Yes
```
````

- [ ] **Step 2: Verify fences balanced**

Run: `grep -c '^```' README.md` → an EVEN number.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: -DryRun/-Compress/-Fast flags and fast-scratch guidance"
```

---

## Final verification (after all tasks)

- [ ] `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` both scripts.
- [ ] `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` both.
- [ ] `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed`.
- [ ] **Windows (user):** `-DryRun` on both scripts returns a plan in seconds and exits without mounting. A `-Fast` build on each produces a bootable ISO faster than the `recovery` default; a default build still matches today's behavior. robocopy copy succeeds (exit 0–7 not treated as failure).
