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
- Normal systemd workloads, interrupts, unbound workqueues, and managed
  containers prefer the housekeeping CPUs on physical cores 0-3.
- Hyper-V/VBS support through libvirt's normal Hyper-V enlightenment settings.
- KVM IOAPIC, nested virtualization, and AVIC.
- VFIO passthrough for the configured GPU, storage, USB controllers, and NIC.
- Deterministic systemd-owned VM startup after the current XML and passthrough
  bindings are ready; libvirt's independent domain autostart is disabled.
- Startup waits for udev/network readiness and verifies that the physical TPM
  responds before QEMU starts.
- Safe paused startup: QEMU initializes VFIO devices for 30 seconds before
  guest CPUs and Windows storage are allowed to run.
- Host-only libvirt lifecycle monitoring powers off NixOS only after a normal
  guest shutdown; no Windows-side tooling is required.

## Not Active

- No NixOS kernel timing patch.
- No out-of-tree KVM hook module.
- No CPUID/RDTSC compensation module or helper command.
- No forced `tsc-frequency=` override.
- No full host FACP/DSDT table injection.
- No runtime IRQ or workqueue repinning from the libvirt hook.
- No automatic guest reset, reboot, destroy, or retry.

## Checks

```bash
sudo verify-win11-vfio
sudo free-win11-hugepages
```

The ignored `qemu-vmcall-patch/` directory is an archive and is not part of the
active flake build.
