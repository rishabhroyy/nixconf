{
  description = "PROJECT GHOST-HOST NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix, ... }@inputs:
  let
    # Overlay to patch QEMU with the vmcall/hypercall quirk fix.
    # This prevents anti-cheats (Genshin, Vanguard) from detecting the VMCALL
    # instruction rewriting quirk and triggering a BSOD.
    qemuPatchedOverlay = final: prev:
    let
      hypercallPatch = ./patches/qemu-disable-hypercall-quirk.patch;
      applyPatch = pkg: pkg.overrideAttrs (old: {
        patches = (old.patches or []) ++ [ hypercallPatch ];
      });
    in {
      # Patches qemu_kvm (used by libvirtd for the VM)
      qemu_kvm = applyPatch prev.qemu_kvm;
      # Patches qemu (full) which provides qemu-system-x86_64 in the system PATH
      qemu = applyPatch prev.qemu;
    };
  in
  {
    nixosConfigurations = {
      rishabh-nix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          { nixpkgs.overlays = [ qemuPatchedOverlay ]; }
          sops-nix.nixosModules.sops
          ./hosts/rishabh-nix/configuration.nix
        ];
      };
    };
  };
}
