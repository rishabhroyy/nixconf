# The host's CPU split while Windows runs, used by vfio.nix (the VM's
# emulator pinning) and homelab.nix (the runtime split applied when Windows
# starts and undone when it stops). The win11 vCPUs own the isolated CPUs:
# physical cores 4-7 and their SMT siblings. The vCPU-to-CPU pairs
# themselves are in win11-template.xml. With Windows off, the host gets all.
rec {
  isolatedList = [ 4 5 6 7 12 13 14 15 ];
  isolated = "4-7,12-15";
  housekeeping = "0-3,8-11";
  all = "0-15";
  # Hex masks of the same sets, for /proc/irq and the workqueue cpumask.
  housekeepingMask = "0f0f";
  allMask = "ffff";
  # Shell-loop form, e.g. `for CPU in ${isolatedWords}`.
  isolatedWords = builtins.concatStringsSep " " (map toString isolatedList);
}
