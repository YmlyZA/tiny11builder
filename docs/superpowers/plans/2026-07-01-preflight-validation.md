# Pre-flight Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Catch a wrong `-Index`, an undersized scratch drive, and a missing `oscdimg` *before* the multi-minute image copy (and surface all three in `-DryRun`), in both builder scripts, at parity.

**Architecture:** Add five small pure helper functions (index-list parser, index membership, required-space math, space sufficiency, oscdimg-source precedence) to each script; unit-test them on macOS via the existing AST harness. Add a pre-flight block that runs after drive validation and before the copy: it reads the SOURCE image off the ISO with `dism /Get-WimInfo`, computes index/space/oscdimg results into scalars, `-DryRun` prints those scalars and exits non-zero on any abort-level failure, and the real run throws on index/space failures and warns on oscdimg.

**Tech Stack:** Windows PowerShell 5.1 (runtime), PowerShell 7 (macOS test/lint), DISM, `dism /Get-WimInfo`, `Get-PSDrive`.

## Global Constraints

- **Target runtime:** Windows PowerShell 5.1. Do not use PS7-only syntax (no ternary `? :`, no `??`, no `-split` operator misuse). `1GB`/`20GB` numeric multipliers and `[math]::Max` are fine.
- **ASCII only.** No emoji or non-ASCII punctuation in either script (mojibake on the 5.1 console). Plain `->`, `[OK]`, `ERROR:`.
- **Microsoft tools only.** No third-party binaries. `dism`, `Get-PSDrive`, `robocopy` are built-in and allowed.
- **Parity.** The five helpers must be byte-identical logic in both `tiny11Coremaker.ps1` and `tiny11maker.ps1`; the pre-flight block must behave identically (allowing for each script's existing variable names and `Write-Host`/`Write-Output` idiom).
- **PowerShell variable names are case-insensitive.** `$Index` (the `[int]` param) and `$index` are the SAME variable — never introduce a lowercase `$index`. Use `$imageIndex` / `$ImagesIndex` / `$availableIndexes`.
- **Abort vs warn:** index invalid -> abort; insufficient scratch space -> abort; oscdimg unresolved -> warn only (never blocks).
- **`-DryRun` exit code:** 0 when clean, 1 when any abort-level check fails. (This intentionally changes the prior always-`exit 0`.)

---

### Task 1: Core pure helpers + unit tests

Add the five pure helpers to `tiny11Coremaker.ps1` and their unit tests. No script-body wiring yet.

**Files:**
- Modify: `tiny11Coremaker.ps1` — insert five functions into the helper block, immediately after the `Get-AlwaysRemovePackages` function's closing `}` (the block ends at the line before `Start-Transcript` near line 284).
- Modify: `scripts/test-core-helpers.ps1` — add tests after the `== Get-AlwaysRemovePackages ==` section (before the `== maker parity ==` section near line 131).

**Interfaces:**
- Produces (consumed by Tasks 2-4):
  - `Get-AvailableImageIndex([string[]]$WimInfoText)` -> array of `[pscustomobject]@{ Index=[int]; Name=[string]; SizeBytes=[long] }`
  - `Test-ImageIndexAvailable([int]$Index, $Available)` -> `[bool]`
  - `Get-RequiredScratchBytes([long]$ImageApparentBytes)` -> `[long]`
  - `Test-SufficientScratch([long]$RequiredBytes, [long]$FreeBytes)` -> `[pscustomobject]@{ Ok=[bool]; RequiredBytes; FreeBytes; RequiredGB; FreeGB }`
  - `Resolve-OscdimgSource([bool]$AdkExists, [bool]$BundledExists)` -> `'adk' | 'bundled' | 'download'`

- [ ] **Step 1: Write the failing tests**

Insert into `scripts/test-core-helpers.ps1` after line 129 (`Check 'base excludes Photos' ...`) and before line 131 (`Write-Host '== maker parity ...`):

```powershell
Write-Host '== Get-AvailableImageIndex =='
$single = @(
    'Details for image : X', '',
    'Index : 1',
    'Name : Windows 11 IoT Enterprise LTSC Evaluation',
    'Description : Windows 11 IoT Enterprise LTSC Evaluation',
    'Size : 19,529,686,632 bytes'
)
$a = Get-AvailableImageIndex $single
Check 'single: one image'   ($a.Count -eq 1)
Check 'single: index 1'     ($a[0].Index -eq 1)
Check 'single: name parsed' ($a[0].Name -eq 'Windows 11 IoT Enterprise LTSC Evaluation')
Check 'single: size parsed' ($a[0].SizeBytes -eq 19529686632)
$multi = @(
    'Index : 1', 'Name : Windows 11 Home', 'Size : 15,000,000,000 bytes',
    'Index : 3', 'Name : Windows 11 Pro',  'Size : 16,500,000,000 bytes'
)
$m = Get-AvailableImageIndex $multi
Check 'multi: two images'  ($m.Count -eq 2)
Check 'multi: indices 1,3' (($m.Index -join ',') -eq '1,3')
Check 'multi: pro size'    ((($m | Where-Object Index -eq 3).SizeBytes) -eq 16500000000)
Check 'empty input empty'  (@(Get-AvailableImageIndex @()).Count -eq 0)

Write-Host '== Test-ImageIndexAvailable =='
Check 'index present' (Test-ImageIndexAvailable 3 $m)
Check 'index absent'  (-not (Test-ImageIndexAvailable 2 $m))

Write-Host '== Get-RequiredScratchBytes =='
Check 'floor applies (small image)'  ((Get-RequiredScratchBytes 1GB) -eq 20GB)
Check 'factor applies (large image)' ((Get-RequiredScratchBytes 19529686632) -eq [long](19529686632 * 1.5))

Write-Host '== Test-SufficientScratch =='
Check 'enough space ok'   ((Test-SufficientScratch 20GB 30GB).Ok)
Check 'short space not ok' (-not (Test-SufficientScratch 30GB 20GB).Ok)

Write-Host '== Resolve-OscdimgSource =='
Check 'adk preferred'  ((Resolve-OscdimgSource $true  $true)  -eq 'adk')
Check 'bundled second' ((Resolve-OscdimgSource $false $true)  -eq 'bundled')
Check 'download last'  ((Resolve-OscdimgSource $false $false) -eq 'download')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — errors like "The term 'Get-AvailableImageIndex' is not recognized" (functions not defined yet).

- [ ] **Step 3: Implement the five helpers**

Insert into `tiny11Coremaker.ps1` immediately after the closing `}` of `Get-AlwaysRemovePackages` (just before `Start-Transcript`):

```powershell
function Get-AvailableImageIndex {
    # Parse `dism /Get-WimInfo /wimfile:<x>` text (the no-index enumeration) into
    # one object per image. Pure: takes text, returns objects. Missing Size lines
    # yield SizeBytes 0 so the free-space check falls back to its floor.
    param([string[]]$WimInfoText)
    if ($WimInfoText -is [string]) { $WimInfoText = $WimInfoText -split '\r?\n' }
    $images = @()
    $cur = $null
    foreach ($line in $WimInfoText) {
        $text = [string]$line
        if ($text -match '^\s*Index\s*:\s*(\d+)') {
            if ($cur) { $images += [pscustomobject]$cur }
            $cur = [ordered]@{ Index = [int]$Matches[1]; Name = ''; SizeBytes = [long]0 }
        } elseif ($cur -and $text -match '^\s*Name\s*:\s*(.+?)\s*$') {
            $cur.Name = $Matches[1]
        } elseif ($cur -and $text -match '^\s*Size\s*:\s*([\d,]+)') {
            $cur.SizeBytes = [long]($Matches[1] -replace ',', '')
        }
    }
    if ($cur) { $images += [pscustomobject]$cur }
    return ,$images
}

function Test-ImageIndexAvailable {
    param([int]$Index, $Available)
    return ([int[]]@($Available.Index)) -contains $Index
}

function Get-RequiredScratchBytes {
    # Peak scratch usage is the mounted image view plus the coexisting
    # install.wim / install2.wim / install.esd exports: ~1.5x the image's
    # apparent size, with a 20 GB floor for small/unknown images.
    param([long]$ImageApparentBytes)
    $factor = 1.5
    $floor  = 20GB
    return [long]([math]::Max([double]$floor, [double]$ImageApparentBytes * $factor))
}

function Test-SufficientScratch {
    param([long]$RequiredBytes, [long]$FreeBytes)
    return [pscustomobject]@{
        Ok            = ($FreeBytes -ge $RequiredBytes)
        RequiredBytes = $RequiredBytes
        FreeBytes     = $FreeBytes
        RequiredGB    = [math]::Round($RequiredBytes / 1GB, 1)
        FreeGB        = [math]::Round($FreeBytes / 1GB, 1)
    }
}

function Resolve-OscdimgSource {
    param([bool]$AdkExists, [bool]$BundledExists)
    if ($AdkExists)     { return 'adk' }
    if ($BundledExists) { return 'bundled' }
    return 'download'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (n is the prior 55 plus the ~20 new checks).

- [ ] **Step 5: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` (expect `[OK]   tiny11Coremaker.ps1`) and `pwsh -NoProfile -File scripts/linter.ps1` (expect `0 high-signal finding(s)` for Core).

- [ ] **Step 6: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): add pre-flight validation helpers + unit tests"
```

---

### Task 2: Core pre-flight phase + `-DryRun` integration + index-loop parity

Wire the helpers into `tiny11Coremaker.ps1`: compute pre-flight scalars before the dry-run block, extend the dry-run block, add real-run aborts/warn, and unify index resolution into a validation loop used by both the ESD-export and mount paths.

**Files:**
- Modify: `tiny11Coremaker.ps1` — insert pre-flight after the image-drive `Test-Path` throw (ends ~line 335) and before `if ($DryRun) {` (~line 337); replace the dry-run block (~337-356); add abort/warn + index loop before the install.wim/esd detection (~364); remove the two old index resolutions (the `if ($Index) { $imageIndex = $Index } else { ... Read-Host }` at ~368 inside the ESD branch and at ~386 before mount).

**Interfaces:**
- Consumes (from Task 1): `Get-AvailableImageIndex`, `Test-ImageIndexAvailable`, `Get-RequiredScratchBytes`, `Test-SufficientScratch`, `Resolve-OscdimgSource`.
- Uses existing vars: `$DriveLetter` (e.g. `E:`), `$mainOSDrive` (e.g. `C:`), `$Index`, `$Yes`, `$hostArchitecture`, `$buildProfile`, `$adminGroup`.

- [ ] **Step 1: Insert the pre-flight computation**

Add immediately BEFORE the `if ($DryRun) {` line (~337):

```powershell
# ---- Pre-flight validation (runs before the copy; also what -DryRun reports) ----
# Read the SOURCE image straight off the ISO so a bad index / too-small scratch /
# missing oscdimg is caught in seconds instead of after the multi-minute copy.
$srcInstallWim  = "$DriveLetter\sources\install.wim"
$srcInstallEsd  = "$DriveLetter\sources\install.esd"
$preflightImage = if (Test-Path $srcInstallWim) { $srcInstallWim } elseif (Test-Path $srcInstallEsd) { $srcInstallEsd } else { $null }

$availableIndexes = @()
if ($preflightImage) {
    $wimInfoText = & 'dism' '/English' '/Get-WimInfo' "/wimfile:$preflightImage" 2>&1
    $availableIndexes = Get-AvailableImageIndex $wimInfoText
}
$ImagesIndex = @($availableIndexes.Index)

$indexOk  = (-not $Index) -or (Test-ImageIndexAvailable $Index $availableIndexes)
$indexMsg = if ($availableIndexes.Count) {
    "Available indexes: " + (($availableIndexes | ForEach-Object { "$($_.Index) = $($_.Name)" }) -join '; ')
} else { "Could not read any image indexes from '$preflightImage'." }

$chosenSizeBytes = if ($Index) {
    [long](($availableIndexes | Where-Object Index -eq $Index | Select-Object -First 1).SizeBytes)
} elseif ($availableIndexes.Count) {
    [long](($availableIndexes.SizeBytes | Measure-Object -Maximum).Maximum)
} else { [long]0 }
$requiredBytes = Get-RequiredScratchBytes $chosenSizeBytes
$scratchQualifier = Split-Path -Qualifier $mainOSDrive
$freeBytes = [long]((Get-PSDrive -Name ($scratchQualifier.TrimEnd(':')) -ErrorAction SilentlyContinue).Free)
$space   = Test-SufficientScratch $requiredBytes $freeBytes
$spaceOk = $space.Ok

$adkOscdimg     = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArchitecture\Oscdimg\oscdimg.exe"
$bundledOscdimg = "$PSScriptRoot\oscdimg.exe"
$oscdimgSource  = Resolve-OscdimgSource (Test-Path $adkOscdimg) (Test-Path $bundledOscdimg)
$oscdimgOk      = ($oscdimgSource -ne 'download')
```

- [ ] **Step 2: Replace the dry-run block**

Replace the entire existing `if ($DryRun) { ... exit 0 }` block with:

```powershell
if ($DryRun) {
    $drOpt  = Resolve-OptionalUtilities -Keep $Keep -Remove $Remove
    $drBase = Get-AlwaysRemovePackages
    Write-Host ""
    Write-Host "===== DRY RUN (no copy / no mount performed) ====="
    Write-Host "  Image drive (-ISO)   : $DriveLetter"
    Write-Host "  Scratch (-SCRATCH)   : $mainOSDrive"
    Write-Host ("  Image index (-Index) : {0}" -f $(if ($Index) { $Index } else { '(prompt at build time)' }))
    if ($Index -and -not $indexOk) {
        Write-Host "     ERROR: index $Index not found. $indexMsg"
    } elseif ($availableIndexes.Count) {
        Write-Host "     [OK] image has indexes: $($ImagesIndex -join ', ')"
    }
    Write-Host ("  Scratch free space   : {0} GB free, ~{1} GB required  [{2}]" -f $space.FreeGB, $space.RequiredGB, $(if ($spaceOk) { 'OK' } else { 'INSUFFICIENT' }))
    Write-Host ("  ISO builder (oscdimg): {0}  [{1}]" -f $oscdimgSource, $(if ($oscdimgOk) { 'OK' } else { 'will download at build time' }))
    Write-Host "  Compression          : $($buildProfile.Compress)  (ESD: $($buildProfile.UseEsd))"
    Write-Host "  Skip component cleanup: $($buildProfile.SkipCleanup)"
    Write-Host "  Enable .NET 3.5      : $([bool]$EnableNet35)"
    Write-Host "  Optional utilities KEPT   : $($drOpt.KeptNames -join ', ')"
    Write-Host "  Optional utilities REMOVED: $($drOpt.RemovePrefixes -join ', ')"
    Write-Host "  Always-remove Appx packages ($($drBase.Count)):"
    $drBase | ForEach-Object { Write-Host "    - $_" }
    if (-not $preflightImage) { Write-Host "     ERROR: no install.wim or install.esd under $DriveLetter\sources." }
    Write-Host "  Planned steps: copy image -> mount install.wim -> remove Appx -> remove system packages -> (optional .NET) -> remove Edge/OneDrive/WinRE -> rebuild WinSxS -> registry tweaks -> $(if ($buildProfile.SkipCleanup) { 'skip cleanup' } else { 'component cleanup' }) -> unmount/commit -> export ($($buildProfile.Compress)) -> bypass boot.wim -> create ISO"
    Write-Host "===== END DRY RUN ====="
    $dryRunFailed = (-not $preflightImage) -or ($Index -and -not $indexOk) -or (-not $spaceOk)
    Stop-Transcript
    if ($dryRunFailed) { exit 1 } else { exit 0 }
}

# Enforce the pre-flight results for a real build (dry run already returned above).
if (-not $preflightImage) {
    throw "No install.wim or install.esd found under $DriveLetter\sources. Check the -ISO drive letter."
}
if ($Index -and -not $indexOk) {
    throw "Image index $Index not found in the Windows image. $indexMsg"
}
if (-not $spaceOk) {
    throw ("Not enough free space on scratch drive $mainOSDrive : ~{0} GB required, {1} GB available. Use -SCRATCH to point at a larger drive." -f $space.RequiredGB, $space.FreeGB)
}
if (-not $oscdimgOk) {
    Write-Warning "Neither the Windows ADK nor a bundled oscdimg.exe was found; the ISO step will attempt to download oscdimg.exe at the end of the build."
}

# Resolve the image index once (validated against the source image), used by both
# the ESD->WIM conversion and the mount. Interactive entry re-prompts until valid.
if ($Index) { $imageIndex = $Index }
while ($ImagesIndex -notcontains $imageIndex) {
    if ($Yes) { throw "Image index '$imageIndex' not found in install.wim; pass a valid -Index for unattended runs." }
    & 'dism' '/English' '/Get-WimInfo' "/wimfile:$preflightImage"
    $imageIndex = Read-Host "Please enter the image index"
}
```

- [ ] **Step 3: Remove the now-duplicate index prompts**

In the ESD branch, delete the line (inside `if ((Test-Path ...install.esd...))`):
```powershell
        if ($Index) { $imageIndex = $Index } else { $imageIndex = Read-Host "Please enter the image index" }
```
And before the mount, delete the line:
```powershell
if ($Index) { $imageIndex = $Index } else { $imageIndex = Read-Host "Please enter the image index" }
```
`$imageIndex` is now already resolved by Step 2's loop; both the export and mount use it.

- [ ] **Step 4: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` — expect `[OK]   tiny11Coremaker.ps1`.
Run: `pwsh -NoProfile -File scripts/linter.ps1` — expect `0 high-signal finding(s)` for Core.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` — expect `RESULT: <n> passed, 0 failed` (unchanged from Task 1; body wiring does not affect helper tests).

Note: the pre-flight body calls `dism`/`Get-PSDrive`, which do not exist on macOS, so the script body itself is not runnable here — its decision logic lives entirely in the Task 1 helpers (already unit-tested). Runtime dry-run/build verification happens on Windows (see Task 5 handoff).

- [ ] **Step 5: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): pre-flight index/space/oscdimg checks + dry-run integration"
```

---

### Task 3: maker pure helpers + parity unit tests

Add the identical five helpers to `tiny11maker.ps1` and extend the parity section of the test harness to load and check them from maker.

**Files:**
- Modify: `tiny11maker.ps1` — insert the five functions into the Functions block, immediately after the `Invoke-Robocopy` function's closing `}` (the block near lines 102-108).
- Modify: `scripts/test-core-helpers.ps1` — extend the maker parity extraction list and add maker parity checks.

**Interfaces:**
- Produces: the same five function signatures as Task 1, now also defined in `tiny11maker.ps1`.

- [ ] **Step 1: Write the failing parity tests**

In `scripts/test-core-helpers.ps1`, change the parity extraction filter (currently `Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded' }`) to:

```powershell
    Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded', 'Get-AvailableImageIndex', 'Test-ImageIndexAvailable', 'Get-RequiredScratchBytes', 'Test-SufficientScratch', 'Resolve-OscdimgSource' } |
```

Then add, after the existing `Check 'maker rc 8 failure' ...` line:

```powershell
$mAvail = maker_Get-AvailableImageIndex @('Index : 1', 'Name : Windows 11 Pro', 'Size : 16,500,000,000 bytes')
Check 'maker parses one image'   ($mAvail.Count -eq 1)
Check 'maker index present'      (maker_Test-ImageIndexAvailable 1 $mAvail)
Check 'maker index absent'       (-not (maker_Test-ImageIndexAvailable 9 $mAvail))
Check 'maker required floor'     ((maker_Get-RequiredScratchBytes 1GB) -eq 20GB)
Check 'maker scratch short'      (-not (maker_Test-SufficientScratch 30GB 20GB).Ok)
Check 'maker oscdimg download'   ((maker_Resolve-OscdimgSource $false $false) -eq 'download')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'maker_Get-AvailableImageIndex' is not recognized" (maker helpers not defined yet).

- [ ] **Step 3: Add the five helpers to maker**

Insert into `tiny11maker.ps1` immediately after the closing `}` of `Invoke-Robocopy` (the exact same five function definitions as Task 1, Step 3):

```powershell
function Get-AvailableImageIndex {
    # Parse `dism /Get-WimInfo /wimfile:<x>` text (the no-index enumeration) into
    # one object per image. Pure: takes text, returns objects. Missing Size lines
    # yield SizeBytes 0 so the free-space check falls back to its floor.
    param([string[]]$WimInfoText)
    if ($WimInfoText -is [string]) { $WimInfoText = $WimInfoText -split '\r?\n' }
    $images = @()
    $cur = $null
    foreach ($line in $WimInfoText) {
        $text = [string]$line
        if ($text -match '^\s*Index\s*:\s*(\d+)') {
            if ($cur) { $images += [pscustomobject]$cur }
            $cur = [ordered]@{ Index = [int]$Matches[1]; Name = ''; SizeBytes = [long]0 }
        } elseif ($cur -and $text -match '^\s*Name\s*:\s*(.+?)\s*$') {
            $cur.Name = $Matches[1]
        } elseif ($cur -and $text -match '^\s*Size\s*:\s*([\d,]+)') {
            $cur.SizeBytes = [long]($Matches[1] -replace ',', '')
        }
    }
    if ($cur) { $images += [pscustomobject]$cur }
    return ,$images
}

function Test-ImageIndexAvailable {
    param([int]$Index, $Available)
    return ([int[]]@($Available.Index)) -contains $Index
}

function Get-RequiredScratchBytes {
    # Peak scratch usage is the mounted image view plus the coexisting
    # install.wim / install2.wim / install.esd exports: ~1.5x the image's
    # apparent size, with a 20 GB floor for small/unknown images.
    param([long]$ImageApparentBytes)
    $factor = 1.5
    $floor  = 20GB
    return [long]([math]::Max([double]$floor, [double]$ImageApparentBytes * $factor))
}

function Test-SufficientScratch {
    param([long]$RequiredBytes, [long]$FreeBytes)
    return [pscustomobject]@{
        Ok            = ($FreeBytes -ge $RequiredBytes)
        RequiredBytes = $RequiredBytes
        FreeBytes     = $FreeBytes
        RequiredGB    = [math]::Round($RequiredBytes / 1GB, 1)
        FreeGB        = [math]::Round($FreeBytes / 1GB, 1)
    }
}

function Resolve-OscdimgSource {
    param([bool]$AdkExists, [bool]$BundledExists)
    if ($AdkExists)     { return 'adk' }
    if ($BundledExists) { return 'bundled' }
    return 'download'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (n grows by the 6 maker parity checks).

- [ ] **Step 5: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` — expect `[OK]   tiny11maker.ps1`.
Run: `pwsh -NoProfile -File scripts/linter.ps1` — expect `0 high-signal finding(s)` for maker.

- [ ] **Step 6: Commit**

```bash
git add tiny11maker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(maker): add pre-flight validation helpers + parity tests"
```

---

### Task 4: maker pre-flight phase + `-DryRun` integration

Wire the helpers into `tiny11maker.ps1`, mirroring Core: compute pre-flight scalars before the dry-run block, extend the dry-run block, add real-run aborts/warn, hoist the index validation before the copy, and guard the ESD-export path.

**Files:**
- Modify: `tiny11maker.ps1` — insert pre-flight after the image-drive `Test-Path` throw (~lines 191-193) and before `if ($DryRun) {` (~195); replace the dry-run block (~195-207); add abort/warn + index loop before the install.wim/esd detection (~209); in the ESD branch remove the `if ($Index) { $imageIndex = $Index } else { Read-Host }` (~213); remove the post-copy index build + loop (`$ImagesIndex = (Get-WindowsImage ...)` and the `while` loop at ~232-238).

**Interfaces:**
- Consumes (from Task 3): the five helpers.
- Uses existing vars: `$DriveLetter` (e.g. `E:`), `$ScratchDisk` (a drive like `E:` OR a folder path when `-SCRATCH` is omitted), `$Index`, `$Yes`, `$hostArchitecture` (set at line 175), `$buildProfile`, `$adminGroup`.

- [ ] **Step 1: Insert the pre-flight computation**

Add immediately BEFORE the `if ($DryRun) {` line (~195):

```powershell
# ---- Pre-flight validation (runs before the copy; also what -DryRun reports) ----
# Read the SOURCE image straight off the ISO so a bad index / too-small scratch /
# missing oscdimg is caught in seconds instead of after the multi-minute copy.
$srcInstallWim  = "$DriveLetter\sources\install.wim"
$srcInstallEsd  = "$DriveLetter\sources\install.esd"
$preflightImage = if (Test-Path $srcInstallWim) { $srcInstallWim } elseif (Test-Path $srcInstallEsd) { $srcInstallEsd } else { $null }

$availableIndexes = @()
if ($preflightImage) {
    $wimInfoText = & 'dism' '/English' '/Get-WimInfo' "/wimfile:$preflightImage" 2>&1
    $availableIndexes = Get-AvailableImageIndex $wimInfoText
}
$ImagesIndex = @($availableIndexes.Index)

$indexOk  = (-not $Index) -or (Test-ImageIndexAvailable $Index $availableIndexes)
$indexMsg = if ($availableIndexes.Count) {
    "Available indexes: " + (($availableIndexes | ForEach-Object { "$($_.Index) = $($_.Name)" }) -join '; ')
} else { "Could not read any image indexes from '$preflightImage'." }

$chosenSizeBytes = if ($Index) {
    [long](($availableIndexes | Where-Object Index -eq $Index | Select-Object -First 1).SizeBytes)
} elseif ($availableIndexes.Count) {
    [long](($availableIndexes.SizeBytes | Measure-Object -Maximum).Maximum)
} else { [long]0 }
$requiredBytes = Get-RequiredScratchBytes $chosenSizeBytes
$scratchQualifier = Split-Path -Qualifier $ScratchDisk
$freeBytes = [long]((Get-PSDrive -Name ($scratchQualifier.TrimEnd(':')) -ErrorAction SilentlyContinue).Free)
$space   = Test-SufficientScratch $requiredBytes $freeBytes
$spaceOk = $space.Ok

$adkOscdimg     = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostArchitecture\Oscdimg\oscdimg.exe"
$bundledOscdimg = "$PSScriptRoot\oscdimg.exe"
$oscdimgSource  = Resolve-OscdimgSource (Test-Path $adkOscdimg) (Test-Path $bundledOscdimg)
$oscdimgOk      = ($oscdimgSource -ne 'download')
```

- [ ] **Step 2: Replace the dry-run block**

Replace the entire existing `if ($DryRun) { ... exit 0 }` block (~195-207) with:

```powershell
if ($DryRun) {
    Write-Output ""
    Write-Output "===== DRY RUN (no copy / no mount performed) ====="
    Write-Output "  Image drive (-ISO)    : $DriveLetter"
    Write-Output "  Scratch (-SCRATCH)    : $ScratchDisk"
    Write-Output ("  Image index (-Index)  : {0}" -f $(if ($Index) { $Index } else { '(prompt at build time)' }))
    if ($Index -and -not $indexOk) {
        Write-Output "     ERROR: index $Index not found. $indexMsg"
    } elseif ($availableIndexes.Count) {
        Write-Output "     [OK] image has indexes: $($ImagesIndex -join ', ')"
    }
    Write-Output ("  Scratch free space    : {0} GB free, ~{1} GB required  [{2}]" -f $space.FreeGB, $space.RequiredGB, $(if ($spaceOk) { 'OK' } else { 'INSUFFICIENT' }))
    Write-Output ("  ISO builder (oscdimg) : {0}  [{1}]" -f $oscdimgSource, $(if ($oscdimgOk) { 'OK' } else { 'will download at build time' }))
    Write-Output "  Compression           : $($buildProfile.Compress)"
    Write-Output "  Skip component cleanup: $($buildProfile.SkipCleanup)"
    if (-not $preflightImage) { Write-Output "     ERROR: no install.wim or install.esd under $DriveLetter\sources." }
    Write-Output "  Planned steps: copy image -> mount install.wim -> remove provisioned Appx -> remove Edge/OneDrive -> registry tweaks -> $(if ($buildProfile.SkipCleanup) { 'skip cleanup' } else { 'component cleanup' }) -> unmount/commit -> export ($($buildProfile.Compress)) -> bypass boot.wim -> create ISO"
    Write-Output "===== END DRY RUN ====="
    $dryRunFailed = (-not $preflightImage) -or ($Index -and -not $indexOk) -or (-not $spaceOk)
    Stop-Transcript
    if ($dryRunFailed) { exit 1 } else { exit 0 }
}

# Enforce the pre-flight results for a real build (dry run already returned above).
if (-not $preflightImage) {
    throw "No install.wim or install.esd found under $DriveLetter\sources. Check the -ISO drive letter."
}
if ($Index -and -not $indexOk) {
    throw "Image index $Index not found in the Windows image. $indexMsg"
}
if (-not $spaceOk) {
    throw ("Not enough free space on scratch drive $ScratchDisk : ~{0} GB required, {1} GB available. Use -SCRATCH to point at a larger drive." -f $space.RequiredGB, $space.FreeGB)
}
if (-not $oscdimgOk) {
    Write-Warning "Neither the Windows ADK nor a bundled oscdimg.exe was found; the ISO step will attempt to download oscdimg.exe at the end of the build."
}

# Resolve the image index once (validated against the source image), used by both
# the ESD->WIM conversion and the mount. Interactive entry re-prompts until valid.
if ($Index) { $imageIndex = $Index }
while ($ImagesIndex -notcontains $imageIndex) {
    if ($Yes) { throw "Image index '$imageIndex' not found in install.wim; pass a valid -Index for unattended runs." }
    & 'dism' '/English' '/Get-WimInfo' "/wimfile:$preflightImage"
    $imageIndex = Read-Host "Please enter the image index"
}
```

- [ ] **Step 3: Remove the ESD-branch prompt and the post-copy index build/loop**

In the ESD branch (`if ((Test-Path "$DriveLetter\sources\install.esd") ...)`), delete the line:
```powershell
        if ($Index) { $imageIndex = $Index } else { $imageIndex = Read-Host "Please enter the image index" }
```

After the copy (`Write-Output "Copy complete!"` region), delete the now-redundant block:
```powershell
$ImagesIndex = (Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim).ImageIndex
if ($Index) { $imageIndex = $Index }
while ($ImagesIndex -notcontains $imageIndex) {
    if ($Yes) { throw "Image index '$imageIndex' not found in install.wim; pass a valid -Index for unattended runs." }
    Get-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim
    $imageIndex = Read-Host "Please enter the image index"
}
```
Leave the surrounding `Write-Output "Getting image information:"` and `Write-Output "Mounting Windows image..."` lines; `$imageIndex` is already resolved by Step 2.

- [ ] **Step 4: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` — expect `[OK]   tiny11maker.ps1`.
Run: `pwsh -NoProfile -File scripts/linter.ps1` — expect `0 high-signal finding(s)` for maker.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` — expect `RESULT: <n> passed, 0 failed` (unchanged; body wiring does not affect helper tests).

Note: as in Task 2, the maker body calls `dism`/`Get-PSDrive`/`Get-WindowsImage`, unavailable on macOS; decision logic is covered by the Task 3 parity tests. Runtime verification is on Windows.

- [ ] **Step 5: Commit**

```bash
git add tiny11maker.ps1
git commit -m "feat(maker): pre-flight index/space/oscdimg checks + dry-run integration"
```

---

### Task 5: README documentation

Document the pre-flight checks so users know a dry run now validates index/space/oscdimg and returns a meaningful exit code.

**Files:**
- Modify: `README.md` — extend the existing "Speed & testing flags" section (added by the prior increment).

- [ ] **Step 1: Add the documentation**

In `README.md`, under the "Speed & testing flags" section, append:

```markdown
### Pre-flight validation

Before copying anything, both scripts now validate:

- **Image index** — if `-Index` names an edition the image does not contain, the
  run aborts immediately and lists the real editions (e.g. single-edition LTSC/IoT
  ISOs only have index `1`). Previously this failed cryptically at DISM mount,
  after the multi-minute copy.
- **Scratch free space** — the target drive must have roughly 1.5x the image's
  apparent size free (minimum 20 GB); otherwise the run aborts up front instead of
  failing partway through the copy or an export.
- **oscdimg availability** — if neither the Windows ADK nor a bundled `oscdimg.exe`
  is present, you get a warning up front (the build still tries to download it at
  the ISO step) rather than discovering it only at the very end.

`-DryRun` runs all three checks against the source ISO (no copy) and **exits 1** if
any hard check fails, `0` if the plan is clean — so `-DryRun -ISO E -Index 3` tells
you in seconds whether a real build would succeed:

    .\tiny11Coremaker.ps1 -ISO E -Index 3 -DryRun
```

- [ ] **Step 2: Verify**

Run: `grep -n "Pre-flight validation" README.md` — expect one match.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document pre-flight validation and dry-run exit codes"
```

---

## Notes for the executor

- Base commit for the increment: current `harden/core-error-handling` HEAD (`70e89b1` or later — the branch already carries the speed/testability work).
- After all tasks: run the final whole-branch review over the pre-flight commits only (`git merge-base` of this task series), then hand off via superpowers:finishing-a-development-branch. The fork/push/PR/merge uses the `YmlyZA` GitHub account (switch before, restore after).
- Real-machine close-out (user, Windows): `.\tiny11Coremaker.ps1 -ISO <d> -Index 3 -DryRun` should now print the friendly index error and exit 1; `-Index 1 -DryRun` should print `[OK]` lines and exit 0; then `-Index 1 -Yes -Fast` should pass pre-flight and build.
