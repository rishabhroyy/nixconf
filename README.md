# nixconf

Personal NixOS flake for a single host.

## Contents

- NixOS host configuration with `sops-nix` secrets.
- Libvirt/VFIO Windows 11 VM definition.
- Docker services for media and admin tools.
- Samba export for local storage.

## Deploy

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix --cores 14
```

The default deployment path applies changes in place. Kernel, initrd, bootloader,
VFIO device-binding, hugepage-reservation, and firmware changes still require a
later reboot before they take effect.

Most paths, PCI IDs, disk UUIDs, and firmware assets are host-specific. Review
the files under `hosts/rishabh-nix/` before reusing this configuration elsewhere.
