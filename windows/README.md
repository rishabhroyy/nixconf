# windows

Config for the `win11` guest. The same install also boots bare-metal.
Nix can't manage Windows, so this is the next best thing: the package list,
the shell profile, and the scripts live here instead of only on the disk.

## Packages

```powershell
winget configure -f windows\configuration.winget
```

winget is the only package manager (no Chocolatey or Scoop). Python versions
come from `uv python install <version>`.

Not on winget; install by hand:

- DaVinci Resolve
- Samsung Magician
- Macrium Reflect (backups to `\\10.0.0.3\data4\PC Backups`)
- ParsecVDisplay
- MATLAB
- Adobe apps (through Creative Cloud)
- HoYoPlay and its games, Infinity Nikki launcher

## Profile

Point `$PROFILE` (PowerShell 7) at the tracked profile:

```powershell
Set-Content $PROFILE '. "$HOME\Documents\GitHub\nixconf\windows\profile.ps1"'
```

It needs the `PSWriteColor` module for the banner (`Install-Module PSWriteColor`)
and oh-my-posh from the package list.

## Scripts

| Script | What it does | Runs from |
|---|---|---|
| `scripts/reboot-to-nixos.ps1` | One-time UEFI boot into NixOS, then reboots | By hand, as admin (see `DEPLOYMENT.md`) |
| `scripts/clean-vfio-residue.ps1` | Lists and removes stale QEMU/VirtIO PnP device records | By hand, as admin |
| `scripts/mount-data4.ps1` | Maps `D:` to data4 as SYSTEM so Macrium can back up to it | `\AutoMountD\AutoMountD` task at boot, as SYSTEM |
| `scripts/parsec-auto-display.ps1` | Adds a virtual monitor while a Parsec client is connected | By hand (long-running) |
