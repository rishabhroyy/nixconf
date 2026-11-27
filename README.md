# nixconf

Personal NixOS configuration for the `rishabh-nix` desktop.

## Contents

- The top-level flake configures the `rishabh-nix` desktop.
- Secrets are encrypted with `sops-nix`.
- Homelab mode: Windows 11 VFIO VM on demand, dashboard on the monitor and tailnet.
- Docker services for media and admin tools.
- Samba export for local storage.
- `windows/`: packages, profile, and scripts for the Windows guest (see `windows/README.md`).

## Deploy

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix --cores 14
```

The default deployment path applies changes in place. Kernel, initrd, bootloader,
VFIO device-binding, and firmware changes still require a later reboot before
they take effect.

Most paths, PCI IDs, disk UUIDs, and firmware assets are host-specific. Review
the files under `hosts/rishabh-nix/` before reusing this configuration elsewhere.
