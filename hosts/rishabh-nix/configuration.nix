{ config, pkgs, lib, ... }:

let
  # Flip this to true for a boring SSH/Tailscale-only rescue boot.
  recoveryMode = false;
in
{
  imports = [
    ./hardware-configuration.nix
  ] ++ lib.optionals (!recoveryMode) [
    ./containers.nix
    ./samba-ntfs.nix
    ./vfio.nix
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Bootloader (Systemd-boot as default for modern UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "rishabh-nix";

  # We are passing the 2.5G NIC natively to the VM via VFIO, so NixOS uses the 1G motherboard NIC.
  # Enable global DHCP so NixOS automatically grabs an IP from your router on the 1G connection.
  networking.useDHCP = true;

  # Tailscale
  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    useRoutingFeatures = "server";
    extraUpFlags = [
      "--advertise-exit-node"
    ];
  };

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

  users.groups = lib.mkIf recoveryMode {
    docker = {};
    kvm = {};
    libvirtd = {};
    qemu = {};
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
  sops.secrets.copyparty_password = {};

  # Hermes's 4 vCPUs are unpinned QEMU threads on the same 8-thread shared
  # pool (cores 0-3/8-11) as every container and the host itself -- Windows
  # is safe (isolcpus + systemd.cpu_affinity keep it off cores 4-7/12-15
  # entirely), but nothing stops Hermes from crowding out Immich/Seanime/etc
  # under load. Lower cgroup weight (default is 100) lets it still burst to
  # all 4 vCPUs when the pool is idle, but yields under contention instead
  # of starving containers.
  systemd.services."microvm@hermes".serviceConfig.CPUWeight = 50;

  # Copy the Tailscale auth key (decrypted above, host-side, from the same
  # secrets.yaml as everything else) into the directory shared with the
  # hermes microvm. The guest never gets a decryption key of its own, so a
  # compromised agent there can only read this one plaintext value, not the
  # rest of this file. It's the same reusable key the host itself uses, so
  # it must stay reusable in the Tailscale admin console.
  #
  # Deliberately not syncing a hermes_env/API-key secret here -- Hermes is
  # unmanaged (see hosts/rishabh-nix/microvms/hermes.nix), configured by
  # hand via `hermes setup` inside the guest, so there's nothing declarative
  # to feed it.
  systemd.services.hermes-secrets-sync = {
    description = "Copy the Tailscale auth key into the shared microvm directory";
    before = [ "microvm@hermes.service" ];
    requiredBy = [ "microvm@hermes.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      install -d -m 0700 /var/lib/microvms/hermes/secrets
      install -m 0400 ${config.sops.secrets.tailscale_auth_key.path} /var/lib/microvms/hermes/secrets/tailscale_auth_key
    '';
  };

  # Dynamically generate the Immich stack.env file natively from the Nix configuration
  sops.templates."immich.env".content = ''
    DB_PASSWORD=${config.sops.placeholder.immich_db_password}
    DB_USERNAME=postgres
    DB_DATABASE_NAME=immich
    DB_HOSTNAME=127.0.0.1
    REDIS_HOSTNAME=127.0.0.1
    IMMICH_VERSION=release
    TZ=America/Los_Angeles
  '';

  # Dynamically generate the Tailscale environment file for Docker sidecars
  sops.templates."tailscale.env".content = ''
    TS_AUTHKEY=${config.sops.placeholder.tailscale_auth_key}
  '';

  sops.templates."copyparty.conf" = {
    owner = "rishabh";
    mode = "0400";
    content = ''
      [global]
        e2dsa
        e2ts
        hist: /cfg/hists/

      [accounts]
        rishabh: ${config.sops.placeholder.copyparty_password}

      [/]
        /w
        accs:
          r: *
          rwmda: rishabh
        flags:
          grid
    '';
  };

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
  services.xserver.videoDrivers = lib.optionals (!recoveryMode) [ "nvidia" ];
  hardware.nvidia = lib.mkIf (!recoveryMode) {
    modesetting.enable = true;
    open = false; # P620 requires the closed-source driver
    nvidiaSettings = false;
    package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
  };
  
  # Enable NVIDIA Container Toolkit for Docker (--gpus=all)
  hardware.nvidia-container-toolkit.enable = !recoveryMode;

  # ---------------------------------------------------------
  # Power Sync & ACPI (Host Shutdown triggered by Power Button)
  # ---------------------------------------------------------
  # Intercept the physical power button so logind doesn't immediately kill the host
  services.logind.settings.Login.HandlePowerKey = "ignore";
  
  services.acpid = lib.mkIf (!recoveryMode) {
    enable = true;
    handlers = {
      power = {
        event = "button/power.*";
        action = ''
          CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null || true)"
          case "$CURRENT_STATE" in
            "shut off")
              ${pkgs.systemd}/bin/systemctl poweroff
              ;;
            running|blocked)
              # The lifecycle monitor powers off NixOS only after libvirt
              # confirms that Windows completed a clean shutdown.
              ${pkgs.systemd}/bin/systemctl start win11-power-sync-monitor.service || true
              ${pkgs.libvirt}/bin/virsh shutdown win11
              ;;
            "in shutdown")
              ;;
            *)
              echo "Refusing to power off NixOS while win11 is in state '$CURRENT_STATE'." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-button -p warning
              ;;
          esac
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
    
    # Fallback protection if the dedicated NVMe ever fails to bind to vfio-pci.
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
    "d /var/lib/tailscale-copyparty 0755 root root -"
    "d /var/lib/immich 0755 1000 1000 -"
    "d /var/lib/copyparty 0755 1000 100 -"
  ];

  systemd.services.docker-copyparty = lib.mkIf (!recoveryMode) {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  };

  systemd.services.docker-immich-server = lib.mkIf (!recoveryMode) {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  };

  systemd.services.docker-seanime = lib.mkIf (!recoveryMode) {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  };

  # ---------------------------------------------------------
  # System Auto-Update & Maintenance
  # ---------------------------------------------------------
  system.autoUpgrade = {
    enable = lib.mkDefault (!recoveryMode);
    flake = "github:rishabhroyy/nixconf";
    operation = "switch";
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
    github-cli
    
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
    efibootmgr
    binutils # strings, objdump, etc.
    
    # System info
    fastfetch
    tree
    (pkgs.writeShellScriptBin "reboot-to-windows" ''
      set -eu

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null || true)"
      case "$CURRENT_STATE" in
        running|paused|blocked|pmsuspended|"in shutdown")
          ;;
        *)
          echo "win11 is not active ($CURRENT_STATE); there is no guest shutdown to wait for." >&2
          exit 1
          ;;
      esac

      BOOTNUM="$(${pkgs.efibootmgr}/bin/efibootmgr | ${pkgs.gawk}/bin/awk '
        BEGIN { IGNORECASE = 1 }
        /^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]/ && /Windows Boot Manager/ {
          boot = $1
          gsub(/^Boot/, "", boot)
          gsub(/\*/, "", boot)
          print boot
          exit
        }
      ')"

      if [ -z "$BOOTNUM" ]; then
        echo "Could not find a UEFI entry named Windows Boot Manager." >&2
        ${pkgs.efibootmgr}/bin/efibootmgr >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/touch /run/win11-boot-baremetal-next
      echo "Waiting for win11 to shut down normally; the VM and NixOS host were left running."
      echo "After that clean shutdown, Windows Boot Manager (Boot$BOOTNUM) will be armed for the next host startup."

      if [ -e /run/win11-power-sync.disabled ]; then
        echo "Warning: power sync is disabled, so shutting down the VM will not power off NixOS." >&2
      elif ! ${pkgs.systemd}/bin/systemctl is-active --quiet win11-power-sync-monitor.service; then
        echo "Warning: the power-sync monitor is not active, so verify the host powers off before the next startup." >&2
      fi
    '')
    (pkgs.writeShellScriptBin "update-containers" ''
      set -euo pipefail

      echo "Pulling latest images for all stacks..."
      ${pkgs.docker}/bin/docker pull ghcr.io/immich-app/immich-server:release
      ${pkgs.docker}/bin/docker pull ghcr.io/immich-app/immich-machine-learning:release-cuda
      ${pkgs.docker}/bin/docker pull umagistr/seanime:latest-cuda
      ${pkgs.docker}/bin/docker pull portainer/portainer-ce:latest
      ${pkgs.docker}/bin/docker pull copyparty/ac:latest
      ${pkgs.docker}/bin/docker pull caddy:alpine
      ${pkgs.docker}/bin/docker pull tailscale/tailscale:latest
      
      echo "Restarting all container stacks to apply updates and refresh sidecars..."
      
      # Immich Stack
      ${pkgs.systemd}/bin/systemctl restart docker-tailscale-immich.service \
                                             docker-immich-server.service \
                                             docker-immich-machine-learning.service \
                                             docker-immich-redis.service \
                                             docker-immich-database.service \
                                             docker-immich-proxy.service

      # Seanime Stack
      ${pkgs.systemd}/bin/systemctl restart docker-tailscale-seanime.service \
                                             docker-seanime.service \
                                             docker-seanime-proxy.service

      # Portainer Stack
      ${pkgs.systemd}/bin/systemctl restart docker-tailscale-portainer.service \
                                             docker-portainer.service \
                                             docker-portainer-proxy.service

      # Copyparty Stack
      ${pkgs.systemd}/bin/systemctl restart docker-tailscale-copyparty.service \
                                             docker-copyparty.service \
                                             docker-copyparty-proxy.service
      
      echo "All containers updated and restarted!"
    '')
  ];

  programs.git = {
    enable = true;
    config = {
      credential.helper = "${pkgs.github-cli}/bin/gh auth git-credential";
    };
  };

  environment.shellAliases = {
    update-containers = "sudo /run/current-system/sw/bin/update-containers";
    disable-power-sync = "sudo /run/current-system/sw/bin/disable-power-sync";
    enable-power-sync = "sudo /run/current-system/sw/bin/enable-power-sync";
    free-win11-ram = "sudo /run/current-system/sw/bin/free-win11-hugepages";
    reboot-to-windows = "sudo /run/current-system/sw/bin/reboot-to-windows";
    nix-deploy = "cd /etc/nixos/nixconf && sudo git pull --ff-only && sudo nixos-rebuild switch --flake .#rishabh-nix && cd -";
  };
}
