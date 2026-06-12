{
  description = "NixOS configuration for the Oracle Cloud ARM server rishabh-vm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, sops-nix, ... }: {
    nixosConfigurations.rishabh-vm = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./configuration.nix
      ];
    };
  };
}
