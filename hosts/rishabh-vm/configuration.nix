{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
    ./services.nix
  ];

  networking = {
    hostName = "rishabh-vm";
    useDHCP = lib.mkDefault true;
    firewall = {
      enable = true;
      checkReversePath = "loose";

      # 80 is intentionally closed. Caddy renews certificates with TLS-ALPN-01
      # over 443. SSH is public as a key-only recovery path.
      allowedTCPPorts = [ 22 443 2022 ];
      allowedUDPPorts = [ 41641 ];
      allowedTCPPortRanges = [{ from = 25565; to = 25575; }];
      allowedUDPPortRanges = [{ from = 25565; to = 25575; }];
    };
    # Keep same-host Panel/Wings traffic local instead of depending on OCI
    # public-IP hairpin behavior.
    hosts."127.0.0.1" = [
      "games.rishabhroy.com"
      "wings.rishabhroy.com"
    ];
  };

  boot = {
    loader.grub = {
      enable = true;
      device = "nodev";
      efiSupport = true;
      efiInstallAsRemovable = true;
      configurationLimit = 10;
    };
    loader.efi.canTouchEfiVariables = false;
    kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
  };

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" "@wheel" ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  system.autoUpgrade = {
    enable = true;
    flake = "github:rishabhroyy/nixconf?dir=hosts/rishabh-vm#rishabh-vm";
    operation = "switch";
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
    dates = "04:15";
    randomizedDelaySec = "30min";
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "rishabh" ];
      X11Forwarding = false;
    };
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
  };

  users.users.rishabh = {
    isNormalUser = true;
    description = "Rishabh";
    extraGroups = [ "wheel" "docker" ];
    hashedPassword = "!";
    openssh.authorizedKeys.keyFiles = [
      ./keys/mac.pub
      ./keys/windows.pub
    ];
  };
  users.groups.pterodactyl = {};
  users.users.pterodactyl = {
    isSystemUser = true;
    group = "pterodactyl";
    home = "/var/lib/pterodactyl";
  };
  security.sudo.wheelNeedsPassword = false;

  services.journald.extraConfig = ''
    SystemMaxUse=2G
    SystemKeepFree=5G
    MaxRetentionSec=30day
  '';

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale_auth_key.path;
    useRoutingFeatures = "server";
    extraUpFlags = [
      "--hostname=rishabh-vm"
      "--advertise-exit-node"
    ];
  };

  sops = {
    defaultSopsFile = ./secrets.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";

    secrets = {
      tailscale_auth_key = {};
      portainer_admin_password = {};
      portainer_oauth_client_secret = {};
      pterodactyl_db_password = {};
      pterodactyl_db_root_password = {};
      pterodactyl_app_key = {};
      pyrodactyl_sso_secret = {};
      pterodactyl_wings_config = {
        mode = "0400";
        restartUnits = [ "pterodactyl-wings.service" ];
      };
      authentik_postgres_password = {};
      authentik_secret_key = {};
      authentik_bootstrap_password = {};
    };

    templates."copyparty.conf" = {
      mode = "0400";
      content = ''
        [global]
          e2dsa
          e2ts
          hist: /cfg/hists/
          idp-h-usr: x-authentik-username
          idp-h-grp: x-authentik-groups
          idp-h-key: x-copyparty-proxy
          idp-store: 3
          no-robots
          rproxy: 1
          shr: /share
          xff-hdr: x-forwarded-for
          xff-src: lan

        [/]
          /w
          accs:
            rwmda: @acct
          flags:
            grid
            shr-who: auth
      '';
    };

    templates."pterodactyl.env" = {
      mode = "0400";
      restartUnits = [ "docker-pyrodactyl-panel.service" ];
      content = ''
        APP_KEY=${config.sops.placeholder.pterodactyl_app_key}
        DB_PASSWORD=${config.sops.placeholder.pterodactyl_db_password}
        MYSQL_PASSWORD=${config.sops.placeholder.pterodactyl_db_password}
        MYSQL_ROOT_PASSWORD=${config.sops.placeholder.pterodactyl_db_root_password}
        PYRODACTYL_SSO_SECRET=${config.sops.placeholder.pyrodactyl_sso_secret}
      '';
    };

    templates."authentik.env" = {
      mode = "0400";
      content = ''
        AUTHENTIK_POSTGRESQL__PASSWORD=${config.sops.placeholder.authentik_postgres_password}
        PG_PASS=${config.sops.placeholder.authentik_postgres_password}
        POSTGRES_PASSWORD=${config.sops.placeholder.authentik_postgres_password}
        AUTHENTIK_SECRET_KEY=${config.sops.placeholder.authentik_secret_key}
        AUTHENTIK_BOOTSTRAP_EMAIL=akadmin@rishabh-vm.invalid
        AUTHENTIK_BOOTSTRAP_PASSWORD=${config.sops.placeholder.authentik_bootstrap_password}
        PORTAINER_OAUTH_CLIENT_SECRET=${config.sops.placeholder.portainer_oauth_client_secret}
      '';
    };

    templates."caddy.env" = {
      mode = "0400";
      restartUnits = [ "caddy.service" ];
      content = ''
        PYRODACTYL_SSO_SECRET=${config.sops.placeholder.pyrodactyl_sso_secret}
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    bash-completion
    bind
    btop
    curl
    docker-compose
    ethtool
    fastfetch
    file
    git
    github-cli
    htop
    inetutils
    iproute2
    jq
    lsof
    nano
    ncdu
    nettools
    nmap
    openssl
    pciutils
    psmisc
    ripgrep
    rsync
    screen
    tmux
    tree
    unzip
    vim
    wget
    zip
  ];

  time.timeZone = "America/Los_Angeles";
  system.stateVersion = "26.05";
}
