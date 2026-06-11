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
sudo systemctl status win11-power-sync-monitor.service
sudo virsh list --all
sudo verify-win11-vfio
```

`verify-win11-vfio` includes the current startup journal, QEMU log tail,
boot-critical PCI reset methods and link state, hugepage availability, and
whether any legacy synchronous QEMU hook remains.

The `start-win11-vm.service` unit owns VM autostart. It disables libvirt's
independent autostart path, waits for the generated VM definition, and requires
the complete passthrough stack, responsive PCI config space, physical TPM, VFIO
bindings, and all 16 boot-reserved 1 GiB hugepages to remain ready for five
consecutive checks.
It then starts Windows normally exactly once. It never pauses, resets, reboots,
destroys, or retries the guest automatically.

The passed-through boot NVMe is kept in PCI D0 from host PCI enumeration onward,
with host runtime PM and D3cold disabled for the NixOS boot. Linux's NVMe driver
initializes the controller, enumerates its namespaces, and completes repeated
read-only direct-I/O probes first. Startup refuses to continue if any namespace
cannot be read, is mounted, used as swap, or held by another host device.
Libvirt then detaches that proven-unused controller into VFIO immediately before
QEMU starts. Other devices bound to `vfio-pci` during initrd remain unmanaged by
libvirt.

The VM's hugepages are reserved once by the kernel command line and remain
reserved for the host boot. No libvirt hook compacts memory, drops caches,
allocates pages, or frees pages during VM lifecycle events. This deliberately
trades reclaiming 16 GiB after VM shutdown for deterministic subsequent starts.

Routine boot never rewrites the VM's persistent OVMF NVRAM. Secure Boot key
enrollment is an explicit maintenance action through
`sudo enroll-win11-secureboot-keys`, not part of domain definition or autostart.

The VM keeps an 8-core / 16-thread topology. Four physical cores remain shared
with NixOS, while four are isolated for latency-sensitive guest work. Only the
vCPU threads pinned to isolated cores use low-priority real-time round-robin
scheduling; QEMU housekeeping and host workloads keep normal scheduling.
Windows' first four guest cores map to the isolated cores so foreground work,
device interrupts, and DPCs are more likely to avoid host scheduling jitter.
KVM poll-control briefly waits for guest wakeups to avoid some scheduler
round trips, and `rcu_nocb_poll` prevents offloaded RCU callback processing
from repeatedly waking the isolated guest CPUs. The host NMI watchdog remains
enabled for hard-lockup diagnosis.

The host-only `win11-power-sync-monitor.service` watches libvirt lifecycle
and reboot events. It powers off NixOS only after libvirt reports the specific
normal shutdown reason `Stopped Shutdown` and the domain remains off after a
short guard period. Reboots, crashes, forced stops, failed boots, and stuck
firmware leave NixOS running. Existing NixOS shutdown or reboot transactions
are never replaced by a VM-triggered poweroff.

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

After the previous forced resets, allow Windows Automatic Repair to finish or
boot Windows bare-metal once before returning to VFIO. Do not use `virsh reset`
as a recovery action; inspect `sudo verify-win11-vfio` and the service journal
instead.

## One-Time Boot Switching

From NixOS, arm the next host startup for the bare-metal Windows boot entry:

```bash
sudo reboot-to-windows
```

From Windows, run PowerShell as Administrator from this repo checkout:

```powershell
.\tools\windows-reboot-to-nixos.ps1
```

Both commands use UEFI BootNext/bootsequence, so the change is one-time rather
than a permanent boot order edit. `reboot-to-windows` records the request but
does not stop the VM, write BootNext early, or reboot the host. Shut down
Windows normally when ready. After that clean shutdown, the power-sync monitor
writes BootNext immediately before powering off NixOS, so an unrelated earlier
host reboot cannot consume the request. The command warns if power sync is
disabled or unavailable.

## Power Sync

Power sync is entirely host-side. A clean Windows shutdown powers off NixOS;
other VM stop reasons leave NixOS running.

```bash
sudo enable-power-sync
sudo disable-power-sync
```

`disable-power-sync` leaves the lifecycle monitor running but prevents it from
powering off NixOS. It remains effective across service restarts and
configuration switches until `enable-power-sync` is run or the NixOS host
boots again.

The physical power button requests a clean guest shutdown and lets the same
lifecycle monitor power off the host. It never cuts host power merely because
a timeout expired.

To skip VM autostart for one boot, edit the boot entry and add either:

```text
win11.no_autostart=1
```

or:

```text
no-win11-autostart
```

To disable power sync for one boot, edit the boot entry and add either kernel
parameter:

```text
win11.no_power_sync=1
```

or:

```text
no-win11-power-sync
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
