# Deployment Notes

This repository is a personal NixOS configuration, not a generic installer.
Before deploying, review the host-specific disk UUIDs, PCI addresses, GPU ROM,
SOPS keys, and encrypted secrets.

## Rebuild

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix --cores 14
```

This applies changes in place. Automatic upgrades use the same behavior and
never reboot the host. Kernel, initrd, bootloader, VFIO device-binding, and
firmware changes require a later reboot before they take effect. A switch
never restarts `win11.service`, so it never shuts Windows down.

## Required Secrets

Secrets are managed with `sops-nix` from `hosts/rishabh-nix/secrets.yaml`.
The host must be able to decrypt them through either:

- `/root/.config/sops/age/keys.txt`
- the configured host SSH key fallback

The VM definition expects motherboard identity and Tailscale secrets to be
available at activation time.

## Homelab Mode and the Windows VM

The machine boots into homelab mode: the host owns all 16 CPUs, all RAM, the
RX 6700 XT, keyboard and mouse, and the monitor shows the dashboard
(`hosts/rishabh-nix/homelab/`). Windows only runs on request.

```bash
win on          # or "Start Windows" on the dashboard
win off         # shuts Windows down via its OpenSSH server
win status
win baremetal   # reboot once into bare-metal Windows
win key         # the host's public key for Windows (see below)
```

The dashboard is at `http://rishabh-nix` and `https://rishabh-nix.<tailnet>.ts.net`
on the tailnet only (never the LAN: it can power the machine off). Preview its
design anywhere with fake data:

```bash
python3 hosts/rishabh-nix/homelab/server.py --demo --port 8080
```

`win11.service` (homelab.nix) owns the handoff. Starting it stops
`homelab.target` (the kiosk and any GPU workloads), checks nothing still holds
the GPU, allocates 16 GiB of 2 MiB hugepages, moves the host onto CPUs
0-3/8-11, and starts the VM; libvirt detaches the GPU to `vfio-pci`
(`managed='yes'`). Any failure undoes all of it and shows the reason on the
dashboard. Stopping it asks Windows to shut down over SSH (the ACPI power
button only as a fallback), waits up to 4 minutes, never forces it, then gives
everything back. Shutting Windows down from inside does the same through
`win11-lifecycle-monitor.service`. A reboot from inside stays in Windows.

One-time setup for `win off`: add the output of `win key` to
`C:\ProgramData\ssh\administrators_authorized_keys` in Windows (the account
and address are `winSsh` in homelab.nix).

The physical power button, `Restart`, and `Power off` all shut Windows down
cleanly first: stopping `win11.service` is part of every host shutdown.

A service that needs the GPU while Windows is off joins `homelab.target`; the
header of `homelab.nix` has the three lines.

The boot NVMe and SATA controller still bind to `vfio-pci` in initrd. No
libvirt hooks are used: the handoff runs from a systemd unit, so it can't
deadlock libvirtd.

Useful checks:

```bash
sudo verify-win11-vfio
journalctl -u win11 -u win11-lifecycle-monitor
```

Maintenance helpers:

```bash
sudo reset-win11-vm-definition
sudo reset-win11-secureboot-nvram
sudo enroll-win11-secureboot-keys
```

`reset-win11-secureboot-nvram` replaces the VM's persistent OVMF variables, so
use it only when firmware variables are broken or intentionally being reset.

Do not use `virsh reset` as a recovery action; inspect `sudo verify-win11-vfio`
and the service journal instead.

From Windows, `.\windows\scripts\reboot-to-nixos.ps1` (PowerShell as
Administrator) arms a one-time UEFI boot back into NixOS.

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
