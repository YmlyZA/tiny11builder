#requires -Version 5.1
<#
.SYNOPSIS
    Layer 2 real-build test harness for tiny11 Core.
.DESCRIPTION
    Run from an ELEVATED Windows PowerShell 5.1 prompt with the Windows 11 ISO
    already mounted in Explorer. tiny11Coremaker.ps1 is interactive: it will
    prompt for the mounted image's drive letter, the image index, whether to
    continue, and whether to enable .NET 3.5.

    The autounattend.xml deletion is deliberate: it forces the script's download
    path to run, which is what exposed the "Cannot find path ...autounattend.xml"
    bug that this branch fixes.
#>
Set-ExecutionPolicy Bypass -Scope Process -Force

# Remove any leftover local answer file so the download branch is exercised.
Remove-Item "$PSScriptRoot\autounattend.xml" -ErrorAction SilentlyContinue

# Run the Core builder (self-elevates if needed; interactive prompts follow).
& "$PSScriptRoot\tiny11Coremaker.ps1"
