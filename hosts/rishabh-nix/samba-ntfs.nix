{ lib, ... }:

{
  # Ensure the modern ntfs3 driver is supported and used
  boot.supportedFilesystems = [ "ntfs" ];

  fileSystems."/mnt/data4" = {
    # 4TB HDD UUID
    device = "/dev/disk/by-uuid/4074A28D74A2856E";
    fsType = "ntfs3";
    options = [
      "rw"
      "uid=1000"
      "gid=100"
      "umask=000"
      "prealloc"
      "nofail"
    ];
  };

  # 1TB SanDisk SATA SSD (host-owned ASMedia controller): Immich data, AI
  # models, and Windows game installs over the Samba share below.
  fileSystems."/mnt/ssd" = {
    device = "/dev/disk/by-label/ssd";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  # Samba is only for the win11 VM (10.0.0.2, its DHCP reservation) and the
  # host itself; other LAN and tailnet devices use copyparty instead.
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "rishabh-nix Samba";
        "netbios name" = "rishabh-nix";
        "security" = "user";
        "hosts allow" = "10.0.0.2 127.";

        # --- High Performance HDD / Gaming Optimizations ---
        "server multi channel support" = "yes";
        "server min protocol" = "SMB3";
        "server signing" = "mandatory"; # Enforced for security, at the cost of some CPU overhead
        "strict locking" = "no";
        "strict allocate" = "yes";
        "aio read size" = "1";
        "aio write size" = "1";
        "use sendfile" = "yes";
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY";
      };

      # Export the whole 4TB HDD so it is easily visible in Windows
      "data4" = {
        "path" = "/mnt/data4";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "valid users" = "rishabh";
      };

      "ssd" = {
        "path" = "/mnt/ssd";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "create mask" = "0644";
        "directory mask" = "0755";
        "valid users" = "rishabh";
      };
    };
  };

  # Everything that uses /mnt/data4 or /mnt/ssd waits for it and stays down if
  # it can't mount, so nothing serves or writes into an empty mountpoint on
  # the root disk instead.
  systemd.services = lib.mapAttrs (_: mounts: { after = mounts; requires = mounts; }) {
    samba-smbd = [ "mnt-data4.mount" "mnt-ssd.mount" ];
    docker-copyparty = [ "mnt-data4.mount" "mnt-ssd.mount" ];
    docker-immich-server = [ "mnt-data4.mount" "mnt-ssd.mount" ];
    docker-immich-machine-learning = [ "mnt-ssd.mount" ];
    docker-hokago = [ "mnt-data4.mount" ];
    docker-hokago-worker = [ "mnt-data4.mount" ];
  };

  # Samba requires a user password to be set up manually using `smbpasswd -a rishabh`
}
