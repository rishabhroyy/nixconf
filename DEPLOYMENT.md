# Deployment Notes

This repository is a personal NixOS configuration, not a generic installer.
Before deploying, review the host-specific disk UUIDs, PCI addresses, GPU ROM,
SOPS keys, and encrypted secrets.

## Rebuild

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix --cores 14
```

Use a reboot after kernel, VFIO, hugepage, or firmware changes.

## Required Secrets

Secrets are managed with `sops-nix` from `hosts/rishabh-nix/secrets.yaml`.
The host must be able to decrypt them through either:

- `/root/.config/sops/age/keys.txt`
- the configured host SSH key fallback

The VM definition expects motherboard identity and Tailscale secrets to be
available at activation time.

## Windows VM

Useful host-side checks:

```bash
sudo systemctl status define-win11-vm.service
sudo systemctl status start-win11-vm.service
sudo virsh list --all
sudo verify-win11-vfio
```

Useful maintenance helpers:

```bash
sudo reset-win11-vm-definition
sudo reset-win11-secureboot-nvram
sudo enroll-win11-secureboot-keys
sudo free-win11-hugepages
sudo reboot-to-windows
```

`reset-win11-secureboot-nvram` replaces the VM's persistent OVMF variables, so
use it only when firmware variables are broken or intentionally being reset.

## One-Time Boot Switching

From NixOS, reboot once into the bare-metal Windows boot entry:

```bash
sudo reboot-to-windows
```

From Windows, run PowerShell as Administrator from this repo checkout:

```powershell
.\tools\windows-reboot-to-nixos.ps1
```

Both commands use UEFI BootNext/bootsequence, so the change is one-time rather
than a permanent boot order edit.

## Power Sync

Power sync is disabled during VM autostart and enabled automatically after the
VM stays running through its boot grace period.

```bash
sudo enable-power-sync
sudo disable-power-sync
```

When the marker is absent, stopping the Windows VM powers off the NixOS host.
When the marker exists, VM shutdown leaves the host running. The physical power
button path still asks the VM to shut down first, waits briefly, then powers off
the host.

To skip VM autostart for one boot, edit the boot entry and add either kernel
parameter:

```text
win11.no_autostart=1
```

or:

```text
no-win11-autostart
```

## Samba

The `data4` share is intended for local network access:

```text
\\rishabh-nix\data4
```

Create or refresh the Samba password with:

```bash
sudo smbpasswd -a rishabh
```

If local name resolution fails, use the host LAN IP instead of the NetBIOS name.

Immich is also exposed on the local network:

```text
http://rishabh-nix:2283
```

## Tailscale

The host advertises itself as an exit node. Approve the route in the Tailscale
admin console, then select this machine as the exit node from a client.
