{ config, pkgs, inputs, ... }:

{
  imports = [
    # Include hardware-configuration if it was generated (we leave a placeholder or assume it's created by user)
    ./hardware-configuration.nix
    ./vfio.nix
    ./containers.nix
    ./samba-ntfs.nix
  ];
  
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Bootloader (Systemd-boot as default for modern UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "rishabh-nix";

  # We are passing the 2.5G NIC natively to the VM via VFIO, so NixOS uses the 1G motherboard NIC.
  # Enable global DHCP so NixOS automatically grabs an IP from your router on the 1G connection.
  networking.useDHCP = true;

  # Tailscale
  services.tailscale.enable = true;
  services.tailscale.authKeyFile = config.sops.secrets.tailscale_auth_key.path;

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true; # Enabled to allow password SSH login
    };
  };

  # User Configuration
  users.users.rishabh = {
    isNormalUser = true;
    description = "Rishabh";
    hashedPasswordFile = config.sops.secrets.user_password.path;
    extraGroups = [ "networkmanager" "wheel" "docker" "libvirtd" "kvm" ];
    openssh.authorizedKeys.keyFiles = [
      ./keys/mac.pub
      ./keys/windows.pub
    ];
  };

  # SOPS Secrets configuration
  sops.defaultSopsFile = ./secrets.yaml;
  sops.defaultSopsFormat = "yaml";
  # Ensure sops can use an ssh key or age key
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";
  # Fallback to ssh keys if age key isn't present
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # Explicitly declare the secrets to make them available at /run/secrets/
  sops.secrets.motherboard_uuid = {};
  sops.secrets.motherboard_serial = {};
  sops.secrets.tailscale_auth_key = {};
  sops.secrets.immich_db_password = {};
  
  # Dynamically generate the Immich stack.env file natively from the Nix configuration
  sops.templates."immich.env".content = ''
    DB_PASSWORD=${config.sops.placeholder.immich_db_password}
    DB_USERNAME=postgres
    DB_DATABASE_NAME=immich
    IMMICH_VERSION=release
    TZ=America/Los_Angeles
  '';

  # Dynamically generate the Tailscale environment file for Docker sidecars
  sops.templates."tailscale.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder.tailscale_auth_key}
  '';

  # User password needs to be decrypted earlier in the boot process
  sops.secrets.user_password.neededForUsers = true;

  # System state version
  system.stateVersion = "24.05";

  # Allow unfree packages specifically for NVIDIA drivers
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (pkgs.lib.getName pkg) [
    "nvidia-x11"
    "nvidia-settings"
    "nvidia-persistenced"
    "nvidia-kernel-modules"
  ];

  # Enable NVIDIA drivers for the host GPU (Quadro P620) to support CUDA in Docker
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = false; # P620 requires the closed-source driver
    nvidiaSettings = false;
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };
  
  # Enable NVIDIA Container Toolkit for Docker (--gpus=all)
  hardware.nvidia-container-toolkit.enable = true;

  # ---------------------------------------------------------
  # Power Sync & ACPI (Host Shutdown triggered by Power Button)
  # ---------------------------------------------------------
  # Intercept the physical power button so logind doesn't immediately kill the host
  services.logind.settings.Login.HandlePowerKey = "ignore";
  
  services.acpid = {
    enable = true;
    handlers = {
      power = {
        event = "button/power.*";
        action = ''
          # 1. Send ACPI shutdown signal to the Windows 11 VM
          ${pkgs.libvirt}/bin/virsh shutdown win11
          
          # 2. Wait up to 120 seconds for the VM process to exit gracefully
          for i in {1..120}; do
            if ! ${pkgs.libvirt}/bin/virsh list | grep -q "win11"; then
              break
            fi
            sleep 1
          done
          
          # 3. Safely power off the NixOS host
          /run/current-system/sw/bin/shutdown -h now
        '';
      };
    };
  };

  # ---------------------------------------------------------
  # Windows 11 SSD Protections (Defense-in-Depth)
  # ---------------------------------------------------------
  services.udev.extraRules = ''
    # Hide the 1TB SATA SSD (Game Drive) from Linux so it is strictly for the Windows VM
    # The ID ata-SanDisk_SSD_PLUS_1000GB_221306A0095A is used in the QEMU XML.
    KERNEL=="sd*", SUBSYSTEM=="block", ENV{ID_SERIAL}=="*SanDisk_SSD_PLUS_1000GB_221306A0095A*", ENV{UDISKS_IGNORE}="1", OWNER="qemu", GROUP="qemu", MODE="0600"
    
    # Hide the 1TB NVMe SSD (Samsung 980 Pro) from Linux (fallback protection if VFIO ever fails to bind)
    KERNEL=="nvme*", SUBSYSTEM=="block", ATTRS{model}=="Samsung SSD 980 PRO 1TB", ENV{UDISKS_IGNORE}="1", OWNER="qemu", GROUP="qemu", MODE="0600"
  '';

  # ---------------------------------------------------------
  # Container Storage & Permissions
  # ---------------------------------------------------------
  systemd.tmpfiles.rules = [
    "d /var/lib/seanime 0755 1001 1001 -"
    "d /var/lib/tailscale-immich 0755 root root -"
    "d /var/lib/tailscale-seanime 0755 root root -"
    "d /var/lib/tailscale-portainer 0755 root root -"
    "d /var/lib/immich 0755 1000 1000 -"
  ];

  # ---------------------------------------------------------
  # System Auto-Update & Maintenance
  # ---------------------------------------------------------
  system.autoUpgrade = {
    enable = true;
    flake = "github:rishabhroyy/nixconf";
    allowReboot = false; # Never randomly restart the host
    dates = "04:00";
    randomizedDelaySec = "45min";
  };

  environment.systemPackages = with pkgs; [
    # Basic Utilities
    git
    vim
    nano
    wget
    curl
    rsync
    screen
    tmux
    htop
    btop
    
    # Archives
    zip
    unzip
    p7zip
    
    # Hardware & Network Debugging
    pciutils # lspci
    usbutils # lsusb
    nettools # ifconfig
    dnsutils # dig, nslookup
    ethtool
    
    # System info
    fastfetch
    tree
    (pkgs.writeShellScriptBin "update-containers" ''
      echo "Pulling latest images for all stacks..."
      ${pkgs.docker}/bin/docker pull ghcr.io/immich-app/immich-server:release
      ${pkgs.docker}/bin/docker pull ghcr.io/immich-app/immich-machine-learning:release-cuda
      ${pkgs.docker}/bin/docker pull umagistr/seanime:latest-cuda
      ${pkgs.docker}/bin/docker pull portainer/portainer-ce:latest
      ${pkgs.docker}/bin/docker pull caddy:alpine
      ${pkgs.docker}/bin/docker pull tailscale/tailscale:latest
      
      echo "Restarting all container stacks to apply updates and refresh sidecars..."
      
      # Immich Stack
      systemctl restart docker-tailscale-immich.service \
                        docker-immich-server.service \
                        docker-immich-machine-learning.service \
                        docker-immich-redis.service \
                        docker-immich-database.service \
                        docker-immich-proxy.service

      # Seanime Stack
      systemctl restart docker-tailscale-seanime.service \
                        docker-seanime.service \
                        docker-seanime-proxy.service

      # Portainer Stack
      systemctl restart docker-tailscale-portainer.service \
                        docker-portainer.service \
                        docker-portainer-proxy.service
      
      echo "All containers updated and restarted!"
    '')
  ];

  environment.shellAliases = {
    update-containers = "sudo /run/current-system/sw/bin/update-containers";
    disable-power-sync = "sudo touch /var/lib/libvirt/hooks/no-power-sync && echo 'Power sync disabled.'";
    enable-power-sync = "sudo rm -f /var/lib/libvirt/hooks/no-power-sync && echo 'Power sync enabled.'";
    nix-deploy = "cd /etc/nixos/nixconf && sudo git pull && sudo nixos-rebuild switch --flake .#rishabh-nix && cd -";
  };
}
