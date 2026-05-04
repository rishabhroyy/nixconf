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
    # Applies qemu-vmcall-patch/changes.patch via the standard NixOS patches mechanism.
    qemuPatchedOverlay = final: prev:
    let
      applyHypercallFix = pkg: pkg.overrideAttrs (old: {
        patches = (old.patches or []) ++ [ ./patches/qemu-disable-hypercall-quirk.patch ];
      });
    in {
      qemu_kvm = applyHypercallFix prev.qemu_kvm;
      qemu = applyHypercallFix prev.qemu;
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
