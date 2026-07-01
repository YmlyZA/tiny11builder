# tiny11builder

[![CI](https://github.com/YmlyZA/tiny11builder/actions/workflows/ci.yml/badge.svg)](https://github.com/YmlyZA/tiny11builder/actions/workflows/ci.yml)

*Scripts to build a trimmed-down Windows 11 image - now in **PowerShell**!*

## Introduction :
Tiny11 builder, now completely overhauled. <br> After more than a year (for which I am so sorry) of no updates, tiny11 builder is now a much more complete and flexible solution - one script fits all. Also, it is a steppingstone for an even more fleshed-out solution.

You can now use it on ANY Windows 11 release (not just a specific build), as well as ANY language or architecture.
This is made possible thanks to the much-improved scripting capabilities of PowerShell, compared to the older Batch release.

This is a script created to automate the build of a streamlined Windows 11 image, similar to tiny10.
The script has also been updated to use DISM's recovery compression, resulting in a much smaller final ISO size, and no utilities from external sources. The only other executable included is **oscdimg.exe**, which is provided in the Windows ADK and it is used to create bootable ISO images. 
Also included is an unattended answer file, which is used to bypass the Microsoft Account on OOBE and to deploy the image with the `/compact` flag.
It's open-source, **so feel free to add or remove anything you want!** Feedback is also much appreciated.

Also, for the very first time, **introducing tiny11 core builder**! A more powerful script, designed for a quick and dirty development testbed. Just the bare minimum, none of the fluff. 
This script generates a significantly reduced Windows 11 image. However, **it's not suitable for regular use due to its lack of serviceability - you can't add languages, updates, or features post-creation**. tiny11 Core is not a full Windows 11 substitute but a rapid testing or development tool, potentially useful for VM environments.

---

## ⚠️ Script versions:
- **tiny11maker.ps1** : The regular script, which removes a lot of bloat but keeps the system serviceable. You can add languages, updates, and features post-creation. This is the recommended script for regular use.
- ⚠️ **tiny11coremaker.ps1** : The core script, which removes even more bloat but also removes the ability to service the image. You cannot add languages, updates, or features post-creation. This is recommended for quick testing or development use.

## Instructions:
1. Download Windows 11 from the [Microsoft website](https://www.microsoft.com/software-download/windows11) or [Rufus](https://github.com/pbatard/rufus)
2. Mount the downloaded ISO image using Windows Explorer.
3. Open **PowerShell 5.1** as Administrator. 
5. Change the script execution policy :
```powershell
Set-ExecutionPolicy Bypass -Scope Process
```
> Using `-Scope Process` you keep your original policy intact as this change only lasts for the current PowerShell session. 

6. Start the script :
```powershell
C:/path/to/your/tiny11/script.ps1 -ISO <letter> -SCRATCH <letter>
``` 
> You can see of the script by running the `get-help` command.

6. Select the drive letter where the image is mounted (only the letter, no colon (:))
7. Select the SKU that you want the image to be based.
8. Sit back and relax :)
9. When the image is completed, you will see it in the folder where the script was extracted, with the name tiny11.iso

---

## What is removed:
<table>
  <tbody>
    <tr>
      <th>Tiny11maker</th>
      <th>Tiny11coremaker</th>
    </tr>
    <tr>
      <td>
        <ul>
          <li>Clipchamp</li>
          <li>News</li>
          <li>Weather</li>
          <li>Xbox</li>
          <li>GetHelp</li>
          <li>GetStarted</li>
          <li>Office Hub</li>
          <li>Solitaire</li>
          <li>PeopleApp</li>
          <li>PowerAutomate</li>
          <li>ToDo</li>
          <li>Alarms</li>
          <li>Mail and Calendar</li>
          <li>Feedback Hub</li>
          <li>Maps</li>
          <li>Sound Recorder</li>
          <li>Your Phone</li>
          <li>Media Player</li>
          <li>QuickAssist</li>
          <li>Internet Explorer</li>
          <li>Tablet PC Math</li>
          <li>Edge</li>
          <li>OneDrive</li>
        </ul>
      </td>
      <td>
        <ul>
          <li>all from regular tiny +</li>
          <li>Windows Component Store (WinSxS)</li>
          <li>Windows Defender (only disabled, can be enabled back if needed)</li>
          <li>Windows Update (wouldn't work without WinSxS, enabling it would put the system in a state of failure)</li>
          <li>WinRE</li>
        </ul>
      </td>
    </tr>
  </tbody>
</table>

Keep in mind that **you cannot add back features in tiny11 core**! <br>
You will be asked during image creation if you want to enable .net 3.5 support!

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

---

---

## Speed & testing flags

Both `tiny11maker.ps1` and `tiny11Coremaker.ps1` accept:

- **`-DryRun`** — validate inputs and print the build plan (what will be removed/kept, the
  ordered steps) in seconds, without copying or mounting anything. Use it to check
  `-ISO`/`-SCRATCH`/`-Index` and (Core) `-Keep`/`-Remove` before a real build.
- **`-Compress recovery|fast|none`** — image compression. `recovery` (default) is smallest and
  slowest (current behavior); `fast` and `none` trade size for a much faster build.
- **`-Fast`** — preset: `fast` compression + skip component cleanup (`/ResetBase`). Keeps the full
  image edits (Core still rebuilds WinSxS and runs the integrity gate), so a `-Fast` build is a
  genuine, bootable image produced in a fraction of the time. An explicit `-Compress` overrides it.

Tip: builds are I/O-bound. Point **`-SCRATCH`** at an SSD or a manually-created RAMDisk to speed
the copy/delete/mount steps. (No RAMDisk is created for you — Windows has no built-in one.)

Example fast unattended Core build, keeping Paint:

```powershell
.\tiny11Coremaker.ps1 -ISO E -SCRATCH D -Index 1 -Fast -Keep Paint -Yes
```

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

## Known issues:
- Although Edge is removed, there are some remnants in the Settings, but the app in itself is deleted. 
- You might have to update Winget before being able to install any apps, using Microsoft Store.
- Outlook and Dev Home might reappear after some time. This is an ongoing battle, though the latest script update tries to prevent this more aggressively.
- If you are using this script on arm64, you might see a glimpse of an error while running the script. This is caused by the fact that the arm64 image doesn't have OneDriveSetup.exe included in the System32 folder.

---

## Features to be implemented:
- ~~disabling telemetry~~ (Implemented in the 04-29-24 release!)
- ~~more ad suppression~~ (Partially implemented in the 09-06-25 release!)
- improved language and arch detection
- more flexibility in what to keep and what to delete
- maybe a GUI???

And that's pretty much it for now!
## ❤️ Support the Project

If this project has helped you, please consider showing your support! A small donation helps me dedicate more time to projects like this.
Thank you!

**[Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev)**
Thanks for trying it and let me know how you like it!
