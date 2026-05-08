{ config, pkgs, lib, ... }:

let
  cfg = config.ghost.vfio.cpuidTscCompensation;

  kvmTscCpuidCompensate = config.boot.kernelPackages.callPackage (
    { stdenv, kernel }:
    stdenv.mkDerivation {
      name = "kvm-tsc-cpuid-compensate-${kernel.version}";
      version = "1.0";

      src = ./kvm-tsc-cpuid-compensate;

      nativeBuildInputs = kernel.moduleBuildDependencies;

      makeFlags = [
        "KERNEL_VERSION=${kernel.version}"
        "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
      ];

      buildPhase = ''
        make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
          M=$(pwd) \
          KERNEL_VERSION=${kernel.modDirVersion} \
          modules
      '';

      installPhase = ''
        mkdir -p $out/lib/modules/${kernel.modDirVersion}/misc
        cp kvm-tsc-cpuid-compensate.ko $out/lib/modules/${kernel.modDirVersion}/misc/
      '';

      meta = {
        description = "Compensates guest TSC for KVM CPUID VM-exit latency";
        license = lib.licenses.gpl2Only;
      };
    }
  ) {};
in
{
  options.ghost.vfio.cpuidTscCompensation = {
    enableAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Load and enable the CPUID TSC compensation module at boot.";
    };

    targetCycles = lib.mkOption {
      type = lib.types.int;
      default = 250;
      description = "Guest-visible CPUID latency target, in guest TSC cycles.";
    };

    maxCycles = lib.mkOption {
      type = lib.types.int;
      default = 200000;
      description = "Ignore compensation above this guest TSC cycle delta.";
    };
  };

  config = {
    boot.extraModulePackages = [ kvmTscCpuidCompensate ];

    boot.extraModprobeConfig = ''
      options kvm-tsc-cpuid-compensate enabled=${if cfg.enableAtBoot then "1" else "0"} target_cycles=${toString cfg.targetCycles} max_cycles=${toString cfg.maxCycles}
    '';

    boot.kernelModules = lib.optionals cfg.enableAtBoot [ "kvm-tsc-cpuid-compensate" ];

    system.activationScripts.disableKvmTscCpuidCompensate = lib.mkIf (!cfg.enableAtBoot) ''
      if [ -w /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled ]; then
        echo 0 > /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled
      fi
    '';

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "enable-vanguard-rdtsc-patch" ''
        set -eu
        ko="${kvmTscCpuidCompensate}/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/misc/kvm-tsc-cpuid-compensate.ko"

        if [ ! -d /sys/module/kvm_tsc_cpuid_compensate ]; then
          ${pkgs.kmod}/bin/insmod "$ko" \
            enabled=1 \
            target_cycles=${toString cfg.targetCycles} \
            max_cycles=${toString cfg.maxCycles}
        else
          echo 1 > /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled
        fi

        ${pkgs.coreutils}/bin/printf 'enabled='
        ${pkgs.coreutils}/bin/cat /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled
        ${pkgs.coreutils}/bin/printf 'target_cycles='
        ${pkgs.coreutils}/bin/cat /sys/module/kvm_tsc_cpuid_compensate/parameters/target_cycles
        ${pkgs.coreutils}/bin/printf 'max_cycles='
        ${pkgs.coreutils}/bin/cat /sys/module/kvm_tsc_cpuid_compensate/parameters/max_cycles
      '')

      (pkgs.writeShellScriptBin "disable-vanguard-rdtsc-patch" ''
        set -eu

        if [ -d /sys/module/kvm_tsc_cpuid_compensate ]; then
          echo 0 > /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled
        fi

        ${pkgs.coreutils}/bin/printf 'enabled='
        ${pkgs.coreutils}/bin/cat /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled 2>/dev/null || ${pkgs.coreutils}/bin/echo unloaded
      '')
    ];
  };
}
