# tiny11 Core Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modernize `tiny11Coremaker.ps1` with a WinSxS integrity gate, unattended parameters, a user-selectable optional-utilities mechanism, and refreshed removal lists — without changing Core's non-serviceable/minimal direction.

**Architecture:** Add small **pure helper functions** (data table + resolution + integrity assertion) near the top of the script so they are unit-testable under pwsh on macOS via AST extraction, exactly like the existing `Invoke-Dism`/`Dismount-OfflineImage` helpers. The interactive/Windows-only flow (param plumbing, picker, DISM calls) is wired to those tested functions and gated with parse + lint + grep checks.

**Tech Stack:** Windows PowerShell 5.1 (runtime target) / PowerShell 7.x (local static checks), DISM, reg.exe, oscdimg.exe. Tests run with `pwsh` and the repo's `scripts/parse-check.ps1` + `scripts/linter.ps1`.

## Global Constraints

- Target runtime is **Windows PowerShell 5.1**; all code must be 5.1-compatible (no PS7-only syntax).
- Scripts stay **ASCII-only** (avoid emoji mojibake on the 5.1 console).
- Use Microsoft tools only (DISM/reg/oscdimg); no third-party binaries.
- **Out of scope:** Microsoft Store fix, re-enabling Windows Update/Defender, restoring serviceability.
- Optional-utility default-keep set is exactly: `Terminal`, `Calculator`, `Notepad`, `Photos`.
- `-SCRATCH` is the scratch-drive parameter name (consistent with maker); defaults to `$env:SystemDrive`.
- WinSxS integrity failure policy is **abort** (throw), never warn-and-continue.
- All work stays on branch `harden/core-error-handling`.
- After every code change: `pwsh -NoProfile -File scripts/parse-check.ps1` must print `[OK]` for both scripts, and `pwsh -NoProfile -File scripts/linter.ps1` must show `0 high-signal finding(s)`.

---

## File Structure

- `tiny11Coremaker.ps1` — modified: add `param()` block, three pure helpers (`Get-OptionalUtilities`, `Resolve-OptionalUtilities`, `Assert-WinSxSRebuild`), rewrite the provisioned-Appx removal, wire the integrity gate, add the doc header.
- `scripts/test-core-helpers.ps1` — created: macOS-runnable unit tests that load the pure helpers from `tiny11Coremaker.ps1` via AST and assert their behavior.
- `README.md` — modified: document the by-design limitations and the optional-utilities `-Keep`/`-Remove` mechanism.

---

## Task 1: Optional-utilities table + resolution function (pure, unit-tested)

**Files:**
- Modify: `tiny11Coremaker.ps1` (helper-functions block, after the existing `Dismount-OfflineImage`, before `Start-Transcript`)
- Create: `scripts/test-core-helpers.ps1`

**Interfaces:**
- Produces: `Get-OptionalUtilities()` → array of `[pscustomobject]@{ Name:string; Prefixes:string[]; Default:'Keep'|'Remove' }`.
- Produces: `Resolve-OptionalUtilities([string[]]$Keep, [string[]]$Remove)` → `[pscustomobject]@{ RemovePrefixes:string[]; KeptNames:string[] }`; throws on unknown name or a name present in both lists.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-core-helpers.ps1`:

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    macOS/Windows-runnable unit tests for the pure helper functions in
    tiny11Coremaker.ps1. Loads the function definitions via AST (no image needed).
#>
$repo = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repo 'tiny11Coremaker.ps1'

# Load ONLY the function definitions from the real script.
$tk = $null; $er = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tk, [ref]$er)
if ($er.Count) { throw "parse errors in $script" }
$ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "  PASS: $name"; $script:pass++ }
    else       { Write-Host "  FAIL: $name"; $script:fail++ }
}
function CheckThrows([string]$name, [scriptblock]$sb) {
    $threw = $false
    try { & $sb } catch { $threw = $true }
    Check $name $threw
}

Write-Host '== Get-OptionalUtilities =='
$table = Get-OptionalUtilities
Check 'table has 12 entries' ($table.Count -eq 12)
Check 'Terminal default Keep'   (($table | Where-Object Name -eq 'Terminal').Default   -eq 'Keep')
Check 'Calculator default Keep' (($table | Where-Object Name -eq 'Calculator').Default -eq 'Keep')
Check 'Notepad default Keep'    (($table | Where-Object Name -eq 'Notepad').Default    -eq 'Keep')
Check 'Photos default Keep'     (($table | Where-Object Name -eq 'Photos').Default     -eq 'Keep')
Check 'Paint default Remove'    (($table | Where-Object Name -eq 'Paint').Default      -eq 'Remove')

Write-Host '== Resolve-OptionalUtilities defaults =='
$r = Resolve-OptionalUtilities
Check 'defaults keep Terminal'        ($r.KeptNames -contains 'Terminal')
Check 'defaults remove Paint prefix'  ($r.RemovePrefixes -contains 'Microsoft.Paint')
Check 'defaults do NOT remove Terminal' (-not ($r.RemovePrefixes -contains 'Microsoft.WindowsTerminal'))

Write-Host '== Resolve overrides =='
$r = Resolve-OptionalUtilities -Keep @('Paint')
Check '-Keep Paint retains it' (-not ($r.RemovePrefixes -contains 'Microsoft.Paint'))
$r = Resolve-OptionalUtilities -Remove @('Terminal')
Check '-Remove Terminal drops it' ($r.RemovePrefixes -contains 'Microsoft.WindowsTerminal')
$r = Resolve-OptionalUtilities -Keep @('paint')
Check '-Keep is case-insensitive' (-not ($r.RemovePrefixes -contains 'Microsoft.Paint'))

Write-Host '== Resolve errors =='
CheckThrows 'unknown name throws'        { Resolve-OptionalUtilities -Keep @('Nope') }
CheckThrows 'name in both lists throws'  { Resolve-OptionalUtilities -Keep @('Paint') -Remove @('Paint') }

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — error like `The term 'Get-OptionalUtilities' is not recognized` (functions not defined yet).

- [ ] **Step 3: Add the two functions**

In `tiny11Coremaker.ps1`, insert the following immediately AFTER the `Dismount-OfflineImage` function's closing `}` (currently around line 59) and BEFORE `Start-Transcript`:

```powershell
function Get-OptionalUtilities {
    # Single source of truth for user-selectable standalone utility apps.
    # Name = friendly token used by -Keep/-Remove and the picker.
    # Prefixes = provisioned-Appx name prefixes. Default = 'Keep' or 'Remove'.
    @(
        [pscustomobject]@{ Name = 'Terminal';      Prefixes = @('Microsoft.WindowsTerminal');             Default = 'Keep'   }
        [pscustomobject]@{ Name = 'Calculator';    Prefixes = @('Microsoft.WindowsCalculator');           Default = 'Keep'   }
        [pscustomobject]@{ Name = 'Notepad';       Prefixes = @('Microsoft.WindowsNotepad');              Default = 'Keep'   }
        [pscustomobject]@{ Name = 'Photos';        Prefixes = @('Microsoft.Windows.Photos');              Default = 'Keep'   }
        [pscustomobject]@{ Name = 'Paint';         Prefixes = @('Microsoft.Paint', 'Microsoft.MSPaint');  Default = 'Remove' }
        [pscustomobject]@{ Name = 'Camera';        Prefixes = @('Microsoft.WindowsCamera');               Default = 'Remove' }
        [pscustomobject]@{ Name = 'SoundRecorder'; Prefixes = @('Microsoft.WindowsSoundRecorder');        Default = 'Remove' }
        [pscustomobject]@{ Name = 'StickyNotes';   Prefixes = @('Microsoft.MicrosoftStickyNotes');        Default = 'Remove' }
        [pscustomobject]@{ Name = 'Clock';         Prefixes = @('Microsoft.WindowsAlarms');               Default = 'Remove' }
        [pscustomobject]@{ Name = 'MediaPlayer';   Prefixes = @('Microsoft.ZuneMusic');                   Default = 'Remove' }
        [pscustomobject]@{ Name = 'MoviesTV';      Prefixes = @('Microsoft.ZuneVideo');                   Default = 'Remove' }
        [pscustomobject]@{ Name = 'SnippingTool';  Prefixes = @('Microsoft.ScreenSketch');                Default = 'Remove' }
    )
}

function Resolve-OptionalUtilities {
    # Resolve the keep/remove state of every optional utility from its default,
    # overridden by -Keep (force keep) and -Remove (force drop). Returns the list
    # of Appx prefixes to remove and the names kept. Throws on an unknown name or
    # a name present in both lists. Name matching is case-insensitive (PowerShell
    # -contains on strings is case-insensitive by default).
    param(
        [string[]]$Keep = @(),
        [string[]]$Remove = @()
    )
    $table = Get-OptionalUtilities
    $valid = $table.Name
    foreach ($n in @($Keep + $Remove)) {
        if ($valid -notcontains $n) {
            throw "Unknown optional utility '$n'. Valid names: $($valid -join ', ')"
        }
    }
    $conflict = $Keep | Where-Object { $Remove -contains $_ }
    if ($conflict) {
        throw "Optional utility '$($conflict -join ', ')' cannot be in both -Keep and -Remove."
    }
    $removePrefixes = New-Object System.Collections.Generic.List[string]
    $keptNames      = New-Object System.Collections.Generic.List[string]
    foreach ($u in $table) {
        $state = $u.Default
        if ($Keep   -contains $u.Name) { $state = 'Keep' }
        if ($Remove -contains $u.Name) { $state = 'Remove' }
        if ($state -eq 'Remove') { $u.Prefixes | ForEach-Object { $removePrefixes.Add($_) } }
        else                     { $keptNames.Add($u.Name) }
    }
    [pscustomobject]@{
        RemovePrefixes = $removePrefixes.ToArray()
        KeptNames      = $keptNames.ToArray()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — final line `RESULT: <n> passed, 0 failed`.

- [ ] **Step 5: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1`
Expected: `[OK]` for `tiny11Coremaker.ps1`.
Run: `pwsh -NoProfile -File scripts/linter.ps1`
Expected: `tiny11Coremaker.ps1 : 0 high-signal finding(s)`.

- [ ] **Step 6: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): optional-utilities table + resolution (pure, tested)"
```

---

## Task 2: WinSxS integrity-gate function (pure, unit-tested)

**Files:**
- Modify: `tiny11Coremaker.ps1` (after `Resolve-OptionalUtilities`)
- Modify: `scripts/test-core-helpers.ps1` (append a test block)

**Interfaces:**
- Produces: `Assert-WinSxSRebuild([string]$Path)` → returns nothing on success; throws if `$Path` is missing, has no `*servicingstack*` directory, or is missing any of `Catalogs`/`Manifests`/`Fusion`/`FileMaps`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-core-helpers.ps1`, BEFORE the final `RESULT` block (i.e. before the line `Write-Host ""` that precedes the result):

```powershell
Write-Host '== Assert-WinSxSRebuild =='
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("winsxs_" + [guid]::NewGuid())
# A complete fake rebuild: servicing stack + all required metadata folders.
$null = New-Item -ItemType Directory -Path (Join-Path $tmp 'amd64_microsoft-windows-servicingstack_31bf3856ad364e35_x_none') -Force
foreach ($d in 'Catalogs','Manifests','Fusion','FileMaps') {
    $null = New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force
}
$ok = $true; try { Assert-WinSxSRebuild -Path $tmp } catch { $ok = $false }
Check 'complete rebuild passes' $ok

# Missing servicing stack -> throw.
$noStack = Join-Path ([System.IO.Path]::GetTempPath()) ("winsxs_" + [guid]::NewGuid())
foreach ($d in 'Catalogs','Manifests','Fusion','FileMaps') {
    $null = New-Item -ItemType Directory -Path (Join-Path $noStack $d) -Force
}
CheckThrows 'missing servicing stack throws' { Assert-WinSxSRebuild -Path $noStack }

# Missing a metadata folder -> throw.
$noMeta = Join-Path ([System.IO.Path]::GetTempPath()) ("winsxs_" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path (Join-Path $noMeta 'amd64_microsoft-windows-servicingstack_x') -Force
foreach ($d in 'Catalogs','Manifests','Fusion') {  # FileMaps intentionally missing
    $null = New-Item -ItemType Directory -Path (Join-Path $noMeta $d) -Force
}
CheckThrows 'missing metadata folder throws' { Assert-WinSxSRebuild -Path $noMeta }

CheckThrows 'missing path throws' { Assert-WinSxSRebuild -Path (Join-Path $tmp 'does-not-exist') }

Remove-Item $tmp, $noStack, $noMeta -Recurse -Force -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — `Assert-WinSxSRebuild` not recognized (the four new checks fail / error).

- [ ] **Step 3: Add the function**

In `tiny11Coremaker.ps1`, insert immediately AFTER `Resolve-OptionalUtilities`'s closing `}`:

```powershell
function Assert-WinSxSRebuild {
    # Integrity gate for the rebuilt WinSxS (WinSxS_edit) BEFORE the old WinSxS is
    # deleted. The servicing stack is mandatory for boot/sysprep; the metadata
    # folders are always present in a healthy component store. If anything critical
    # is missing the allowlist did not match this build - abort rather than ship a
    # non-bootable image (the caller's try/finally unloads hives and discards the
    # mount).
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) {
        throw "WinSxS rebuild path not found: $Path"
    }
    $hasServicingStack = @(Get-ChildItem -Path $Path -Directory -Filter '*servicingstack*' -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $hasServicingStack) {
        throw "WinSxS rebuild incomplete: no '*servicingstack*' directory under $Path. Aborting to avoid a non-bootable image."
    }
    $requiredMeta = 'Catalogs', 'Manifests', 'Fusion', 'FileMaps'
    $missing = $requiredMeta | Where-Object { -not (Test-Path (Join-Path $Path $_)) }
    if ($missing) {
        throw "WinSxS rebuild incomplete: missing $($missing -join ', ') under $Path. Aborting to avoid a non-bootable image."
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed`.

- [ ] **Step 5: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]`.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)`.

- [ ] **Step 6: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): WinSxS rebuild integrity gate (pure, tested)"
```

---

## Task 3: Parameter block + unattended plumbing + UAC forwarding

**Files:**
- Modify: `tiny11Coremaker.ps1` (very top; the elevation block; the drive-letter/index/continue/.NET prompts)

**Interfaces:**
- Consumes: `Resolve-OptionalUtilities` (Task 1) is NOT called here; only the parameters `-Keep`/`-Remove` are declared and validated, then passed through in Task 4.
- Produces: script-scope variables `$ISO`, `$SCRATCH`, `$Index`, `$EnableNet35`, `$Keep`, `$Remove`, `$Yes`, and `$mainOSDrive` derived from `-SCRATCH`.

- [ ] **Step 1: Add the `param()` block at the very top**

`param()` must be the first statement. Insert at the VERY TOP of `tiny11Coremaker.ps1`, before the current line 1 (`if ((Get-ExecutionPolicy)...`):

```powershell
#requires -Version 5.1
<#
.SYNOPSIS
    tiny11 Core image builder - a minimal, NON-SERVICEABLE Windows 11 image for
    testing, scripting, and VMs.

.DESCRIPTION
    By design this image cannot install Microsoft Store apps, has no Defender, no
    Windows Update, and cannot be serviced (no adding languages/updates/features).
    If you need any of those, use tiny11maker.ps1 instead.

.PARAMETER ISO
    Drive letter of the mounted Windows 11 image (e.g. E).
.PARAMETER SCRATCH
    Scratch/work drive letter. Defaults to the system drive.
.PARAMETER Index
    Image index to build.
.PARAMETER EnableNet35
    Enable .NET 3.5 without prompting.
.PARAMETER Keep
    Comma-separated optional utilities to RETAIN that default to removed
    (Paint, Camera, SoundRecorder, StickyNotes, Clock, MediaPlayer, MoviesTV, SnippingTool).
.PARAMETER Remove
    Comma-separated optional utilities to DROP that default to kept
    (Terminal, Calculator, Notepad, Photos).
.PARAMETER Yes
    Non-interactive: skip confirmation prompts and the utility picker; requires -ISO and -Index.
#>
param(
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [int]$Index,
    [switch]$EnableNet35,
    [string[]]$Keep = @(),
    [string[]]$Remove = @(),
    [switch]$Yes
)
```

- [ ] **Step 2: Forward parameters across the UAC relaunch**

In the admin-check block, replace:

```powershell
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
    $newProcess.Arguments = $myInvocation.MyCommand.Definition;
    $newProcess.Verb = "runas";
```

with:

```powershell
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell";
    # Forward parameters so the elevated instance does not fall back to prompting.
    $argList = "-File `"$($myInvocation.MyCommand.Definition)`""
    if ($ISO)        { $argList += " -ISO $ISO" }
    if ($SCRATCH)    { $argList += " -SCRATCH $SCRATCH" }
    if ($Index)      { $argList += " -Index $Index" }
    if ($EnableNet35){ $argList += " -EnableNet35" }
    if ($Keep)       { $argList += " -Keep $($Keep -join ',')" }
    if ($Remove)     { $argList += " -Remove $($Remove -join ',')" }
    if ($Yes)        { $argList += " -Yes" }
    $newProcess.Arguments = $argList;
    $newProcess.Verb = "runas";
```

- [ ] **Step 3: Derive `$mainOSDrive` from `-SCRATCH`; validate non-interactive prerequisites**

Find (currently ~line 73):

```powershell
$mainOSDrive = $env:SystemDrive
```

Replace with:

```powershell
if ($SCRATCH) { $mainOSDrive = $SCRATCH + ":" } else { $mainOSDrive = $env:SystemDrive }
# Validate optional-utility names early so a bad -Keep/-Remove fails before any work.
$null = Resolve-OptionalUtilities -Keep $Keep -Remove $Remove
if ($Yes) {
    if (-not $ISO)   { throw "-Yes requires -ISO (no interactive prompt available)." }
    if (-not $Index) { throw "-Yes requires -Index (no interactive prompt available)." }
}
```

- [ ] **Step 4: Make the continue / drive-letter / index / .NET prompts honor parameters**

(a) Continue prompt — replace:

```powershell
Write-Host "Do you want to continue? (y/n)"
$continueChoice = Read-Host

if ($continueChoice -eq 'y') {
```

with:

```powershell
if ($Yes) { $continueChoice = 'y' } else {
    Write-Host "Do you want to continue? (y/n)"
    $continueChoice = Read-Host
}

if ($continueChoice -eq 'y') {
```

(b) Drive letter — replace:

```powershell
$DriveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
$DriveLetter = $DriveLetter + ":"
```

with:

```powershell
if ($ISO) { $DriveLetter = $ISO } else {
    $DriveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
}
$DriveLetter = $DriveLetter + ":"
```

(c) Both index prompts — replace each occurrence of:

```powershell
        $index = Read-Host "Please enter the image index"
```

and

```powershell
$index = Read-Host "Please enter the image index"
```

with the parameter-aware form (apply to BOTH index prompts):

```powershell
if ($Index) { $index = $Index } else { $index = Read-Host "Please enter the image index" }
```

(d) .NET prompt — replace:

```powershell
Write-Host "Do you want to enable .NET 3.5? This cannot be done after the image has been created! (y/n)"
$enableNet35 = Read-Host

if ($enableNet35 -eq 'y') {
```

with:

```powershell
if ($EnableNet35) { $enableNet35 = 'y' }
elseif ($Yes)     { $enableNet35 = 'n' }
else {
    Write-Host "Do you want to enable .NET 3.5? This cannot be done after the image has been created! (y/n)"
    $enableNet35 = Read-Host
}

if ($enableNet35 -eq 'y') {
```

- [ ] **Step 5: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` for both scripts.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)`.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → still `0 failed` (functions unchanged).

- [ ] **Step 6: Grep assertions**

Run: `grep -n 'param(' tiny11Coremaker.ps1 | head -1`
Expected: a `param(` near the very top (line < 30).
Run: `grep -c 'Read-Host "Please enter the image index"' tiny11Coremaker.ps1`
Expected: `2` (both still present, now inside `if ($Index)` guards).

- [ ] **Step 7: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): -ISO/-SCRATCH/-Index/-EnableNet35/-Keep/-Remove/-Yes params + UAC forwarding"
```

---

## Task 4: Modernize removal list + wire optional utilities + interactive picker

**Files:**
- Modify: `tiny11Coremaker.ps1` (the `$packagePrefixes` definition and the removal loop, ~lines 173-183)

**Interfaces:**
- Consumes: `Resolve-OptionalUtilities` (Task 1), `$Keep`/`$Remove`/`$Yes` (Task 3).

- [ ] **Step 1: Replace the always-remove list (deduped, maker-aligned, NO optional utilities)**

Replace the single `$packagePrefixes = '...'` line (currently line 173) with the base bloat list.
None of the 12 optional-utility prefixes appear here — they are added in Step 2.

```powershell
# Always-remove bloat. The 12 optional standalone utilities (Terminal, Calculator,
# Notepad, Photos, Paint, Camera, SoundRecorder, StickyNotes, Clock, MediaPlayer,
# MoviesTV, SnippingTool) are handled separately in the next block via
# Get-OptionalUtilities / the picker / -Keep / -Remove, so they must NOT appear here.
$packagePrefixes = @(
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
```

- [ ] **Step 2: Resolve optional utilities (picker when interactive) and append, ONCE**

Immediately AFTER the block from Step 1, insert. This resolves the optional set exactly once
(picker path when interactive, defaults+params path under `-Yes`), then appends the chosen
removals. The name arrays are built with `ForEach-Object` so an empty selection yields `@()`,
never `$null` (which `Resolve-OptionalUtilities` would reject):

```powershell
if ($Yes) {
    $picked = Resolve-OptionalUtilities -Keep $Keep -Remove $Remove
} else {
    Write-Host ""
    Write-Host "Optional utilities (default state shown). Toggle any you want to change:"
    $utils = Get-OptionalUtilities
    $state = @{}
    for ($i = 0; $i -lt $utils.Count; $i++) {
        $u = $utils[$i]
        $s = $u.Default
        if ($Keep   -contains $u.Name) { $s = 'Keep' }
        if ($Remove -contains $u.Name) { $s = 'Remove' }
        $state[$u.Name] = $s
        Write-Host ("  {0,2}. [{1,-6}] {2}" -f ($i + 1), $s, $u.Name)
    }
    $answer = Read-Host "Enter numbers/names to TOGGLE (comma-separated), or press Enter to accept"
    if ($answer.Trim()) {
        foreach ($tokenRaw in ($answer -split ',')) {
            $token = $tokenRaw.Trim()
            if (-not $token) { continue }
            $name = $null
            if ($token -match '^[0-9]+$' -and [int]$token -ge 1 -and [int]$token -le $utils.Count) {
                $name = $utils[[int]$token - 1].Name
            } else {
                $m = $utils | Where-Object { $_.Name -eq $token }
                if ($m) { $name = $m.Name }
            }
            if ($name) {
                $state[$name] = if ($state[$name] -eq 'Keep') { 'Remove' } else { 'Keep' }
            } else {
                Write-Host "  (ignoring unknown entry '$token')"
            }
        }
    }
    $keepNames   = @($utils | Where-Object { $state[$_.Name] -eq 'Keep' }   | ForEach-Object { $_.Name })
    $removeNames = @($utils | Where-Object { $state[$_.Name] -eq 'Remove' } | ForEach-Object { $_.Name })
    $picked = Resolve-OptionalUtilities -Keep $keepNames -Remove $removeNames
}
$packagePrefixes = @($packagePrefixes) + @($picked.RemovePrefixes)
if ($picked.KeptNames) { Write-Host "Keeping optional utilities: $($picked.KeptNames -join ', ')" }
```

- [ ] **Step 3: Confirm the existing removal filter still works (no change)**

The existing filter (currently ~lines 175-178) already iterates `$packagePrefixes`; with it now an
array, no change is needed. Leave this block exactly as-is:

```powershell
$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
}
```

- [ ] **Step 4: Static + helper tests**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]`.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)`.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed`.

- [ ] **Step 5: Grep assertions (no optional prefix leaked into always-remove)**

Run: `grep -n "Microsoft.WindowsTerminal\|Microsoft.WindowsCalculator\|Microsoft.Windows.Photos\|Microsoft.WindowsNotepad" tiny11Coremaker.ps1`
Expected: matches ONLY inside `Get-OptionalUtilities` (the table), NOT inside `$packagePrefixes`.

- [ ] **Step 6: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): modernized removal list + optional-utility picker wiring"
```

---

## Task 5: Wire the WinSxS integrity gate + zero-match warnings

**Files:**
- Modify: `tiny11Coremaker.ps1` (the WinSxS copy loop and the `Deleting WinSxS` step, ~lines 353-364)

**Interfaces:**
- Consumes: `Assert-WinSxSRebuild` (Task 2).

- [ ] **Step 1: Add per-pattern zero-match warnings in the copy loop**

Find the shared copy loop (currently ~lines 353-360):

```powershell
foreach ($dir in $dirsToCopy) {
        $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Write-Host "Copying $sourceDir.FullName to $destDir"
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }
```

Replace with:

```powershell
foreach ($dir in $dirsToCopy) {
        $sourceDirs = @(Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory)
        if ($sourceDirs.Count -eq 0) {
            Write-Warning "WinSxS allowlist pattern matched nothing: $dir"
        }
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Write-Host "Copying $sourceDir.FullName to $destDir"
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }
```

- [ ] **Step 2: Assert integrity BEFORE deleting the old WinSxS**

Find (currently ~lines 363-364):

```powershell
Write-Host "Deleting WinSxS. This may take a while..."
        Remove-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS -Recurse -Force
```

Replace with:

```powershell
Write-Host "Validating rebuilt WinSxS before deleting the original..."
Assert-WinSxSRebuild -Path $destinationDirectory
Write-Host "Deleting WinSxS. This may take a while..."
        Remove-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS -Recurse -Force
```

- [ ] **Step 3: Static checks**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]`.
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)`.
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `0 failed`.

- [ ] **Step 4: Grep assertion (gate runs before the purge)**

Run: `grep -n 'Assert-WinSxSRebuild\|Deleting WinSxS' tiny11Coremaker.ps1`
Expected: the `Assert-WinSxSRebuild` line number is SMALLER than the `Deleting WinSxS` line number.

- [ ] **Step 5: Commit**

```bash
git add tiny11Coremaker.ps1
git commit -m "feat(core): WinSxS integrity gate + allowlist zero-match warnings"
```

---

## Task 6: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:** none.

- [ ] **Step 1: Add the limitations + optional-utilities section to README**

Append a new section to `README.md` (after the existing "What is removed" table). Use this exact Markdown (the outer block uses four backticks so the inner ```powershell``` fence is preserved):

````markdown
---

## tiny11 Core — limitations by design

tiny11 Core is a deliberately minimal, **non-serviceable** image for testing, scripting, and VMs.
The following are by design, not bugs:

- **No Microsoft Store app installation.** Store apps need Windows Update access, retained
  framework dependencies, and serviceability — all of which Core removes. If you need the Store,
  use `tiny11maker.ps1`.
- **No Windows Defender** (disabled).
- **No Windows Update** (disabled; re-enabling on a gutted component store would break the system).
- **Not serviceable** — you cannot add languages, updates, or features after creation.

### Optional utilities (`-Keep` / `-Remove`)

Standalone utility apps can be tailored. Defaults: `Terminal`, `Calculator`, `Notepad`, `Photos`
are **kept**; `Paint`, `Camera`, `SoundRecorder`, `StickyNotes`, `Clock`, `MediaPlayer`,
`MoviesTV`, `SnippingTool` are **removed**.

- Retain a default-removed utility: `-Keep Paint,Camera`
- Drop a default-kept utility: `-Remove Calculator,Photos`
- Without `-Yes`, an interactive picker lets you toggle each one.

### Unattended / batch builds

```powershell
.\tiny11Coremaker.ps1 -ISO E -SCRATCH D -Index 1 -EnableNet35 -Keep Paint -Remove Photos -Yes
```

`-Yes` runs non-interactively and requires `-ISO` and `-Index`.
````

- [ ] **Step 2: Verify the markdown renders (no broken fences)**

Run: `grep -c '^```' README.md`
Expected: an EVEN number (all code fences balanced).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: tiny11 Core limitations, optional utilities, unattended usage"
```

---

## Final verification (after all tasks)

- [ ] Run `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]` for both scripts.
- [ ] Run `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for both.
- [ ] Run `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`.
- [ ] **Windows real-build (manual, this round MUST include an amd64 image):**
  - `.\build.ps1` (interactive) — confirm the optional-utility picker appears and a kept utility survives.
  - Unattended: `.\tiny11Coremaker.ps1 -ISO <E> -SCRATCH <D> -Index <n> -Yes -Keep Paint` — confirm no `Read-Host` is hit and `tiny11.iso` is produced.
  - Fail-fast: `.\tiny11Coremaker.ps1 -Yes` (no `-ISO`) — confirm a clean `throw` message, not a hang.
  - Confirm the produced amd64 ISO boots in a VM (integrity gate did not false-positive).
