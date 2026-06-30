#requires -Version 5.1
<#
.SYNOPSIS
    Layer 1 static parse check for the tiny11 builder scripts.
.DESCRIPTION
    Uses the PowerShell language parser to confirm both scripts are
    syntactically valid on the runtime you launch this with (run it under
    Windows PowerShell 5.1 - the version the project targets). No image or
    admin rights required. Exits 1 if any file fails to parse.
#>
$repo    = Split-Path -Parent $PSScriptRoot
$targets = 'tiny11maker.ps1', 'tiny11Coremaker.ps1'
$failed  = $false

foreach ($name in $targets) {
    $path = Join-Path $repo $name
    if (-not (Test-Path $path)) { Write-Host "skip: $name not found"; continue }

    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count) {
        $failed = $true
        Write-Host "[FAIL] $name : $($errors.Count) parse error(s)"
        $errors | ForEach-Object { Write-Host ("       line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    } else {
        Write-Host "[OK]   $name : parses clean on $($PSVersionTable.PSVersion)"
    }
}

if ($failed) { exit 1 }
