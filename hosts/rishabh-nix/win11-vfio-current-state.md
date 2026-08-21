# Windows VM Baseline

Current stable profile for the `win11` libvirt domain.

## Active

- Patched QEMU package: `pkgs.qemu_win11`.
- Patched OVMF package: `pkgs.ovmf_win11` with Secure Boot and TPM support.
- QEMU vmcall/hypercall quirk fix.
- QEMU/OVMF identity tweaks for the VM's firmware and virtual bus devices.
- Physical TPM passthrough through `/dev/tpmrm0`.
- Host DMI and encrypted secrets used for SMBIOS fields.
- One small synthetic ACPI thermal SSDT.
- 16 GiB RAM backed by 1 GiB hugepages.
- 16 vCPUs with host-passthrough CPU, cache passthrough, `topoext`, `invtsc`,
  and an 8-core / 16-thread topology.
- Physical cores 4-7 isolated for the VM; physical cores 0-3 shared with NixOS.
- Windows guest cores 0-3 map to isolated physical cores 4-7 so foreground
  work, interrupts, and DPCs preferentially land away from host activity.
- The eight vCPU threads on those isolated cores use low-priority real-time
  round-robin scheduling; guest cores 4-7 and host work retain normal
  scheduling.
- KVM poll-control reduces scheduler round trips for short guest wakeups.
- `kvm.halt_poll_ns=500000` and the C2 idle state disabled on cores 4-7/12-15
  (`disable-win11-core-cstates.service`) to keep guest wakeups cheap.
- Isolated cores 4-7/12-15 pinned to their max P-state
  (`pin-win11-core-max-freq.service`, `scaling_min_freq = scaling_max_freq`).
  Measured live under actual 90%+ vCPU load: these cores sat locked at their
  ~1.75GHz floor the whole time, versus 4.2-4.8GHz on cores 0-3 under lighter
  load, despite the "performance" governor already being set on both. Root
  cause: amd-pstate-epp's boost request is re-applied on every scheduler
  tick, and `nohz_full` on the isolated cores (required for the VM's latency
  isolation) stops that tick -- so the boost request only ever got applied
  once at boot, before the VM had any load, and was never refreshed. Pinning
  the allowed frequency range to a single point is a static hardware request
  that doesn't need a tick to stay in effect. This, not the C-state residency
  fix above or any of the removed identity spoofing, was the actual cause of
  persistent VM lagginess -- the dedicated cores were running at roughly a
  third of their available clock regardless of load. These cores are 100%
  dedicated to the VM, so there's no idle-clock power saving worth keeping.
- Offloaded RCU callbacks use polling so they do not repeatedly wake isolated
  guest CPUs; the host NMI watchdog remains enabled.
- Normal systemd workloads, interrupts, unbound workqueues, and managed
  containers prefer the housekeeping CPUs on physical cores 0-3.
- Hyper-V/VBS support through libvirt's normal Hyper-V enlightenment settings.
- KVM IOAPIC, nested virtualization, and AVIC.
- VFIO passthrough for the configured GPU, storage, and USB controllers.
- The 2.5GbE NIC is host-owned (bridged as `br0`) instead of raw PCI
  passthrough, so NixOS (`10.0.0.3`, MAC cloned from the old 1G NIC, which is
  no longer a live bridge member so this is safe) and win11 (via a
  virtio-net interface on the same bridge) share it concurrently.
  win11's virtio-net MAC is fixed at `16:5d:34:c1:14:5e` (the real RTL8125
  MAC with the locally-administered bit set), deliberately NOT cloned as an
  exact match -- the real MAC now belongs to a live host interface
  (`enp41s0`) that's itself a bridge member, so a cloned guest MAC collides
  with the bridge's permanent local-port fdb entry and blackholes all
  inbound guest traffic (learned the hard way: DHCP/ARP replies never
  reached the guest even though its outbound broadcasts did). Router has two
  DHCP reservations to `10.0.0.2`, one per MAC -- baremetal's existing one on
  the real MAC, plus a new one on `16:5d:34:c1:14:5e` for the VM. Only one is
  ever live at a time since they're mutually exclusive boot modes of the
  same box. Bare-metal Windows is unaffected either way -- it never goes
  through NixOS/libvirt, so it always sees the NIC directly with its native
  driver regardless of how NixOS is using it. WoL
  is enabled host-side (`networking.interfaces.enp41s0.wakeOnLan.enable`)
  since Linux owns the physical device instead of Windows' driver.
- Deterministic systemd-owned VM startup after the current XML and passthrough
  bindings are ready; libvirt's independent domain autostart is disabled.
- Dedicated passthrough devices, including the physical boot NVMe, bind once to
  `vfio-pci` during initrd and remain bound throughout the NixOS boot.
- Only the two shared-ID USB controllers use libvirt-managed driver handoff.
- A single normal QEMU start; no preflight probes, driver handoff for dedicated
  devices, paused startup delay, or automatic reset.
- Routine autostart never rewrites persistent OVMF NVRAM.
- Hugepages remain reserved for the host boot. No synchronous libvirt hook
  compacts memory, drops caches, or changes hugepage allocation during VM
  lifecycle events.
- Host-only libvirt lifecycle and reboot monitoring powers off NixOS only after
  a normal guest shutdown that leaves the domain off; no Windows-side tooling
  is required.
- `reboot-to-windows` defers its one-time UEFI BootNext write until the guest
  later completes a clean shutdown, immediately before the monitor powers off
  NixOS.

## Not Active

- No NixOS kernel timing patch.
- No out-of-tree KVM hook module.
- No CPUID/RDTSC compensation module or helper command.
- No forced `tsc-frequency=` override.
- No full host FACP/DSDT table injection.
- No runtime IRQ or workqueue repinning from the libvirt hook.
- No runtime hugepage allocation or release from a libvirt hook.
- No host-initiated automatic guest reset, reboot, destroy, or retry after a
  startup failure. Guest-requested Windows restarts retain normal semantics.

## Checks

```bash
sudo verify-win11-vfio
sudo free-win11-hugepages
```

The ignored `qemu-vmcall-patch/` directory is an archive and is not part of the
active flake build.
