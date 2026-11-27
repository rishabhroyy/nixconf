# The host's CPU split, used by vfio.nix (kernel isolation, the VM's tuning
# services, emulator pinning) and containers.nix (the container slice).
# The win11 vCPUs own the isolated CPUs: physical cores 4-7 and their SMT
# siblings. The vCPU-to-CPU pairs themselves are in win11-template.xml.
rec {
  isolatedList = [ 4 5 6 7 12 13 14 15 ];
  isolated = "4-7,12-15";
  housekeeping = "0-3,8-11";
  # Shell-loop form, e.g. `for CPU in ${isolatedWords}`.
  isolatedWords = builtins.concatStringsSep " " (map toString isolatedList);
}
