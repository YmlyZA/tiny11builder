# tiny11 builders - unattended install (OOBE skip + optional zero-touch) - design

- **Date:** 2026-07-01
- **Status:** Approved (pending written-spec review)
- **Scope target:** `tiny11Coremaker.ps1` AND `tiny11maker.ps1` (kept at parity)
- **Branch:** `harden/core-error-handling`

## Context

The committed `autounattend.xml` is minimal: it sets image index 1, a blank
product key, and `HideOnlineAccountScreens`. A real install still stops at setup
language, EULA, disk selection, region, keyboard, network, account name +
password, privacy, and time zone. Worse, the file is `processorArchitecture=
"amd64"` only, so on the user's arm64 builds it is silently ignored.

Goal: a Windows install from a tiny11 image goes **to the desktop with no OOBE
clicks** (Tier A, default), with an opt-in **zero-touch** mode that also wipes
disk 0 and installs unattended from ISO boot (Tier B, for VMs/test machines).

## New parameters (both scripts, at parity)

| Param | Default | Effect |
|---|---|---|
| `-User <string>` | `User` | local **Administrators** account created by the answer file |
| `-Password <string>` | `''` (blank) | account password; blank is allowed |
| `-TimeZone <string>` | `UTC` | Windows time-zone id set in OOBE |
| `-ZeroTouch` (switch) | off | **Tier B**: add a windowsPE `DiskConfiguration` that wipes disk 0 and installs, for a zero-click install (DESTRUCTIVE) |

AutoLogon is always enabled for the created account (so a blank password still
lands on the desktop). All four params are forwarded across the UAC self-relaunch
in both scripts, and are reported by `-DryRun`.

## Design

### Generator: `New-UnattendXml` (pure, both scripts, byte-identical)

Replaces the github download with an in-script generator (keeps the scripts
standalone, removes a network dependency, and is unit-testable):

```
New-UnattendXml -Architecture <amd64|arm64> -UserName <s> -Password <s>
                -TimeZone <s> -Language <s> [-ZeroTouch]  ->  [string] (full XML)
```

- **Arch-aware:** every `<component>` uses `processorArchitecture="$Architecture"`
  (the image's real arch, from `$architecture`) - this fixes the arm64 gap.
- **XML-safe:** `$UserName`/`$Password`/`$TimeZone` are escaped with
  `[System.Security.SecurityElement]::Escape(...)` before substitution.
- Returns a complete two-pass answer file:
  - **windowsPE** - `Microsoft-Windows-International-Core-WinPE` (SetupUILanguage +
    Input/System/UI/User locale = `$Language`); `Microsoft-Windows-Setup`
    (blank ProductKey, `AcceptEula=true`, `ImageInstall/OSImage` with
    `/IMAGE/INDEX = 1` and `WillShowUI=OnError`).
  - **oobeSystem** - `Microsoft-Windows-International-Core` (locale = `$Language`);
    `Microsoft-Windows-Shell-Setup` with `<OOBE>` hides (EULA, OEM registration,
    online-account, wireless), `NetworkLocation=Home`, `ProtectYourPC=3`;
    `<UserAccounts>` creating the local admin; `<AutoLogon>` (Enabled, high
    `LogonCount`, the account creds); `<TimeZone>$TimeZone`.

### Tier B (`-ZeroTouch`): disk wipe

When `-ZeroTouch` is set, the generator inserts into the windowsPE `Setup`
component a standard clean **UEFI/GPT** layout on **disk 0**:

- `<DiskConfiguration><Disk><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>` with
  partitions **EFI 260 MB (FAT32)** + **MSR 16 MB** + **Windows (Extend, NTFS,
  letter C)**; `WillShowUI=OnError`.
- `<InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>` in the
  OSImage.

When `-ZeroTouch` is NOT set (Tier A), neither block is emitted and the disk-
selection screen appears (the one deliberate confirmation).

### Script flow changes (both scripts)

- **Remove** the early `autounattend.xml` github download block (Core ~L416-418,
  maker ~L251-252).
- After `$architecture` and `$languageCode` are known (post-mount), generate the
  XML once: `$unattendXml = New-UnattendXml -Architecture $architecture -UserName
  $User -Password $Password -TimeZone $TimeZone -Language $langForUnattend
  -ZeroTouch:$ZeroTouch` (where `$langForUnattend = $languageCode` or `'en-US'`
  if not detected).
- Write `$unattendXml` (UTF-8) to BOTH:
  - `Sysprep\autounattend.xml` (Core L911 / maker L582 site) - oobeSystem, and
  - the ISO root `\tiny11\autounattend.xml` (maker already does this at L702;
    ADD it to Core) - so Windows Setup consumes windowsPE too.
- `-ZeroTouch` prints a clear one-time warning at build start: the produced image
  will ERASE disk 0 during setup.
- `-DryRun` reports: user, timezone, autologon, and Tier (A / B-ZeroTouch-wipes-disk0).

Because generation writes the XML directly to the image targets (no
`$PSScriptRoot\autounattend.xml` copy anymore):
- **Delete the committed `autounattend.xml`** at the repo root - nothing reads it
  now, and leaving it is a stale/confusing artifact.
- **Remove maker's post-build `autounattend.xml` cleanup block** (maker ~L756-802),
  which existed only to delete the downloaded `$PSScriptRoot` copy; with no such
  copy created, that block is dead (and would otherwise delete a tracked file).

The existing `BypassNRO` / `DisableOnline` reg tweaks and the WU-disable RunOnce
stay (harmless and complementary).

## Testing strategy

- **Static (every change):** parse-check, linter, test-core-helpers stay green;
  CI enforces on Windows PS 5.1.
- **Unit tests for `New-UnattendXml` (from BOTH scripts, parity):**
  - `[xml]$result` parses (well-formed) for Tier A and Tier B.
  - contains `processorArchitecture="arm64"` when `-Architecture arm64`.
  - contains the index (`<Value>1</Value>`), the escaped user name, the time zone,
    and `<AutoLogon>`.
  - **Tier A:** result does NOT contain `DiskConfiguration` / `WillWipeDisk`.
  - **Tier B:** result contains `WillWipeDisk` and the `InstallTo` disk 0 /
    partition 3.
  - XML-escaping: a user name like `a&b` appears escaped (`a&amp;b`), and the
    result still parses.
- **Runtime (Windows, user):** Tier A build -> install stops only at disk
  selection, then runs to desktop auto-logged-in; Tier B build in a VM -> ISO
  boot -> desktop, disk 0 wiped, no clicks.

## Safety / non-goals

- `-ZeroTouch` is destructive by design (whole disk 0). It is opt-in, warned at
  build time, and documented. No extra guard beyond the warning (the user's use
  case is always full-disk VM installs).
- Password is stored in the answer file as plaintext (acceptable for throwaway
  test images; documented). No encryption.
- No domain join, no multiple accounts, no post-install software - a single local
  admin and a clean desktop only.
- BIOS/MBR layouts are out of scope (Windows 11 is UEFI/GPT only).

## Sequencing

1. Core: `New-UnattendXml` + unit tests; add params + UAC-forward + dry-run +
   warning; wire generation + dual write (ISO root + Sysprep); remove download.
2. maker: `New-UnattendXml` (verbatim) + parity tests; same param/flow wiring.

All work continues on `harden/core-error-handling`.
