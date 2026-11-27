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

  # Samba share for the LAN (10.0.0.0/24), which includes the win11 VM on br0.
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "rishabh-nix Samba";
        "netbios name" = "rishabh-nix";
        "security" = "user";
        "hosts allow" = "10.0.0. 127.";

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
    };
  };

  # Everything that uses /mnt/data4 waits for it and stays down if it can't
  # mount, so nothing serves or writes into the empty mountpoint on the root
  # disk instead.
  systemd.services = lib.genAttrs [
    "samba-smbd"
    "docker-copyparty"
    "docker-immich-server"
    "docker-hokago"
    "docker-hokago-worker"
  ] (_: {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  });

  # Samba requires a user password to be set up manually using `smbpasswd -a rishabh`
}
