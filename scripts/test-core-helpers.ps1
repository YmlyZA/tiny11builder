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
Check 'defaults keep Calculator' ($r.KeptNames -contains 'Calculator')
Check 'defaults keep Notepad'    ($r.KeptNames -contains 'Notepad')
Check 'defaults keep Photos'     ($r.KeptNames -contains 'Photos')
Check 'defaults remove Paint MSPaint prefix' ($r.RemovePrefixes -contains 'Microsoft.MSPaint')

Write-Host '== Resolve overrides =='
$r = Resolve-OptionalUtilities -Keep @('Paint')
Check '-Keep Paint retains it' (-not ($r.RemovePrefixes -contains 'Microsoft.Paint'))
$r = Resolve-OptionalUtilities -Remove @('Terminal')
Check '-Remove Terminal drops it' ($r.RemovePrefixes -contains 'Microsoft.WindowsTerminal')
$r = Resolve-OptionalUtilities -Keep @('paint')
Check '-Keep is case-insensitive' (-not ($r.RemovePrefixes -contains 'Microsoft.Paint'))
$r = Resolve-OptionalUtilities -Remove @('terminal')
Check '-Remove is case-insensitive' ($r.RemovePrefixes -contains 'Microsoft.WindowsTerminal')

Write-Host '== Resolve errors =='
CheckThrows 'unknown name throws'        { Resolve-OptionalUtilities -Keep @('Nope') }
CheckThrows 'name in both lists throws'  { Resolve-OptionalUtilities -Keep @('Paint') -Remove @('Paint') }

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
Check '-Compress none wim export none' ($p.WimExportCompress -eq 'none')
$p = Resolve-BuildProfile -Compress 'none' -Fast
Check 'explicit compress overrides Fast' ($p.Compress -eq 'none')
Check 'Fast still skips cleanup w/ explicit compress' ($p.SkipCleanup -eq $true)
Check '-Compress none -Fast wim export none' ($p.WimExportCompress -eq 'none')
$p = Resolve-BuildProfile -Compress 'fast'
Check '-Compress fast direct'          ($p.Compress -eq 'fast')
Check '-Compress fast wim export fast' ($p.WimExportCompress -eq 'fast')
Check '-Compress fast no esd'          ($p.UseEsd -eq $false)
CheckThrows 'invalid compress throws'  { Resolve-BuildProfile -Compress 'zip' }

Write-Host '== Test-RobocopySucceeded =='
Check 'rc 0 success'  (Test-RobocopySucceeded 0)
Check 'rc 1 success'  (Test-RobocopySucceeded 1)
Check 'rc 7 success'  (Test-RobocopySucceeded 7)
Check 'rc 8 failure'  (-not (Test-RobocopySucceeded 8))
Check 'rc 16 failure' (-not (Test-RobocopySucceeded 16))

Write-Host '== Get-AlwaysRemovePackages =='
$base = Get-AlwaysRemovePackages
Check 'base list non-empty'          ($base.Count -gt 0)
Check 'base excludes Terminal'       (-not ($base -match 'WindowsTerminal'))
Check 'base excludes Calculator'     (-not ($base -match 'WindowsCalculator'))
Check 'base excludes Notepad'        (-not ($base -match 'WindowsNotepad'))
Check 'base excludes Photos'         (-not ($base -match 'Windows\.Photos'))

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

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
