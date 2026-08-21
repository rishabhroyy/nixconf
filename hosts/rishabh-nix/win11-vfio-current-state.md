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
  (`disable-win11-core-cstates.service`). Measured live: those cores were
  spending effectively all their time parked in C2 (18us entry latency, 36us
  break-even) between the guest's bursty HLTs, which kept amd-pstate-epp's
  autonomous boost algorithm from ever seeing sustained load -- they were
  pinned at their ~1.75GHz floor instead of boosting toward 4.85GHz,
  regardless of the "performance" governor already being set. This, not any
  of the removed identity spoofing, was the actual cause of persistent VM
  lagginess. Fix costs a bit of idle power/heat on the isolated cores only;
  cores 0-3/8-11 keep normal idle behavior.
- Offloaded RCU callbacks use polling so they do not repeatedly wake isolated
  guest CPUs; the host NMI watchdog remains enabled.
- Normal systemd workloads, interrupts, unbound workqueues, and managed
  containers prefer the housekeeping CPUs on physical cores 0-3.
- Hyper-V/VBS support through libvirt's normal Hyper-V enlightenment settings.
- KVM IOAPIC, nested virtualization, and AVIC.
- VFIO passthrough for the configured GPU, storage, USB controllers, and NIC.
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
