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
- Hyper-V/VBS support through libvirt's normal Hyper-V enlightenment settings.
- KVM IOAPIC, nested virtualization, and AVIC.
- VFIO passthrough for the configured GPU, storage, USB controllers, and NIC.

## Not Active

- No NixOS kernel timing patch.
- No out-of-tree KVM hook module.
- No CPUID/RDTSC compensation module or helper command.
- No forced `tsc-frequency=` override.
- No full host FACP/DSDT table injection.
- No runtime IRQ or workqueue repinning from the libvirt hook.

## Checks

```bash
sudo verify-win11-vfio
sudo free-win11-hugepages
```

The ignored `qemu-vmcall-patch/` directory is an archive and is not part of the
active flake build.
