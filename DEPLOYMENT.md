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
sudo virsh list --all
sudo verify-win11-vfio
```

Useful maintenance helpers:

```bash
sudo reset-win11-vm-definition
sudo reset-win11-secureboot-nvram
sudo enroll-win11-secureboot-keys
sudo free-win11-hugepages
```

`reset-win11-secureboot-nvram` replaces the VM's persistent OVMF variables, so
use it only when firmware variables are broken or intentionally being reset.

## Power Sync

Power sync is controlled by `/var/lib/libvirt/hooks/no-power-sync`.

```bash
sudo enable-power-sync
sudo disable-power-sync
```

When the marker is absent, stopping the Windows VM powers off the NixOS host.
When the marker exists, VM shutdown leaves the host running. The physical power
button path still asks the VM to shut down first, waits briefly, then powers off
the host.

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
