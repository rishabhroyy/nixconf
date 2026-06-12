{
  description = "NixOS configuration for the Oracle Cloud ARM server rishabh-vm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, sops-nix, ... }: {
    nixosConfigurations.rishabh-vm = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        sops-nix.nixosModules.sops
        ./configuration.nix
      ];
    };
  };
}
