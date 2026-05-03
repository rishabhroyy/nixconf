{ config, pkgs, ... }:

let
  # The devices we want to pass through to the Windows 11 VM
  # RX 6700 XT (1002:73df), Samsung 980 Pro NVMe (144d:a80a), and Realtek 2.5Gbe NIC (10ec:8125)
  # NOTE: We intentionally EXCLUDE the USB controller (1022:149c) here because there are TWO of them!
  vfioIds = [ "1002:73df" "1002:ab28" "144d:a80a" "10ec:8125" ];
in
{
  # Kernel parameters for IOMMU, VFIO, and CPU Isolation
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    # Isolate Cores 2-7 and 10-15 (Physical pairs) for the Windows 11 VM
    "isolcpus=2-7,10-15"
    "nohz_full=2-7,10-15"
    "rcu_nocbs=2-7,10-15"
    "kvm.ignore_msrs=1"
    "kvm.report_ignored_msrs=0"
    ("vfio-pci.ids=" + builtins.concatStringsSep "," vfioIds)
  ];

  # Load VFIO modules
  boot.initrd.kernelModules = [
    "vfio_pci"
    "vfio"
    "vfio_iommu_type1"
  ];

  # Virtualization settings
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "ignore";
    onShutdown = "shutdown";
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
    };
  };

  # Hook for VM-to-Host Power Sync
  system.activationScripts.libvirt-hooks.text = ''
    mkdir -p /etc/libvirt/hooks
    cp ${../../modules/scripts/qemu-hook.sh} /etc/libvirt/hooks/qemu
    chmod +x /etc/libvirt/hooks/qemu
  '';

  # Systemd service to define the VM from the template XML automatically
  systemd.services.define-win11-vm = {
    description = "Define Windows 11 VFIO VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" "sops-nix.service" ];
    requires = [ "libvirtd.service" "sops-nix.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Copy the ROM from the local Nix repository to the libvirt directory so QEMU can read it
      # Placed in the qemu subfolder and chowned so AppArmor and the qemu user don't block it
      mkdir -p /var/lib/libvirt/qemu
      cp ${./6700xt.rom} /var/lib/libvirt/qemu/6700xt.rom
      chown qemu:qemu /var/lib/libvirt/qemu/6700xt.rom
      chmod 644 /var/lib/libvirt/qemu/6700xt.rom

      # Substitute secrets into the XML template
      if ! ${pkgs.libvirt}/bin/virsh dominfo win11 >/dev/null 2>&1; then
        export UUID=$(cat /run/secrets/motherboard_uuid)
        export SERIAL=$(cat /run/secrets/motherboard_serial)
        
        # Substitute the $UUID and $SERIAL variables into the template and define it
        ${pkgs.envsubst}/bin/envsubst < ${./win11-template.xml} > /tmp/win11-resolved.xml
        ${pkgs.libvirt}/bin/virsh define /tmp/win11-resolved.xml
        ${pkgs.libvirt}/bin/virsh autostart win11
        rm /tmp/win11-resolved.xml
      fi
    '';
  };

  environment.systemPackages = with pkgs; [
    virt-manager
    libguestfs
    qemu
    envsubst
  ];
}
