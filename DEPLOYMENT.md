# Deployment Notes

This repository is a personal NixOS configuration, not a generic installer.
Before deploying, review the host-specific disk UUIDs, PCI addresses, GPU ROM,
SOPS keys, and encrypted secrets.

## Rebuild

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix --cores 14
```

This applies changes in place. Automatic upgrades use the same behavior and
never reboot the host. Kernel, initrd, bootloader, VFIO device-binding,
hugepage-reservation, and firmware changes require a later reboot before they
take effect.

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
independent autostart path, waits for the generated VM definition, then starts
Windows normally exactly once. It never pauses, probes, detaches, resets,
reboots, destroys, or retries the guest automatically.

The dedicated GPU, boot NVMe, SATA controller, and NIC bind directly to
`vfio-pci` during initrd and remain there for the NixOS boot. Their domain XML
uses `managed='no'`, so libvirt does not detach or reattach host drivers. Only
the two shared-ID USB controllers use libvirt-managed handoff.

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

## Hermes Agent MicroVM

A `microvm.nix` guest (`hermes`) runs Nous Research's Hermes Agent
(Nix/NixOS support is Tier 2 / best-effort upstream), with 4 vCPU / 8GB RAM
(carved out of the Windows VM's allocation, see "RAM budget" below) and a
disk image capped at 150GB (`/var/lib/microvms/hermes/var.img`, on the
host's root disk — the host has one ext4 filesystem, no separate `/var`
partition). That's a ceiling, not a reservation: the image is sparse and
grows/shrinks with actual usage (see "Disk sizing" below). It joins your
tailnet independently of the host and is reachable only over Tailscale, not
the LAN.

VM shape (CPU/RAM/disk/networking/store) is declarative, in
`hosts/rishabh-nix/microvms/hermes.nix`. Hermes *itself* is deliberately
**not** — it's installed as a plain package (`flake.nix`), not through
`services.hermes-agent`. That NixOS module ties the CLI to a shared
`HERMES_HOME` and unconditionally drops a `.managed` marker into it on every
activation, which makes `hermes setup` / `hermes config set` / `hermes
config edit` refuse to run. Going unmanaged trades that seamlessness for
robustness: no service half-configured and crash-looping while waiting on a
key, no config format inferred ahead of the Tier-2 docs actually confirming
it — you just run the same `hermes setup` anyone else would.

### 1. Start it up

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix
```

Builds the guest and autostarts it (`microvm.autostart = [ "hermes" ]`).

Windows' RAM cut (16GB -> 12GB, freeing 4GB for Hermes) needs a **host
reboot** too — see "RAM budget" below.

### 2. Verify, connect, and configure

```bash
systemctl status microvm@hermes      # on the host: is the guest up?
```

Find the guest's tailnet name/IP in the Tailscale admin console (hostname
`hermes-agent`), then:

```bash
ssh rishabh@hermes-agent             # over Tailscale, MagicDNS
hermes setup                         # first-time provider/API key/model config
hermes --tui
```

`hermes` is on PATH for every user in the guest (package installed via
`environment.systemPackages` in `flake.nix`). With no `HERMES_HOME`
override, it defaults to `~/.hermes` — i.e. `/home/rishabh/.hermes` — where
`hermes setup` writes your provider, model, and API key. That's already
persistent, see "Persistence inside the guest" below.

Tailscale auth reuses the host's existing `tailscale_auth_key` (synced in by
`hermes-secrets-sync` in `configuration.nix`, same mechanism as before) — no
separate key needed for that part.

### Disk sizing

`size = 153600` in `hermes.nix` is a 150GB ceiling, not an upfront
allocation. microvm.nix creates `var.img` with `truncate` (a sparse file —
`ls -l` shows 150G, `du` shows actual bytes written), and QEMU mounts it with
`discard=unmap`, so space frees back to the host when the guest deletes
files, as long as TRIM runs — `services.fstrim.enable = true` in `hermes.nix`
does that periodically. Check real usage on the host with
`du -h /var/lib/microvms/hermes/var.img`, or from inside the guest with `df
-h /var`.

### Persistence inside the guest

The guest's `/` is rebuilt from the Nix store on every boot — only `/var`
persists. That now covers:

- **`/home`** — bind-mounted onto `/var/home` in `hermes.nix`. Hermes is
  unmanaged (see above), so its state — `~/.hermes` (config, API key,
  sessions, memory) — lives under `/home/rishabh` and survives reboots for
  free, along with anything else you drop there by hand (dotfiles, cloned
  repos, ad-hoc scripts).
- the SSH host key (pinned to `/var/lib/ssh`, otherwise SSH trust resets
  every boot)

Anything written outside `/var` (excluding `/nix/store`, which now has its
own persistent writable overlay — see below) is still wiped every boot —
add packages to `environment.systemPackages` in `hermes.nix` for anything
that needs to survive that way instead.

### RAM budget

Total host RAM is 32GB. Windows was a static, unballooned 16GB
(`win11-template.xml`, `hugepages=16` in `vfio.nix`) — both trimmed to 12GB
to give Hermes room. **Windows' hugepage reservation is set at kernel
boot**, so the `hugepages=12` change in `vfio.nix` needs a full host reboot
(not just `nixos-rebuild switch`) to actually free the 4GB back to the pool
— until you reboot, the kernel still has 16GB of hugepages locked down even
though the VM XML only asks for 12.
