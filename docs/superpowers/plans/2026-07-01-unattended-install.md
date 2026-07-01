# Unattended Install (OOBE skip + optional zero-touch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a complete, arch-aware unattended-install answer file so a tiny11 image installs to the desktop with no OOBE clicks (default), plus an opt-in `-ZeroTouch` mode that wipes disk 0 for a zero-click install.

**Architecture:** A pure `New-UnattendXml` generator (unit-tested, byte-identical in both scripts) replaces the github download. The scripts add `-User`/`-Password`/`-TimeZone`/`-ZeroTouch` params, generate the XML after the image architecture is known, and write it (UTF-8, no BOM) to both the ISO root and `Sysprep\`.

**Tech Stack:** Windows PowerShell 5.1, Windows Setup unattend schema, DISM.

## Global Constraints

- **Target runtime Windows PowerShell 5.1** — no PS7-only syntax (no ternary `? :`, no `??`). Inline `$(if(){}else{})`, `[System.Security.SecurityElement]::Escape`, `[System.IO.File]::WriteAllText`, `System.Text.UTF8Encoding` are all valid on 5.1.
- **ASCII only** in the scripts (the generated XML is ASCII too).
- **Parity:** `New-UnattendXml` must be BYTE-IDENTICAL in both scripts. The params, UAC forwarding, generation, and dual-write behave identically (allowing Core `Write-Host` vs maker `Write-Output`).
- **Variable names are CASE-INSENSITIVE** — do not collide with params; the new params are `$User`, `$Password`, `$TimeZone`, `$ZeroTouch`.
- **`-ZeroTouch` is destructive** (wipes disk 0). It must print a build-time warning and be reported by `-DryRun`.
- Write the answer file as **UTF-8 without BOM** (Windows Setup can choke on a BOM).

---

### Task 1: Core — `New-UnattendXml` + tests, params, generation, dual-write

**Files:** Modify `tiny11Coremaker.ps1`, `scripts/test-core-helpers.ps1`.

**Interfaces:**
- Produces: `New-UnattendXml -Architecture <amd64|arm64> -UserName <s> -Password <s> -TimeZone <s> -Language <s> [-ZeroTouch]` -> `[string]` (full answer-file XML). Consumed by the generation wiring and Task 2.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-core-helpers.ps1`, after the last `Test-IsoResult` Check line and before the `== maker parity` section, insert:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'New-UnattendXml' is not recognized".

- [ ] **Step 3: Add the generator**

In `tiny11Coremaker.ps1`, immediately after the closing `}` of `Test-IsoResult`, insert:

```powershell
function New-UnattendXml {
    # Pure: builds the complete Windows Setup answer file (windowsPE + oobeSystem).
    # Tier A (default) skips OOBE to an auto-logged-in local admin; -ZeroTouch adds
    # a disk-0 wipe (clean UEFI layout) for a zero-click install. Arch-aware.
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (prior 96 + 13 new = 109).

- [ ] **Step 5: Add the parameters**

In the `param( ... )` block, after `[switch]$Fast`, add (note the comma after `$Fast`):

```powershell
    [switch]$Fast,
    [string]$User = 'User',
    [string]$Password = '',
    [string]$TimeZone = 'UTC',
    [switch]$ZeroTouch
```

- [ ] **Step 6: Forward the new params across UAC self-relaunch**

After the `if ($Fast) { $argList += " -Fast" }` line, add:

```powershell
    $argList += " -User `"$User`""
    if ($Password) { $argList += " -Password `"$Password`"" }
    $argList += " -TimeZone `"$TimeZone`""
    if ($ZeroTouch) { $argList += " -ZeroTouch" }
```

- [ ] **Step 7: Remove the github download (keep the sources-dir creation)**

Replace the autounattend download block (the comment lines + the `if (-not (Test-Path ...autounattend.xml)) { ... Invoke-RestMethod ... }` inside the `if (-not $DryRun) { ... }` guard) so only the directory creation remains:

```powershell
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path "$mainOSDrive\tiny11\sources" > $null
}
```

- [ ] **Step 8: Warn on -ZeroTouch at build start**

Immediately after the `$buildProfile = Resolve-BuildProfile ...` line, add:

```powershell
if ($ZeroTouch) { Write-Warning "-ZeroTouch: the produced image will ERASE DISK 0 automatically during Windows Setup. Use only on VMs / dedicated test machines." }
```

- [ ] **Step 9: Generate the answer file and dual-write it**

Replace the Sysprep copy line:
```powershell
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null
```
with:
```powershell
$langForUnattend = if ($languageCode) { $languageCode } else { 'en-US' }
$unattendXml = New-UnattendXml -Architecture $architecture -UserName $User -Password $Password -TimeZone $TimeZone -Language $langForUnattend -ZeroTouch:$ZeroTouch
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml", $unattendXml, $utf8NoBom)
[System.IO.File]::WriteAllText("$ScratchDisk\tiny11\autounattend.xml", $unattendXml, $utf8NoBom)
```
(`$architecture` and `$languageCode` are set earlier from the mounted image; `$ScratchDisk` equals `$mainOSDrive` in Core.)

- [ ] **Step 10: Report the unattend settings in -DryRun**

In the `if ($DryRun)` block, after the `Image index (-Index)` line, add:

```powershell
    Write-Host "  Unattended user      : $User (autologon)"
    Write-Host "  Time zone            : $TimeZone"
    Write-Host "  Install mode         : $(if ($ZeroTouch) { 'ZeroTouch (ERASES disk 0)' } else { 'OOBE-skip (keeps disk selection)' })"
```

- [ ] **Step 11: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11Coremaker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for Core (skip locally if PSScriptAnalyzer absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`

Note: the body isn't runnable on macOS; the generator is unit-tested and the wiring is parse/lint-gated + CI + real-Windows validated.

- [ ] **Step 12: Commit**

```bash
git add tiny11Coremaker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(core): generate arch-aware unattended-install answer file (OOBE skip + -ZeroTouch)"
```

---

### Task 2: maker — `New-UnattendXml` (parity), params, generation, dual-write, cleanup removal, delete committed autounattend.xml

**Files:** Modify `tiny11maker.ps1`, `scripts/test-core-helpers.ps1`; delete `autounattend.xml`.

- [ ] **Step 1: Write the failing parity test**

In `scripts/test-core-helpers.ps1`, extend the maker-parity extraction filter to also include `'New-UnattendXml'`:

```powershell
    Where-Object { $_.Name -in 'Resolve-BuildProfile', 'Test-RobocopySucceeded', 'Get-AvailableImageIndex', 'Test-ImageIndexAvailable', 'Get-RequiredScratchBytes', 'Test-SufficientScratch', 'Resolve-OscdimgSource', 'Format-BuildSummary', 'Test-IsoResult', 'New-UnattendXml' } |
```

Then add, after the last existing maker-parity Check line:

```powershell
$mUaA = maker_New-UnattendXml -Architecture 'arm64' -UserName 'User' -Password '' -TimeZone 'UTC' -Language 'en-US'
Check 'maker tierA arch arm64' ($mUaA -match 'processorArchitecture="arm64"')
Check 'maker tierA no wipe'     (-not ($mUaA -match 'WillWipeDisk'))
$mUaB = maker_New-UnattendXml -Architecture 'amd64' -UserName 'User' -Password '' -TimeZone 'UTC' -Language 'en-US' -ZeroTouch
Check 'maker tierB disk wipe'   ($mUaB -match '<WillWipeDisk>true</WillWipeDisk>')
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: FAIL — "The term 'maker_New-UnattendXml' is not recognized".

- [ ] **Step 3: Add the generator (verbatim from Core)**

Open `tiny11Coremaker.ps1`, copy the ENTIRE `New-UnattendXml` function verbatim, and paste it into `tiny11maker.ps1` immediately after the closing `}` of `Test-IsoResult`. Byte-identical.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1`
Expected: PASS — `RESULT: <n> passed, 0 failed` (grows by 3 maker parity checks).

- [ ] **Step 5: Add the parameters**

In maker's `param( ... )` block, after `[switch]$Fast`, add the same four params (note the comma after `$Fast`):

```powershell
    [switch]$Fast,
    [string]$User = 'User',
    [string]$Password = '',
    [string]$TimeZone = 'UTC',
    [switch]$ZeroTouch
```

- [ ] **Step 6: Forward the new params across UAC self-relaunch**

After the `if ($Fast) { $argList += " -Fast" }` line, add:

```powershell
    $argList += " -User `"$User`""
    if ($Password) { $argList += " -Password `"$Password`"" }
    $argList += " -TimeZone `"$TimeZone`""
    if ($ZeroTouch) { $argList += " -ZeroTouch" }
```

- [ ] **Step 7: Remove the github download**

Delete maker's autounattend download block (the `if (-not (Test-Path ...autounattend.xml)) { Invoke-RestMethod ... }`). If it is wrapped in a `-not $DryRun` guard whose only body was the download, remove the now-empty guard too.

- [ ] **Step 8: Warn on -ZeroTouch at build start**

Immediately after maker's `$buildProfile = Resolve-BuildProfile ...` line, add:

```powershell
if ($ZeroTouch) { Write-Warning "-ZeroTouch: the produced image will ERASE DISK 0 automatically during Windows Setup. Use only on VMs / dedicated test machines." }
```

- [ ] **Step 9: Generate + write to Sysprep (first write site)**

Replace maker's Sysprep copy line:
```powershell
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null
```
with:
```powershell
$langForUnattend = if ($languageCode) { $languageCode } else { 'en-US' }
$unattendXml = New-UnattendXml -Architecture $architecture -UserName $User -Password $Password -TimeZone $TimeZone -Language $langForUnattend -ZeroTouch:$ZeroTouch
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml", $unattendXml, $utf8NoBom)
```

- [ ] **Step 10: Write to the ISO root (second write site)**

Replace maker's ISO-root copy line:
```powershell
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$ScratchDisk\tiny11\autounattend.xml" -Force | Out-Null
```
with:
```powershell
[System.IO.File]::WriteAllText("$ScratchDisk\tiny11\autounattend.xml", $unattendXml, $utf8NoBom)
```
(`$unattendXml` and `$utf8NoBom` from Step 9 remain in scope.)

- [ ] **Step 11: Remove the dead post-build autounattend cleanup block**

Delete maker's cleanup section that removes `$PSScriptRoot\autounattend.xml` (starts at `Write-Output "Removing autounattend.xml..."`, through the `if (Test-Path ... autounattend.xml) { ... } else { "No action needed." }` block). Generation no longer creates a `$PSScriptRoot` copy, so this is dead and would otherwise delete a tracked file. Remove the whole block (including its Write-Output header).

- [ ] **Step 12: Report the unattend settings in -DryRun**

In maker's `if ($DryRun)` block, after the `Image index (-Index)` line, add:

```powershell
    Write-Output "  Unattended user       : $User (autologon)"
    Write-Output "  Time zone             : $TimeZone"
    Write-Output "  Install mode          : $(if ($ZeroTouch) { 'ZeroTouch (ERASES disk 0)' } else { 'OOBE-skip (keeps disk selection)' })"
```

- [ ] **Step 13: Delete the now-unused committed answer file**

Neither script references `$PSScriptRoot\autounattend.xml` anymore. Run:
```bash
git rm autounattend.xml
```

- [ ] **Step 14: Verify static gates**

Run: `pwsh -NoProfile -File scripts/parse-check.ps1` → `[OK]   tiny11maker.ps1`
Run: `pwsh -NoProfile -File scripts/linter.ps1` → `0 high-signal finding(s)` for maker (skip locally if module absent)
Run: `pwsh -NoProfile -File scripts/test-core-helpers.ps1` → `RESULT: <n> passed, 0 failed`
Confirm no dangling references: `grep -rn 'PSScriptRoot.autounattend' tiny11maker.ps1 tiny11Coremaker.ps1` → no matches.

- [ ] **Step 15: Commit**

```bash
git add tiny11maker.ps1 scripts/test-core-helpers.ps1
git commit -m "feat(maker): generate unattended-install answer file (parity); drop committed autounattend.xml"
```

---

### Task 3: README — document the unattended-install flags

**Files:** Modify `README.md`.

- [ ] **Step 1: Add the documentation**

Under the "Speed & testing flags" / "Pre-flight validation" area of `README.md`, append:

```markdown
### Unattended install

Both builders now bake a complete, architecture-aware answer file into the image,
so Windows installs to the desktop with no OOBE clicks:

- **Default (OOBE skip):** language, EULA, region, keyboard, network, account
  creation, privacy, and time zone are all handled automatically. A local
  **administrator** account is created and **auto-logged in**; only the disk-
  selection screen remains. Override the defaults with:
  - `-User <name>`   (default `User`)
  - `-Password <pwd>` (default blank; AutoLogon is always on)
  - `-TimeZone <id>`  (default `UTC`)
- **`-ZeroTouch` (zero-click, DESTRUCTIVE):** also wipes **disk 0** and lays down
  a clean UEFI layout, so booting the ISO installs straight to the desktop with
  no interaction. Intended for VMs / dedicated test machines only — it erases
  disk 0 without prompting. The build prints a warning when this is set.

    .\tiny11Coremaker.ps1 -ISO E -Index 1 -Yes -ZeroTouch

The password is stored in the answer file as plaintext (fine for throwaway test
images). `-DryRun` reports the user, time zone, and install mode.
```

- [ ] **Step 2: Verify**

Run: `grep -c "Unattended install" README.md` → `1`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document unattended-install flags (OOBE skip + -ZeroTouch)"
```

---

## Notes for the executor

- Base for the increment: current `harden/core-error-handling` HEAD.
- After all tasks: final whole-branch review, then finishing-a-development-branch (push/PR/merge to fork main; CI gates the PR). `YmlyZA` is the persistent active account (do NOT restore thunderbird-ns); it has the `workflow` scope.
- Real-machine close-out (user, Windows): a default build installs to an auto-logged-in desktop with only the disk-pick; a `-ZeroTouch` build in a VM goes ISO-boot -> desktop with disk 0 wiped and no clicks. Confirm on both amd64 and arm64 (the arch fix).
