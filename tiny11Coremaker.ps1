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
# $Password is intentionally plain-text: it is written verbatim into autounattend.xml for Windows Setup.
param(
    [ValidatePattern('^[c-zC-Z]$')][string]$ISO,
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [int]$Index,
    [switch]$EnableNet35,
    [string[]]$Keep = @(),
    [string[]]$Remove = @(),
    [switch]$Yes,
    [switch]$DryRun,
    [ValidateSet('recovery', 'fast', 'none')][string]$Compress,
    [switch]$Fast,
    [string]$User = 'User',
    [string]$Password = '',
    [string]$TimeZone = 'UTC',
    [switch]$ZeroTouch
)

# Normalize comma-separated values so -Keep "Paint,Camera" (one quoted token)
# behaves the same as -Keep Paint,Camera (a native array). @() keeps them arrays when empty.
$Keep   = @($Keep   | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })
$Remove = @($Remove | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        Write-Host "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole))
{
    Write-Host "Restarting Tiny11 image creator as admin in a new window, you can close this one."
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
    if ($DryRun)     { $argList += " -DryRun" }
    if ($Compress)   { $argList += " -Compress $Compress" }
    if ($Fast)       { $argList += " -Fast" }
    $argList += " -User `"$User`""
    if ($Password) { $argList += " -Password `"$Password`"" }
    $argList += " -TimeZone `"$TimeZone`""
    if ($ZeroTouch) { $argList += " -ZeroTouch" }
    $newProcess.Arguments = $argList;
    $newProcess.Verb = "runas";
    [System.Diagnostics.Process]::Start($newProcess);
    exit
}

#---------[ Helper functions ]---------#
function Invoke-Dism {
    # Run DISM and abort the script if it reports a non-zero exit code. Use only
    # for load-bearing operations (mount / unmount / export / convert); package
    # removal stays soft because some packages legitimately refuse to be removed.
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DismArgs)
    & dism.exe @DismArgs
    if ($LASTEXITCODE -ne 0) {
        throw "DISM failed (exit code $LASTEXITCODE): dism $($DismArgs -join ' ')"
    }
}

function Remove-OfflineHives {
    # Idempotently unload every offline hive this script loads. Safe to call even
    # if some are not currently loaded (errors suppressed). The GC pass first
    # releases any lingering handles so the unloads actually succeed.
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    foreach ($hive in 'zCOMPONENTS', 'zDEFAULT', 'zNTUSER', 'zSOFTWARE', 'zSYSTEM') {
        reg unload "HKLM\$hive" > $null 2>&1
    }
}

function Dismount-OfflineImage {
    # Safety-net dismount for finally blocks: if an image is still mounted at
    # $MountDir, discard the (incomplete) changes so the host is never left with
    # a stuck mount point.
    param([string]$MountDir)
    if (-not $MountDir) { return }
    # Use string concatenation, not Join-Path: Join-Path resolves the PSDrive and
    # raises DriveNotFound when the drive is gone. A finally-block helper must never
    # throw (or print a stray error), so concat + a backstop catch keep it silent.
    $mounted = $false
    try { $mounted = Test-Path "$MountDir\Windows" } catch { return }
    if ($mounted) {
        Write-Host "Cleanup: discarding a still-mounted image at $MountDir ..."
        & dism.exe /English /unmount-image "/mountdir:$MountDir" /discard 2>&1 | Out-Null
    }
}

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
    if ($images.Count -eq 0) { return @() }
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
    $sizeText    = "{0} GB" -f (($IsoBytes / 1GB).ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture))
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

function Test-IsoResult {
    # The ISO step succeeded only if oscdimg exited 0 AND a non-empty file exists.
    param([int]$ExitCode, [bool]$IsoExists, [long]$IsoBytes)
    return ($ExitCode -eq 0 -and $IsoExists -and $IsoBytes -gt 0)
}

function New-UnattendXml {
    # Pure: builds the complete Windows Setup answer file (windowsPE + oobeSystem).
    # Tier A (default) skips OOBE to an auto-logged-in local admin; -ZeroTouch adds
    # a disk-0 wipe (clean UEFI layout) for a zero-click install. Arch-aware.
    # Password is intentionally plain-text: Windows Setup autounattend.xml requires it.
    param(
        [ValidateSet('amd64', 'arm64')][string]$Architecture,
        [string]$UserName,
        [string]$Password,
        [string]$TimeZone,
        [string]$Language = 'en-US',
        [switch]$ZeroTouch
    )
    $escUser = [System.Security.SecurityElement]::Escape($UserName)
    $escPass = [System.Security.SecurityElement]::Escape($Password)
    $escTz   = [System.Security.SecurityElement]::Escape($TimeZone)
    $ns      = 'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    $common  = "publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`" $ns"
    if ($ZeroTouch) {
        $diskConfig = @"

            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                        <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                        <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format></ModifyPartition>
                        <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                        <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Format>NTFS</Format><Letter>C</Letter></ModifyPartition>
                    </ModifyPartitions>
                </Disk>
                <WillShowUI>OnError</WillShowUI>
            </DiskConfiguration>
"@
        $installTo = '<InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>'
    } else {
        $diskConfig = ''
        $installTo  = ''
    }
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="$Architecture" $common>
            <SetupUILanguage><UILanguage>$Language</UILanguage></SetupUILanguage>
            <InputLocale>$Language</InputLocale>
            <SystemLocale>$Language</SystemLocale>
            <UILanguage>$Language</UILanguage>
            <UserLocale>$Language</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="$Architecture" $common>
            <UserData>
                <ProductKey><Key></Key></ProductKey>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <ImageInstall>
                <OSImage>
                    <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>
                    $installTo
                    <WillShowUI>OnError</WillShowUI>
                </OSImage>
            </ImageInstall>$diskConfig
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="$Architecture" $common>
            <InputLocale>$Language</InputLocale>
            <SystemLocale>$Language</SystemLocale>
            <UILanguage>$Language</UILanguage>
            <UserLocale>$Language</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$Architecture" $common>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$escUser</Name>
                        <Group>Administrators</Group>
                        <Password><Value>$escPass</Value><PlainText>true</PlainText></Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Username>$escUser</Username>
                <Enabled>true</Enabled>
                <LogonCount>999999999</LogonCount>
                <Password><Value>$escPass</Value><PlainText>true</PlainText></Password>
            </AutoLogon>
            <TimeZone>$escTz</TimeZone>
            <UserData><ProductKey><Key></Key></ProductKey></UserData>
        </component>
    </settings>
</unattend>
"@
}

# Close any transcript leaked by a prior aborted run in this same session,
# so this run always starts its own clean transcript.
Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
Start-Transcript -Path "$PSScriptRoot\tiny11.log"
$buildStart = Get-Date
$script:buildWarnings = 0
# Ask the user for input
Write-Host "Welcome to tiny11 core builder! BETA 09-05-25"
Write-Host "This script generates a significantly reduced Windows 11 image. However, it's not suitable for regular use due to its lack of serviceability - you can't add languages, updates, or features post-creation. tiny11 Core is not a full Windows 11 substitute but a rapid testing or development tool, potentially useful for VM environments."
if ($Yes) { $continueChoice = 'y' } else {
    Write-Host "Do you want to continue? (y/n)"
    $continueChoice = Read-Host
}

if ($continueChoice -eq 'y') {
    Write-Host "Off we go..."
Start-Sleep -Seconds 3
Clear-Host

if ($SCRATCH) { $mainOSDrive = $SCRATCH + ":" } else { $mainOSDrive = $env:SystemDrive }
# Fail fast with a clear message if the scratch drive does not exist (a bad -SCRATCH
# otherwise cascades into cryptic DISM 'Error: 3' / DriveNotFound failures).
if (-not (Test-Path "$mainOSDrive\")) {
    throw "Scratch drive '$mainOSDrive' was not found. Pass -SCRATCH with an existing drive letter, or omit it to use the system drive ($env:SystemDrive)."
}
# Validate optional-utility names early so a bad -Keep/-Remove fails before any work.
$null = Resolve-OptionalUtilities -Keep $Keep -Remove $Remove
if ($Yes) {
    if (-not $ISO)   { throw "-Yes requires -ISO (no interactive prompt available)." }
    if (-not $Index) { throw "-Yes requires -Index (no interactive prompt available)." }
}
# This script always works on the system drive; $ScratchDisk is kept as an
# alias of $mainOSDrive so the registry/oscdimg sections that reference it
# resolve to a real, absolute path instead of an empty string.
$ScratchDisk = $mainOSDrive
$buildProfile = Resolve-BuildProfile -Compress $Compress -Fast:$Fast
if ($ZeroTouch) { Write-Warning "-ZeroTouch: the produced image will ERASE DISK 0 automatically during Windows Setup. Use only on VMs / dedicated test machines." }
Write-Verbose "Build profile: Compress=$($buildProfile.Compress) SkipCleanup=$($buildProfile.SkipCleanup) UseEsd=$($buildProfile.UseEsd)"
$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path "$mainOSDrive\tiny11\sources" > $null
}
if ($ISO) { $DriveLetter = $ISO } else {
    $DriveLetter = Read-Host "Please enter the drive letter for the Windows 11 image"
}
$DriveLetter = $DriveLetter + ":"
if (-not (Test-Path "$DriveLetter\")) {
    throw "Image drive '$DriveLetter' was not found. Mount the Windows 11 ISO and pass its drive letter via -ISO (or at the prompt)."
}

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

if ($DryRun) {
    $drOpt  = Resolve-OptionalUtilities -Keep $Keep -Remove $Remove
    $drBase = Get-AlwaysRemovePackages
    Write-Host ""
    Write-Host "===== DRY RUN (no copy / no mount performed) ====="
    Write-Host "  Image drive (-ISO)   : $DriveLetter"
    Write-Host "  Scratch (-SCRATCH)   : $mainOSDrive"
    Write-Host ("  Image index (-Index) : {0}" -f $(if ($Index) { $Index } else { '(prompt at build time)' }))
    Write-Host "  Unattended user      : $User (autologon)"
    Write-Host "  Time zone            : $TimeZone"
    Write-Host "  Install mode         : $(if ($ZeroTouch) { 'ZeroTouch (ERASES disk 0)' } else { 'OOBE-skip (keeps disk selection)' })"
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
    Stop-Transcript -ErrorAction SilentlyContinue
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
    $script:buildWarnings++
}

# Resolve the image index once (validated against the source image), used by both
# the ESD->WIM conversion and the mount. Interactive entry re-prompts until valid.
if ($Index) { $imageIndex = $Index }
while ($ImagesIndex -notcontains $imageIndex) {
    if ($Yes) { throw "Image index '$imageIndex' not found in install.wim; pass a valid -Index for unattended runs." }
    & 'dism' '/English' '/Get-WimInfo' "/wimfile:$preflightImage"
    $imageIndex = Read-Host "Please enter the image index"
}

# Everything from here on touches a mounted image and/or loaded offline hives.
# Wrap it so that ANY terminating failure still tears those down (see finally),
# instead of leaving the host with a stuck mount or loaded hives.
$script:buildFailed = $false
try {

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
    if ((Test-Path "$DriveLetter\sources\install.esd") -eq $true) {
        Write-Host "Found install.esd, converting to install.wim..."
        &  'dism' '/English' "/Get-WimInfo" "/wimfile:$DriveLetter\sources\install.esd"
        Write-Host ' '
        Write-Host 'Converting install.esd to install.wim. This may take a while...'
        Invoke-Dism /Export-Image /SourceImageFile:"$DriveLetter\sources\install.esd" /SourceIndex:$imageIndex /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.wim" /Compress:max /CheckIntegrity
        # The exported WIM holds the chosen edition as its only image (index 1);
        # mount and re-export must target index 1, not the source ESD's index.
        $imageIndex = 1
    } else {
        throw "Can't find Windows OS installation files on drive $DriveLetter (no install.wim or install.esd under \sources). Check the -ISO drive letter."
    }
}

Write-Host "Copying Windows image..."
Invoke-Robocopy -Source "$DriveLetter\" -Destination "$mainOSDrive\tiny11"
Set-ItemProperty -Path "$mainOSDrive\tiny11\sources\install.esd" -Name IsReadOnly -Value $false > $null 2>&1
Remove-Item "$mainOSDrive\tiny11\sources\install.esd" > $null 2>&1
Write-Host "Copy complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Getting image information:"
&  'dism' '/English' "/Get-WimInfo" "/wimfile:$mainOSDrive\tiny11\sources\install.wim"
Write-Host "Mounting Windows image. This may take a while."
$wimFilePath = "$mainOSDrive\tiny11\sources\install.wim" 
& takeown "/F" $wimFilePath 
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
try {
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {
    # Clearing the read-only attribute is best-effort; the WIM may already be
    # writable. Note it verbosely instead of leaving an empty catch.
    Write-Verbose "Could not clear read-only on $wimFilePath : $_"
}
# A previous interrupted/failed run can leave scratchdir populated or holding an
# orphaned WIM mount; DISM refuses to mount into a non-empty directory. Clean up
# first: clear orphaned mountpoints, discard a leftover mount at scratchdir if one
# looks present, then remove and recreate the directory empty. All best-effort.
& dism.exe /English /Cleanup-Mountpoints 2>&1 | Out-Null
if (Test-Path "$mainOSDrive\scratchdir\Windows") {
    & dism.exe /English /Unmount-Image "/MountDir:$mainOSDrive\scratchdir" /Discard 2>&1 | Out-Null
}
Remove-Item -Path "$mainOSDrive\scratchdir" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$mainOSDrive\scratchdir" > $null
Invoke-Dism /English /mount-image "/imagefile:$mainOSDrive\tiny11\sources\install.wim" "/index:$imageIndex" "/mountdir:$mainOSDrive\scratchdir"

$imageIntl = & dism /English /Get-Intl "/Image:$mainOSDrive\scratchdir"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Host "Default system UI language code: $languageCode"
} else {
    Write-Host "Default system UI language code not found."
}

$imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$mainOSDrive\tiny11\sources\install.wim" "/index:$imageIndex"
$lines = $imageInfo -split '\r?\n'

foreach ($line in $lines) {
    if ($line -like '*Architecture : *') {
        $architecture = $line -replace 'Architecture : ',''
        # If the architecture is x64, replace it with amd64
        if ($architecture -eq 'x64') {
            $architecture = 'amd64'
        }
        Write-Host "Architecture: $architecture"
        break
    }
}

if (-not $architecture) {
    Write-Host "Architecture information not found."
}

Write-Host "Mounting complete! Performing removal of applications..."

$packages = & 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Get-ProvisionedAppxPackages' |
    ForEach-Object {
        if ($_ -match 'PackageName : (.*)') {
            $matches[1]
        }
    }
# Always-remove bloat comes from Get-AlwaysRemovePackages (single source of truth,
# also used by -DryRun). Optional utilities are merged in by the picker block below.
$packagePrefixes = Get-AlwaysRemovePackages
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

$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
}
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

Write-Host "Removing of system apps complete! Now proceeding to removal of system packages..."
Start-Sleep -Seconds 1
Clear-Host

$scratchDir = "$mainOSDrive\scratchdir"
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64",
    "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35",
    "Windows-Defender-Client-Package~31bf3856ad364e35~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-StepsRecorder-Package~"

)

# Get all packages. /Format:List prints the full, untruncated "Package Identity"
# on its own line; /Format:Table can clip long names into invalid identities.
# /English keeps the label stable regardless of the image's UI language.
$allPackages = & dism /English /image:$scratchDir /Get-Packages /Format:List |
    ForEach-Object {
        if ($_ -match 'Package Identity : (.+)') { $matches[1].Trim() }
    }

foreach ($packagePattern in $packagePatterns) {
    # Filter the packages to remove
    $packagesToRemove = $allPackages | Where-Object { $_ -like "$packagePattern*" }

    foreach ($packageIdentity in $packagesToRemove) {
        Write-Host "Removing $packageIdentity..."
        & dism /English /image:$scratchDir /Remove-Package /PackageName:$packageIdentity
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  warning: could not remove $packageIdentity (exit $LASTEXITCODE), continuing."
            $script:buildWarnings++
        }
    }
}

if ($EnableNet35) { $net35Choice = 'y' }
elseif ($Yes)     { $net35Choice = 'n' }
else {
    Write-Host "Do you want to enable .NET 3.5? This cannot be done after the image has been created! (y/n)"
    $net35Choice = Read-Host
}

if ($net35Choice -eq 'y') {
    Write-Host "Enabling .NET 3.5..."
    & 'dism'  "/image:$scratchDir" '/enable-feature' '/featurename:NetFX3' '/All' "/source:$mainOSDrive\tiny11\sources\sxs"
    Write-Host ".NET 3.5 has been enabled."
}
elseif ($net35Choice -eq 'n') {
    Write-Host "You chose not to enable .NET 3.5. Continuing..."
}
else {
    Write-Host "Invalid input. Please enter 'y' to enable .NET 3.5 or 'n' to continue without installing .net 3.5."
}
Write-Host "Removing Edge:"
Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue > $null
Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue > $null
Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue > $null
# NOTE: the Edge WebView component under WinSxS is intentionally NOT deleted here.
# tiny11 Core rebuilds WinSxS from an allowlist further down (copy allowlist to
# WinSxS_edit -> delete the old WinSxS -> rename), and edge-webview is not in that
# allowlist, so it is purged wholesale by the rebuild. Deleting it at this point
# was redundant AND, because takeown/icacls don't reliably reclaim the nested
# EBWebView files before the WinSxS-wide takeown runs, it produced ~900 "Access
# denied" errors per run. The System32 copy below is a different path that the
# rebuild does NOT cover, so that removal stays.
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r' 2>$null
& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' 2>$null
Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Removing WinRE"
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Recovery" '/r'
& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Recovery" '/grant' 'Administrators:F' '/T' '/C'
Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -ItemType File -Force
Write-Host "Removing OneDrive:"
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" > $null 2>$null
& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' > $null 2>$null
Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue > $null
Write-Host "Removal complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Taking ownership of the WinSxS folder. This might take a while..."
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\WinSxS" '/r'
& 'icacls' "$mainOSDrive\scratchdir\Windows\WinSxS" '/grant' "$($adminGroup.Value):(F)" '/T' '/C'
Write-host "Complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Preparing..."
$folderPath = Join-Path -Path $mainOSDrive -ChildPath "\scratchdir\Windows\WinSxS_edit"
$sourceDirectory = "$mainOSDrive\scratchdir\Windows\WinSxS"
$destinationDirectory = "$mainOSDrive\scratchdir\Windows\WinSxS_edit"
New-Item -Path $folderPath -ItemType Directory
if ($architecture -eq "amd64") {
   $dirsToCopy = @(
        "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",    
        "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
        "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
        "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
        "x86_microsoft-windows-servicingstack-inetsrv_*",
        "x86_microsoft-windows-servicingstack-onecore_*",
        "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
        "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
        "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
        "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
        "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
        "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
        "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
        "Catalogs",
        "FileMaps",
        "Fusion",
        "InstallTemp",
        "Manifests",
        "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
        "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
        "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
        "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
    )
    # NOTE: the actual copy is performed by the shared loop after this if/elseif,
    # so amd64 must NOT copy here as well (that doubled the slowest step).
}
 elseif ($architecture -eq "arm64") {
    # Specify the list of files to copy
     $dirsToCopy = @(
        "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
        "Catalogs"
        "FileMaps"
        "Fusion"
        "InstallTemp"
        "Manifests"
        "SettingsManifests"
        "Temp"
        "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
        "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
        "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        "x86_microsoft.windows.common-controls_6595b64144ccf1df_*"
        "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*"
        "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
        "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
        "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*"
        "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*"
        "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
        "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*"
        "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*"
        "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*"
        "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*"
        "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*"
        "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*"
        "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*"
        "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*"
        "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*"
        "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
    )
}
foreach ($dir in $dirsToCopy) {
        $sourceDirs = @(Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory)
        if ($sourceDirs.Count -eq 0) {
            Write-Warning "WinSxS allowlist pattern matched nothing: $dir"
            $script:buildWarnings++
        }
        foreach ($sourceDir in $sourceDirs) {
            $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
            Write-Host "Copying $sourceDir.FullName to $destDir"
            Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
        }
    }  


Write-Host "Validating rebuilt WinSxS before deleting the original..."
Assert-WinSxSRebuild -Path $destinationDirectory
Write-Host "Deleting WinSxS. This may take a while..."
        Remove-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS -Recurse -Force

Rename-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS_edit -NewName $mainOSDrive\scratchdir\Windows\WinSxS
Write-Host "Complete!"

Write-Host "Loading registry..."
reg load HKLM\zCOMPONENTS $ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS | Out-Null
reg load HKLM\zDEFAULT $ScratchDisk\scratchdir\Windows\System32\config\default | Out-Null
reg load HKLM\zNTUSER $ScratchDisk\scratchdir\Users\Default\ntuser.dat | Out-Null
reg load HKLM\zSOFTWARE $ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE | Out-Null
reg load HKLM\zSYSTEM $ScratchDisk\scratchdir\Windows\System32\config\SYSTEM | Out-Null
Write-Host "Bypassing system requirements(on the system image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Disabling Sponsored Apps:"
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableWindowsConsumerFeatures' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' '/v' 'ConfigureStartPins' '/t' 'REG_SZ' '/d' '{"pinnedList": [{}]}' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'ContentDeliveryAllowed' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'FeatureManagementEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'OemPreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'PreInstalledAppsEverEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SilentInstalledAppsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SoftLandingEnabled' '/t' 'REG_DWORD' '/d' '0' '/f'| Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-310093Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338388Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338389Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-338393Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353694Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContent-353696Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SubscribedContentEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' '/v' 'SystemPaneSuggestionsEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' '/v' 'DisablePushToInstall' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' '/v' 'DontOfferThroughWUAU' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableConsumerAccountStateContent' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' '/v' 'DisableCloudOptimizedContent' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Enabling Local Accounts on OOBE:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'BypassNRO' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
$langForUnattend = if ($languageCode) { $languageCode } else { 'en-US' }
$unattendXml = New-UnattendXml -Architecture $architecture -UserName $User -Password $Password -TimeZone $TimeZone -Language $langForUnattend -ZeroTouch:$ZeroTouch
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml", $unattendXml, $utf8NoBom)
[System.IO.File]::WriteAllText("$ScratchDisk\tiny11\autounattend.xml", $unattendXml, $utf8NoBom)
Write-Host "Disabling Reserved Storage:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' '/v' 'ShippedWithReserves' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
Write-Host "Disabling BitLocker Device Encryption"
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' '/v' 'PreventDeviceEncryption' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Disabling Chat icon:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' '/v' 'ChatIcon' '/t' 'REG_DWORD' '/d' '3' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' '/v' 'TaskbarMn' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
Write-Host "Removing Edge related registries"
reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f | Out-Null
reg delete "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f | Out-Null
Write-Host "Disabling OneDrive folder backup"
& 'reg' 'add' "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" '/v' 'DisableFileSyncNGSC' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Disabling Telemetry:"
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' '/v' 'TailoredExperiencesWithDiagnosticDataEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' '/v' 'HasAccepted' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' '/v' 'Enabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitInkCollection' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' '/v' 'RestrictImplicitTextCollection' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' '/v' 'HarvestContacts' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' '/v' 'AcceptedPrivacyPolicy' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' '/v' 'AllowTelemetry' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' | Out-Null
Write-Host "Prevents installation or DevHome and Outlook:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' '/v' 'workCompleted' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' '/f' | Out-Null
& 'reg' 'delete' 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate' '/f' | Out-Null
Write-Host "Disabling Copilot"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' '/v' 'TurnOffWindowsCopilot' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' '/v' 'HubsSidebarEnabled' '/t' 'REG_DWORD' '/d' '0' '/f' | Out-Null
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' '/v' 'DisableSearchBoxSuggestions' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Prevents installation of Teams:"
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' '/v' 'DisableInstallation' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
Write-Host "Prevent installation of New Outlook":
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' '/v' 'PreventRun' '/t' 'REG_DWORD' '/d' '1' '/f' | Out-Null
$tasksPath = "$mainOSDrive\scratchdir\Windows\System32\Tasks"

Write-Host "Deleting scheduled task definition files..."

# Application Compatibility Appraiser
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue

# Customer Experience Improvement Program (removes the entire folder and all tasks within it)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue

# Program Data Updater
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue

# Chkdsk Proxy
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue

# Windows Error Reporting (QueueReporting)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

Write-Host "Task files have been deleted."
Write-Host "Disabling Windows Update..."
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE1' '/t' 'REG_SZ' '/d' 'net stop wuauserv' '/f'
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE2' '/t' 'REG_SZ' '/d' 'sc stop wuauserv' '/f'
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'StopWUPostOOBE3' '/t' 'REG_SZ' '/d' 'sc config wuauserv start= disabled' '/f'
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE1' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f'
& 'reg' 'add' "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" '/v' 'DisbaleWUPostOOBE2' '/t' 'REG_SZ' '/d' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f' '/f'
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DoNotConnectToWindowsUpdateInternetLocations' '/t' 'REG_DWORD' '/d' '1' '/f'
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'DisableWindowsUpdateAccess' '/t' 'REG_DWORD' '/d' '1' '/f' 
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'WUStatusServer' '/t' 'REG_SZ' '/d' 'localhost' '/f' 
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' '/v' 'UpdateServiceUrlAlternate' '/t' 'REG_SZ' '/d' 'localhost' '/f' 
& 'reg' 'add' 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'UseWUServer' '/t' 'REG_DWORD' '/d' '1' '/f' 
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' '/v' 'DisableOnline' '/t' 'REG_DWORD' '/d' '1' '/f' 
& 'reg' 'add' 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' 
& 'reg' 'delete' 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC' '/f'
& 'reg' 'delete' 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc' '/f'
& 'reg' 'add' 'HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' '/v' 'NoAutoUpdate' '/t' 'REG_DWORD' '/d' '1' '/f'
Write-Host "Disabling Windows Defender"
# Set registry values for Windows Defender services
$servicePaths = @(
    "WinDefend",
    "WdNisSvc",
    "WdNisDrv",
    "WdFilter",
    "Sense"
)

foreach ($path in $servicePaths) {
    # Use reg.exe rather than the HKLM:\ PSDrive: a Set-ItemProperty here keeps a
    # handle open on the zSYSTEM hive, which can make the later 'reg unload zSYSTEM'
    # fail and leave the hive loaded when the image is committed.
    & 'reg' 'add' "HKLM\zSYSTEM\ControlSet001\Services\$path" '/v' 'Start' '/t' 'REG_DWORD' '/d' '4' '/f' | Out-Null
}
& 'reg' 'add' 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' '/v' 'SettingsPageVisibility' '/t' 'REG_SZ' '/d' 'hide:virus;windowsupdate' '/f' 
Write-Host "Tweaking complete!"
Write-Host "Unmounting Registry..."
Remove-OfflineHives
if ($buildProfile.SkipCleanup) {
    Write-Host "Skipping component cleanup (-Fast)."
} else {
    Write-Host "Cleaning up image..."
    & 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' > $null
    Write-Host "Cleanup complete."
}
Write-Host ' '
Write-Host "Unmounting image..."
Invoke-Dism '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
Write-Host "Exporting image (compress: $($buildProfile.WimExportCompress))..."
Invoke-Dism '/English' '/Export-Image' "/SourceImageFile:$mainOSDrive\tiny11\sources\install.wim" "/SourceIndex:$imageIndex" "/DestinationImageFile:$mainOSDrive\tiny11\sources\install2.wim" "/compress:$($buildProfile.WimExportCompress)"
Remove-Item -Path "$mainOSDrive\tiny11\sources\install.wim" -Force > $null
Rename-Item -Path "$mainOSDrive\tiny11\sources\install2.wim" -NewName "install.wim" > $null
Write-Host "Windows image completed. Continuing with boot.wim."
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Mounting boot image:"
$wimFilePath = "$mainOSDrive\tiny11\sources\boot.wim" 
& takeown "/F" $wimFilePath > $null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
Invoke-Dism '/English' '/mount-image' "/imagefile:$mainOSDrive\tiny11\sources\boot.wim" '/index:2' "/mountdir:$mainOSDrive\scratchdir"
Write-Host "Loading registry..."
reg load HKLM\zCOMPONENTS $mainOSDrive\scratchdir\Windows\System32\config\COMPONENTS
reg load HKLM\zDEFAULT $mainOSDrive\scratchdir\Windows\System32\config\default
reg load HKLM\zNTUSER $mainOSDrive\scratchdir\Users\Default\ntuser.dat
reg load HKLM\zSOFTWARE $mainOSDrive\scratchdir\Windows\System32\config\SOFTWARE
reg load HKLM\zSYSTEM $mainOSDrive\scratchdir\Windows\System32\config\SYSTEM
Write-Host "Bypassing system requirements(on the setup image):"
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' > $null
& 'reg' 'add' 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' > $null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV1' '/t' 'REG_DWORD' '/d' '0' '/f' > $null
& 'reg' 'add' 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' '/v' 'SV2' '/t' 'REG_DWORD' '/d' '0' '/f' > $null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassCPUCheck' '/t' 'REG_DWORD' '/d' '1' '/f' > $null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassRAMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' > $null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassSecureBootCheck' '/t' 'REG_DWORD' '/d' '1' '/f' > $null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassStorageCheck' '/t' 'REG_DWORD' '/d' '1' '/f' > $null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\LabConfig' '/v' 'BypassTPMCheck' '/t' 'REG_DWORD' '/d' '1' '/f' > $null
& 'reg' 'add' 'HKLM\zSYSTEM\Setup\MoSetup' '/v' 'AllowUpgradesWithUnsupportedTPMOrCPU' '/t' 'REG_DWORD' '/d' '1' '/f' > $null
& 'reg' 'add' 'HKEY_LOCAL_MACHINE\zSYSTEM\Setup' '/v' 'CmdLine' '/t' 'REG_SZ' '/d' 'X:\sources\setup.exe' '/f' > $null
Write-Host "Tweaking complete!"
Write-Host "Unmounting Registry..."
Remove-OfflineHives
Write-Host "Unmounting image..."
Invoke-Dism '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
Clear-Host
if ($buildProfile.UseEsd) {
    Write-Host "Exporting ESD. This may take a while..."
    Invoke-Dism /Export-Image /SourceImageFile:"$mainOSDrive\tiny11\sources\install.wim" /SourceIndex:1 /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.esd" /Compress:recovery
    Remove-Item "$mainOSDrive\tiny11\sources\install.wim" > $null 2>&1
} else {
    Write-Host "Keeping install.wim (compress: $($buildProfile.Compress)); skipping ESD conversion."
}
Write-Host "The tiny11 image is now completed. Proceeding with the making of the ISO..."
Write-Host "Creating ISO image..."
$ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$hostarchitecture\Oscdimg"
$localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

if ([System.IO.Directory]::Exists($ADKDepTools)) {
    Write-Host "Will be using oscdimg.exe from system ADK."
    $OSCDIMG = "$ADKDepTools\oscdimg.exe"
} else {
    Write-Host "ADK folder not found. Will be using bundled oscdimg.exe."
    
    
    $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

    if (-not (Test-Path -Path $localOSCDIMGPath)) {
        Write-Host "Downloading oscdimg.exe..."
        Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath

        if (Test-Path $localOSCDIMGPath) {
            Write-Host "oscdimg.exe downloaded successfully."
        } else {
            Write-Error "Failed to download oscdimg.exe."
            exit 1
        }
    } else {
        Write-Host "oscdimg.exe already exists locally."
    }

    $OSCDIMG = $localOSCDIMGPath
}

& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"
$isoExit   = $LASTEXITCODE
$isoResult = "$PSScriptRoot\tiny11.iso"
$isoOk     = Test-Path $isoResult
$isoLen    = if ($isoOk) { (Get-Item $isoResult).Length } else { [long]0 }
if (-not (Test-IsoResult -ExitCode $isoExit -IsoExists $isoOk -IsoBytes $isoLen)) {
    throw "ISO creation failed (oscdimg exit $isoExit); no valid tiny11.iso was produced at $isoResult."
}

$elapsed  = (Get-Date) - $buildStart
$isoPath  = "$PSScriptRoot\tiny11.iso"
$isoBytes = if (Test-Path $isoPath) { (Get-Item $isoPath).Length } else { 0 }
Format-BuildSummary -Elapsed $elapsed -IsoBytes $isoBytes -IsoPath $isoPath -AppsRemoved $appsRemoved -AppsTotal $appsTotal -Warnings $script:buildWarnings |
    ForEach-Object { Write-Host $_ }
# Finishing up
Write-Host "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"
Write-Host "Performing Cleanup..."
Remove-Item -Path "$mainOSDrive\tiny11" -Recurse -Force > $null
Remove-Item -Path "$mainOSDrive\scratchdir" -Recurse -Force > $null

}
catch {
    $script:buildFailed = $true
    Write-Host ""
    Write-Host "ERROR: the image build failed and was aborted:"
    Write-Host "  $($_.Exception.Message)"
    Write-Host "Review the DISM log at $env:windir\Logs\DISM\dism.log for details."
}
finally {
    # Always release hives and tear down any half-finished mount, then close the
    # transcript - on both the success and failure paths.
    Remove-OfflineHives
    Dismount-OfflineImage -MountDir "$mainOSDrive\scratchdir"
    Stop-Transcript -ErrorAction SilentlyContinue
}

if ($script:buildFailed) { exit 1 } else { exit }
}
elseif ($continueChoice -eq 'n') {
    Write-Host "You chose not to continue. The script will now exit."
    exit
}
else {
    Write-Host "Invalid input. Please enter 'y' to continue or 'n' to exit."
}
