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
