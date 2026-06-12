# nixconf

Personal NixOS configurations for two independently managed hosts.

## Contents

- The top-level flake configures the `rishabh-nix` desktop.
- `hosts/rishabh-vm` is a separate nested flake for the Oracle Cloud server.
- Both hosts use separate `sops-nix` recipients and encrypted secrets.
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

The server has its own installation and maintenance guide:

```text
hosts/rishabh-vm/README.md
```

Most paths, PCI IDs, disk UUIDs, and firmware assets are host-specific. Review
the files under `hosts/rishabh-nix/` before reusing this configuration elsewhere.
