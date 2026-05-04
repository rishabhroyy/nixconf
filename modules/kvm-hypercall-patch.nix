{ config, pkgs, lib, ... }:

let
  # Build the kvm-hypercall-patch kernel module as a NixOS out-of-tree module.
  # This is the NixOS equivalent of `dkms install` from the original repo.
  # It intercepts kvm_emulate_hypercall via ftrace and raises UD_VECTOR,
  # preventing anti-cheats from detecting the VMCALL/VMMCALL instruction quirk.
  kvmHypercallPatch = config.boot.kernelPackages.callPackage (
    { stdenv, kernel }:
    stdenv.mkDerivation {
      name = "kvm-hypercall-patch-${kernel.version}";
      version = "1.0";

      src = ./kvm-hypercall-patch;

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
        cp kvm-hypercall-patch.ko $out/lib/modules/${kernel.modDirVersion}/misc/
      '';

      meta = {
        description = "Patches KVM hypercall (vmcall/vmmcall) to raise UD, preventing anti-cheat detection";
        license = lib.licenses.gpl2Only;
      };
    }
  ) {};
in
{
  # Build and install the out-of-tree kernel module
  boot.extraModulePackages = [ kvmHypercallPatch ];

  # Load the module at boot so it's always active when the VM starts
  boot.kernelModules = [ "kvm-hypercall-patch" ];
}
