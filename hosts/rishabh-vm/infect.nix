{ lib, ... }:

let
  sops-nix = builtins.fetchTarball {
    url = "https://github.com/Mic92/sops-nix/archive/9ed65852b6257fbeae4355bc24ecfea307ca759a.tar.gz";
  };
in
{
  imports = [
    "${sops-nix}/modules/sops"
    ./configuration.nix
  ];

  networking.hostName = lib.mkForce "rishabh-vm";
  system.stateVersion = lib.mkForce "26.05";
}
