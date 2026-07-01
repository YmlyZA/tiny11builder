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

Write-Host '== Test-IsoResult =='
Check 'iso ok'           (Test-IsoResult -ExitCode 0 -IsoExists $true  -IsoBytes 100)
Check 'iso bad exit'     (-not (Test-IsoResult -ExitCode 1 -IsoExists $true  -IsoBytes 100))
Check 'iso missing file' (-not (Test-IsoResult -ExitCode 0 -IsoExists $false -IsoBytes 0))
Check 'iso empty file'   (-not (Test-IsoResult -ExitCode 0 -IsoExists $true  -IsoBytes 0))

Write-Host '== New-UnattendXml =='
$uaA = New-UnattendXml -Architecture 'arm64' -UserName 'User' -Password '' -TimeZone 'UTC' -Language 'en-US'
$okA = $true; try { $null = [xml]$uaA } catch { $okA = $false }
Check 'tierA well-formed xml' $okA
Check 'tierA arch arm64'      ($uaA -match 'processorArchitecture="arm64"')
Check 'tierA index 1'         ($uaA -match '<Value>1</Value>')
Check 'tierA autologon'       ($uaA -match '<AutoLogon>')
Check 'tierA user name'       ($uaA -match '<Name>User</Name>')
Check 'tierA timezone'        ($uaA -match '<TimeZone>UTC</TimeZone>')
Check 'tierA no disk wipe'    (-not ($uaA -match 'WillWipeDisk'))
$uaB = New-UnattendXml -Architecture 'amd64' -UserName 'Tester' -Password 'p@ss' -TimeZone 'UTC' -Language 'en-US' -ZeroTouch
$okB = $true; try { $null = [xml]$uaB } catch { $okB = $false }
Check 'tierB well-formed xml' $okB
Check 'tierB arch amd64'      ($uaB -match 'processorArchitecture="amd64"')
Check 'tierB disk wipe'       ($uaB -match '<WillWipeDisk>true</WillWipeDisk>')
Check 'tierB installto part3' ($uaB -match '<PartitionID>3</PartitionID>')
Check 'tierB user name'       ($uaB -match '<Name>Tester</Name>')
$uaE = New-UnattendXml -Architecture 'amd64' -UserName 'a&b' -Password '' -TimeZone 'UTC' -Language 'en-US'
$okE = $true; try { $null = [xml]$uaE } catch { $okE = $false }
Check 'escaped user parses'   $okE
Check 'escaped user amp'      ($uaE -match '<Name>a&amp;b</Name>')

Write-Host '== maker parity: Resolve-BuildProfile =='
$makerPath = Join-Path $repo 'tiny11maker.ps1'
$mtk = $null; $mer = $null
$mast = [System.Management.Automation.Language.Parser]::ParseFile($makerPath, [ref]$mtk, [ref]$mer)
$mast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded', 'Get-AvailableImageIndex', 'Test-ImageIndexAvailable', 'Get-RequiredScratchBytes', 'Test-SufficientScratch', 'Resolve-OscdimgSource', 'Format-BuildSummary', 'Test-IsoResult' } |
    ForEach-Object { Invoke-Expression ($_.Extent.Text -replace 'function\s+(\S+)', 'function maker_$1') }
$mp = maker_Resolve-BuildProfile -Fast
Check 'maker -Fast compress fast' ($mp.Compress -eq 'fast')
Check 'maker -Fast skips cleanup' ($mp.SkipCleanup -eq $true)
Check 'maker rc 8 failure' (-not (maker_Test-RobocopySucceeded 8))

$mAvail = maker_Get-AvailableImageIndex @('Index : 1', 'Name : Windows 11 Pro', 'Size : 16,500,000,000 bytes')
Check 'maker parses one image'   ($mAvail.Count -eq 1)
Check 'maker index present'      (maker_Test-ImageIndexAvailable 1 $mAvail)
Check 'maker index absent'       (-not (maker_Test-ImageIndexAvailable 9 $mAvail))
Check 'maker required floor'     ((maker_Get-RequiredScratchBytes 1GB) -eq 20GB)
Check 'maker scratch short'      (-not (maker_Test-SufficientScratch 30GB 20GB).Ok)
Check 'maker oscdimg download'   ((maker_Resolve-OscdimgSource $false $false) -eq 'download')
$mSummary = maker_Format-BuildSummary -Elapsed (New-TimeSpan -Minutes 1 -Seconds 2) -IsoBytes 1073741824 -IsoPath 'C:\a.iso' -AppsRemoved 5 -AppsTotal 5 -Warnings 0
Check 'maker summary success'  ($mSummary -contains '  Result        : SUCCESS')
Check 'maker summary size 1GB' ($mSummary -contains '  Output ISO    : C:\a.iso  (1.00 GB)')
Check 'maker summary apps 5/5' ($mSummary -contains '  Apps removed  : 5 of 5 provisioned Appx')
Check 'maker iso ok'       (maker_Test-IsoResult -ExitCode 0 -IsoExists $true -IsoBytes 100)
Check 'maker iso bad exit' (-not (maker_Test-IsoResult -ExitCode 1 -IsoExists $true -IsoBytes 100))

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
