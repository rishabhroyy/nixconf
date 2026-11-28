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
- 16 GiB RAM backed by 2 MiB hugepages, allocated at VM start and freed at
  stop by `win11.service` (homelab.nix).
- 8 vCPUs with host-passthrough CPU, cache passthrough, `topoext`, `invtsc`,
  and a 4-core / 8-thread topology.
- All 8 vCPUs are pinned to CPUs 4-7/12-15 (physical cores 4-7 plus their
  SMT siblings). While the VM runs, `win11.service` moves the host
  (system/user slices, init, IRQs, unbound workqueues) onto CPUs 0-3/8-11,
  shared with the QEMU emulator threads; with the VM off the host has all 16.
  No boot-time isolation (`isolcpus`/`nohz_full`/`rcu_nocbs`).
- The QEMU emulator thread uses low-priority real-time round-robin
  scheduling (priority 1) so it isn't queued behind containers on the
  housekeeping CPUs; the vCPU threads use normal scheduling on their
  dedicated isolated CPUs.
- virtio-net uses 4 vhost queues (NetKVM RSS).
- `kvm.halt_poll_ns=500000`, and the C2 idle state disabled on cores
  4-7/12-15 only while the VM runs, to keep guest wakeups cheap.
- No P-state pinning: the earlier `scaling_min_freq = scaling_max_freq`
  workaround existed only because `nohz_full` stopped the scheduler tick that
  re-applies amd-pstate-epp's boost request. Without `nohz_full` the normal
  governor works; check `scaling_cur_freq` in `verify-win11-vfio` under load.
- `machine.slice` has `CPUWeight=1000`, so the VM's threads (emulator,
  vhost-net) win over containers on the shared CPUs. No container CPU caps.
- Hyper-V enlightenments (incl. `avic`, so SynIC doesn't inhibit AVIC) with
  the hypervisor CPUID bit visible -- hiding it made Windows ignore all of
  them. Only works with SVM hidden (below); with SVM exposed, Windows hangs
  at boot trying to launch Hyper-V.
- SVM hidden from the guest, so VBS/HVCI, WSL2, and Hyper-V can't run nested
  inside the VM. Bare-metal Windows is unaffected and keeps VBS.
- KVM IOAPIC and AVIC. `kvm_amd nested=0`: SVM is hidden from the guest, so
  nested virtualization could never be used.
- VFIO passthrough for the configured GPU, storage, and USB controllers.
- The 2.5GbE NIC is host-owned (bridged as `br0`) instead of raw PCI
  passthrough, so NixOS (`10.0.0.3`, MAC cloned from the old 1G NIC, which is
  no longer a live bridge member so this is safe) and win11 (via a
  virtio-net interface on the same bridge) share it concurrently.
  win11's virtio-net MAC is the RTL8125's real hardware MAC
  (`14:5d:34:c1:14:5e`) -- this works because `enp41s0`'s own software MAC
  is deliberately overridden to a different, locally-administered address
  (`16:5d:34:c1:14:5e`) via `systemd.services.set-enp41s0-mac` in
  `configuration.nix`, specifically to free the real MAC up for the VM (an
  explicit oneshot doing `ip link set ... down/address/up`, not the
  declarative `networking.interfaces.*.macAddress` option -- that option
  did not reliably apply in practice, verified live). Without that
  override, the real MAC collides with
  the bridge's automatic "permanent, local" fdb entry for `enp41s0`'s own
  address and silently blackholes all inbound guest traffic (learned the
  hard way: DHCP/ARP replies never reached the guest even though its
  outbound broadcasts did). With the real MAC exclusively the VM's, the
  router's existing DHCP reservation for `10.0.0.2` keeps matching with no
  router-side changes and no static IP in Windows. Bare-metal Windows uses
  the same real MAC directly -- it never goes through NixOS/libvirt, so it
  always sees the NIC natively regardless of how NixOS is using it, and the
  two are never live on the network at the same time. WoL
  is enabled host-side (`networking.interfaces.enp41s0.wakeOnLan.enable`)
  since Linux owns the physical device instead of Windows' driver.
- VM starts only on request (`win on`, the dashboard), never at boot; libvirt's
  own domain autostart stays disabled.
- The boot NVMe binds to `vfio-pci` during initrd and stays
  there. The RX 6700 XT, its HDMI audio and the two USB controllers use
  libvirt-managed handoff (amdgpu/xhci while Windows is off).
- `win11.service` stops `homelab.target` and refuses to start Windows while any
  host process still holds the GPU.
- Routine startup never rewrites persistent OVMF NVRAM.
- Windows shutting down (from inside, `win off`, or any host shutdown) returns
  the machine to homelab mode; it no longer powers the host off. `win off`
  uses Windows' OpenSSH server; the ACPI power button is only a fallback.

## Not Active

- No NixOS kernel timing patch.
- No out-of-tree KVM hook module.
- No CPUID/RDTSC compensation module or helper command.
- No forced `tsc-frequency=` override.
- No full host FACP/DSDT table injection.
- No libvirt hooks. Runtime CPU/IRQ/workqueue repinning and hugepage
  allocation run from `win11.service`, outside libvirtd.
- No host-initiated automatic guest reset, reboot, destroy, or retry after a
  startup failure. Guest-requested Windows restarts retain normal semantics.

## Checks

```bash
sudo verify-win11-vfio
```

The ignored `qemu-vmcall-patch/` directory is an archive and is not part of the
active flake build.
