{ ... }:

{
  # Ensure the modern ntfs3 driver is supported and used
  boot.supportedFilesystems = [ "ntfs" ];

  # The 1TB SATA SSD has been removed from here and passed directly to the Windows VM.
  # We are only keeping the 4TB HDD (DATA4) on Linux.

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

  # Samba share for the local LAN, including the Windows VM when it is attached
  # through the physical network.
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "rishabh-nix Samba";
        "netbios name" = "rishabh-nix";
        "security" = "user";
        # Allow access from the local LAN (VM will be on the LAN via the physical router)
        "hosts allow" = "192.168. 10. 172.16. 127.";
        
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

  # Do not export an empty directory on the root filesystem when DATA4 is
  # unavailable. The container services that consume this disk use the same
  # fail-closed mount dependency.
  systemd.services.samba-smbd = {
    after = [ "mnt-data4.mount" ];
    requires = [ "mnt-data4.mount" ];
  };

  # Samba requires a user password to be set up manually using `smbpasswd -a rishabh`
}
