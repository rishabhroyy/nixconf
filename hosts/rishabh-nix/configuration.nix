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

  # The 2.5GbE NIC (10ec:8125, PCI 0000:29:00.0, enp41s0) is host-owned and
  # bridged as br0 so NixOS and the win11 VM can both use it at once -- the
  # VM gets a virtio-net interface on the same bridge instead of raw PCI
  # passthrough (see win11-template.xml). br0's MAC is pinned to the old 1G
  # NIC's MAC so the router's existing DHCP reservation for 10.0.0.3 keeps
  # matching without touching the router. The 1G NIC (enp39s0) is unused now.
  #
  # enp41s0 is this board's predictable name for 0000:29:00.0 (bus 0x29 =
  # 41 decimal) -- verify with `ip link` after the first boot with the NIC
  # off vfio-pci, since it never had a chance to enumerate under that name
  # while it was passed through.
  #
  # enp41s0's own software MAC is deliberately overridden away from its real
  # hardware MAC (14:5d:34:c1:14:5e -> 16:5d:34:c1:14:5e, locally-
  # administered bit set). A bridge slave port with an IP-less, DHCP-less
  # role never actually transmits under its own MAC, so this override is
  # invisible on the wire -- but it frees up the real MAC so win11's
  # virtio-net interface (win11-template.xml) can use it directly, without
  # colliding with the bridge's automatic "permanent, local" fdb entry for
  # enp41s0's own address (that collision is what silently blackholed all
  # inbound guest traffic before this). With the real MAC now exclusively
  # the VM's, the router's existing DHCP reservation for 10.0.0.2 keeps
  # matching with no router-side changes and no static IP in Windows.
  #
  # networking.interfaces.enp41s0.macAddress did NOT apply this reliably in
  # practice (verified live: enp41s0 still came up on its real MAC after a
  # full reboot with that option set) -- ordering against bridge
  # enslavement, most likely. An explicit oneshot doing the same down/
  # set-address/up cycle that fixed it live works regardless of ordering
  # (proven: it also works run manually against an already-enslaved port),
  # so that's what's actually relied on here instead of the declarative
  # option.
  networking.useDHCP = false;
  networking.interfaces.enp39s0.useDHCP = false;
  systemd.services.set-enp41s0-mac = {
    description = "Override enp41s0's MAC so win11's virtio-net can use the real one";
    before = [ "network-addresses-br0.service" "network-link-enp41s0.service" ];
    wantedBy = [ "multi-user.target" "network-addresses-br0.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.iproute2}/bin/ip link set enp41s0 down
      ${pkgs.iproute2}/bin/ip link set enp41s0 address 16:5d:34:c1:14:5e
      ${pkgs.iproute2}/bin/ip link set enp41s0 up
    '';
  };
  networking.bridges.br0.interfaces = [ "enp41s0" ];
  networking.interfaces.br0 = {
    useDHCP = true;
    macAddress = "d8:bb:c1:42:9c:09";
  };
  # WoL is matched against the NIC's burned-in firmware MAC while the
  # machine is fully off, independent of any software MAC override applied
  # above while the OS is running.
  networking.interfaces.enp41s0.wakeOnLan.enable = true;

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
  sops.secrets.hokago_db_password = {};
  sops.secrets.copyparty_password = {};
  sops.secrets.signal_phone_number = {};

  # Hermes's 4 vCPUs are unpinned QEMU threads on the same 8-thread shared
  # pool (cores 0-3/8-11) as every container and the host itself -- Windows
  # is safe (isolcpus + systemd.cpu_affinity keep it off cores 4-7/12-15
  # entirely), but nothing stops Hermes from crowding out Immich/Hokago/etc
  # under load. Lower cgroup weight (default is 100) lets it still burst to
  # all 4 vCPUs when the pool is idle, but yields under contention instead
  # of starving containers.
  systemd.services."microvm@hermes".serviceConfig.CPUWeight = 50;

  # Copy secrets (decrypted above, host-side, from the same secrets.yaml as
  # everything else) into the directory shared with the hermes microvm. The
  # guest never gets a decryption key of its own, so a compromised agent
  # there can only read these plaintext values, not the rest of this file.
  # tailscale_auth_key is the same reusable key the host itself uses.
  # signal_phone_number backs the signal-cli-daemon service in hermes.nix --
  # kept out of the tracked hermes.nix file after it got committed there and
  # pushed to a public repo.
  #
  # Deliberately not syncing a hermes_env/API-key secret here -- Hermes
  # agent config is unmanaged (see hosts/rishabh-nix/microvms/hermes.nix),
  # configured by hand via `hermes setup` inside the guest, so there's
  # nothing declarative to feed it.
  systemd.services.hermes-secrets-sync = {
    description = "Copy secrets into the shared microvm directory";
    before = [ "microvm@hermes.service" ];
    requiredBy = [ "microvm@hermes.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      install -d -m 0711 /var/lib/microvms/hermes/secrets
      install -m 0400 ${config.sops.secrets.tailscale_auth_key.path} /var/lib/microvms/hermes/secrets/tailscale_auth_key
      install -m 0444 ${config.sops.secrets.signal_phone_number.path} /var/lib/microvms/hermes/secrets/signal_phone_number
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

  sops.templates."hokago.env".content = ''
    POSTGRES_PASSWORD=${config.sops.placeholder.hokago_db_password}
    DATABASE_URL=postgresql://hokago:${config.sops.placeholder.hokago_db_password}@127.0.0.1:5432/hokago
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
    "d /var/lib/hokago/config 0755 root root -"
    "d /var/lib/hokago/db 0755 root root -"
    # valkey/valkey:8-bookworm runs as 999:valkey and BGSAVEs to /data/dump.rdb
    # (bind-mounted from /var/lib/hokago/cache/valkey). root:root 0755 causes
    # "Failed opening temp-1702.rdb: Permission denied" + MISCONF stop-writes
    # that blocks BullMQ (bull:artwork/metadata). Queue is ephemeral — no
    # persistence needed — but fix perms anyway and disable RDB below.
    "d /var/lib/hokago/cache/valkey 0750 999 999 -"
    "Z /var/lib/hokago/cache/valkey 0750 999 999 -"
    "d /var/lib/tailscale-immich 0755 root root -"
    "d /var/lib/tailscale-hokago 0755 root root -"
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

  systemd.services.docker-hokago = lib.mkIf (!recoveryMode) {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  };

  systemd.services.docker-hokago-worker = lib.mkIf (!recoveryMode) {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  };

  # Valkey runs as 999:valkey. tmpfiles Z fixes perms on boot, but a
  # nixos-rebuild that only recreates the dir as root:root (fresh cache)
  # needs an immediate chown before the container starts, otherwise the
  # first BGSAVE fails and stop-writes-on-bgsave-error=y blocks BullMQ.
  systemd.services.docker-hokago-valkey = lib.mkIf (!recoveryMode) {
    serviceConfig.ExecStartPre = [
      "-${pkgs.coreutils}/bin/chown 999:999 /var/lib/hokago/cache/valkey"
      "-${pkgs.coreutils}/bin/chmod 0750 /var/lib/hokago/cache/valkey"
    ];
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
      ${pkgs.docker}/bin/docker pull ghcr.io/rishabhroyy/hokago:latest
      ${pkgs.docker}/bin/docker pull postgres:17-bookworm
      ${pkgs.docker}/bin/docker pull valkey/valkey:8-bookworm
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

      # Hokago Stack
      ${pkgs.systemd}/bin/systemctl restart docker-tailscale-hokago.service \
                                             docker-hokago-postgres.service \
                                             docker-hokago-valkey.service \
                                             docker-hokago.service \
                                             docker-hokago-worker.service \
                                             docker-hokago-proxy.service

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
    (pkgs.writeShellScriptBin "stop-hermes" ''
      set -euo pipefail
      ${pkgs.systemd}/bin/systemctl stop microvm@hermes.service
    '')
    (pkgs.writeShellScriptBin "start-hermes" ''
      set -euo pipefail
      ${pkgs.systemd}/bin/systemctl start microvm@hermes.service
    '')
    (pkgs.writeShellScriptBin "stop-hokago" ''
      set -euo pipefail
      ${pkgs.systemd}/bin/systemctl stop docker-hokago-proxy.service \
                                          docker-hokago-worker.service \
                                          docker-hokago.service \
                                          docker-hokago-valkey.service \
                                          docker-hokago-postgres.service \
                                          docker-tailscale-hokago.service
    '')
    (pkgs.writeShellScriptBin "start-hokago" ''
      set -euo pipefail
      ${pkgs.systemd}/bin/systemctl start docker-tailscale-hokago.service \
                                           docker-hokago-postgres.service \
                                           docker-hokago-valkey.service \
                                           docker-hokago.service \
                                           docker-hokago-worker.service \
                                           docker-hokago-proxy.service
    '')
    (pkgs.writeShellScriptBin "stop-immich" ''
      set -euo pipefail
      ${pkgs.systemd}/bin/systemctl stop docker-immich-proxy.service \
                                          docker-immich-server.service \
                                          docker-immich-machine-learning.service \
                                          docker-immich-redis.service \
                                          docker-immich-database.service \
                                          docker-tailscale-immich.service
    '')
    (pkgs.writeShellScriptBin "start-immich" ''
      set -euo pipefail
      ${pkgs.systemd}/bin/systemctl start docker-tailscale-immich.service \
                                           docker-immich-database.service \
                                           docker-immich-redis.service \
                                           docker-immich-machine-learning.service \
                                           docker-immich-server.service \
                                           docker-immich-proxy.service
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
    stop-hermes = "sudo /run/current-system/sw/bin/stop-hermes";
    start-hermes = "sudo /run/current-system/sw/bin/start-hermes";
    stop-hokago = "sudo /run/current-system/sw/bin/stop-hokago";
    start-hokago = "sudo /run/current-system/sw/bin/start-hokago";
    stop-immich = "sudo /run/current-system/sw/bin/stop-immich";
    start-immich = "sudo /run/current-system/sw/bin/start-immich";
  };
}
