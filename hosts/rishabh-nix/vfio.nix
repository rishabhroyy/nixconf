{ config, pkgs, ... }:

let
  # The devices we want to pass through to the Windows 11 VM
  # RX 6700 XT (1002:73df), Samsung 980 Pro NVMe (144d:a80a), and Realtek 2.5Gbe NIC (10ec:8125)
  # NOTE: We intentionally EXCLUDE the USB controller (1022:149c) here because there are TWO of them!
  vfioIds = [ "1002:73df" "1002:ab28" "144d:a80a" "10ec:8125" "1b21:0612" ];
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
    "hugepagesz=2M"
    "hugepages=12288"
    ("vfio-pci.ids=" + builtins.concatStringsSep "," vfioIds)
  ];

  # Enable nested virtualization for AMD (required for Windows 11 VBS/Core Isolation)
  boot.extraModprobeConfig = "options kvm_amd nested=1";

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
  system.activationScripts.libvirt-hooks.text = let
    hookScript = pkgs.writeShellScript "qemu-hook" ''
      GUEST_NAME="$1"
      OPERATION="$2"
      SUB_OPERATION="$3"

      if [ "$GUEST_NAME" == "win11" ]; then
          # Log the event for debugging
          echo "$(date): win11 $OPERATION $SUB_OPERATION" >> /tmp/qemu-hook.log
          
          if [[ "$OPERATION" == "stopped" || "$OPERATION" == "release" ]]; then
              # Only power off if the lock file does NOT exist
              if [ ! -f /var/lib/libvirt/hooks/no-power-sync ]; then
                  echo "Windows 11 guest $OPERATION. Syncing power off to NixOS host." | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook
                  ${pkgs.systemd}/bin/systemctl poweroff
              else
                  echo "Windows 11 guest $OPERATION. Power sync suppressed by /var/lib/libvirt/hooks/no-power-sync" | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook
              fi
          fi
      fi
    '';
  in ''
    mkdir -p /etc/libvirt/hooks /var/lib/libvirt/hooks
    
    # Place in both /etc and /var paths to ensure libvirt picks it up
    cp -f ${hookScript} /etc/libvirt/hooks/qemu
    cp -f ${hookScript} /var/lib/libvirt/hooks/qemu
    
    chmod +x /etc/libvirt/hooks/qemu /var/lib/libvirt/hooks/qemu
  '';

  # Systemd service to define the VM from the template XML automatically
  systemd.services.define-win11-vm = {
    description = "Define Windows 11 VFIO VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for secrets to be decrypted by sops-nix
      while [ ! -f /run/secrets/motherboard_uuid ]; do
        echo "Waiting for motherboard_uuid secret..."
        sleep 1
      done
      # Copy the ROM from the local Nix repository to the libvirt directory so QEMU can read it
      # Placed in the qemu subfolder and chowned so AppArmor and the qemu user don't block it
      mkdir -p /var/lib/libvirt/qemu
      cp ${./6700xt.rom} /var/lib/libvirt/qemu/6700xt.rom
      chown root:root /var/lib/libvirt/qemu/6700xt.rom
      chmod 644 /var/lib/libvirt/qemu/6700xt.rom

      # Always redefine the VM to ensure XML template changes are applied
      if ${pkgs.libvirt}/bin/virsh dominfo win11 >/dev/null 2>&1; then
        echo "Updating existing win11 VM definition..."
        ${pkgs.libvirt}/bin/virsh undefine win11 --nvram
      fi

      export UUID=$(cat /run/secrets/motherboard_uuid)
      export SERIAL=$(cat /run/secrets/motherboard_serial)
      
      # Substitute the $UUID and $SERIAL variables into the template and define it
      ${pkgs.envsubst}/bin/envsubst < ${./win11-template.xml} > /tmp/win11-resolved.xml
      ${pkgs.libvirt}/bin/virsh define /tmp/win11-resolved.xml
      ${pkgs.libvirt}/bin/virsh autostart win11
      rm /tmp/win11-resolved.xml
    '';
  };

  environment.systemPackages = with pkgs; [
    virt-manager
    libguestfs
    qemu
    envsubst
  ];
}
