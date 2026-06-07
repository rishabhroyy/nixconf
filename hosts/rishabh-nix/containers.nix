{ config, ... }:

{
  # Enable Docker
  virtualisation.docker.enable = true;
  virtualisation.oci-containers.backend = "docker";

  # Tailscale Sidecars and Services
  # Keep background services on the housekeeping CPUs while the
  # latency-sensitive CPU cores remain available to the Windows guest.
  virtualisation.oci-containers.containers = builtins.mapAttrs (_: container:
    container // {
      extraOptions = (container.extraOptions or []) ++ [ "--cpuset-cpus=0-3,8-11" ];
    }
  ) {
    # ---------------------------------------------------------
    # Immich
    # ---------------------------------------------------------
    tailscale-immich = {
      image = "tailscale/tailscale:latest";
      environmentFiles = [ config.sops.templates."tailscale.env".path ];
      environment = {
        TS_HOSTNAME = "immich";
        TS_STATE_DIR = "/var/lib/tailscale";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-immich:/var/lib/tailscale"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
      ports = [ "2283:2283" ];
    };

    immich-server = {
      image = "ghcr.io/immich-app/immich-server:release";
      dependsOn = [ "tailscale-immich" "immich-redis" "immich-database" ];
      extraOptions = [
        "--network=container:tailscale-immich"
      ];
      # Automatically loaded via SOPS Templates from configuration.nix
      environmentFiles = [ config.sops.templates."immich.env".path ];
      volumes = [
        "/home/rishabh/immich/photos:/usr/src/app/upload"
        "/mnt/data4/Photos/Photos/iPhone_Photos:/usr/src/app/external/iphone_photoprism_backup:ro"
        "/mnt/data4/Photos/cameras:/usr/src/app/external/camera_ssd:ro"
      ];
    };

    immich-machine-learning = {
      image = "ghcr.io/immich-app/immich-machine-learning:release-cuda";
      dependsOn = [ "tailscale-immich" ];
      extraOptions = [
        "--network=container:tailscale-immich"
      ];
      environment = {
        NVIDIA_VISIBLE_DEVICES = "all";
        NVIDIA_DRIVER_CAPABILITIES = "all";
      };
      environmentFiles = [ config.sops.templates."immich.env".path ];
      volumes = [
        "/var/lib/immich/model-cache:/cache"
      ];
    };

    immich-redis = {
      image = "registry.hub.docker.com/library/redis:6.2-alpine@sha256:84882e87b54734154586e5f8abd4dce69fe7311315e2fc6d67c29614c8de2672";
      dependsOn = [ "tailscale-immich" ];
      extraOptions = [
        "--network=container:tailscale-immich"
      ];
    };

    immich-database = {
      image = "registry.hub.docker.com/tensorchord/pgvecto-rs:pg14-v0.2.0@sha256:90724186f0a3517cf6914295b5ab410db9ce23190a2d9d0b9dd6463e3fa298f0";
      dependsOn = [ "tailscale-immich" ];
      extraOptions = [
        "--network=container:tailscale-immich"
      ];
      labels = { "com.centurylinklabs.watchtower.enable" = "false"; };
      environmentFiles = [ config.sops.templates."immich.env".path ];
      environment = {
        POSTGRES_INITDB_ARGS = "--data-checksums";
      };
      volumes = [
        "/home/rishabh/immich/db:/var/lib/postgresql/data"
      ];
      cmd = [ "postgres" "-c" "shared_preload_libraries=vectors.so" "-c" "search_path=\"$user\", public, vectors" "-c" "logging_collector=on" "-c" "max_wal_size=2GB" "-c" "shared_buffers=512MB" "-c" "wal_compression=on" ];
    };

    immich-proxy = {
      image = "caddy:alpine";
      dependsOn = [ "tailscale-immich" ];
      extraOptions = [
        "--network=container:tailscale-immich"
      ];
      # Elegantly proxies port 80 to 2283 so you don't have to type the port number
      cmd = [ "caddy" "reverse-proxy" "--from" ":80" "--to" "127.0.0.1:2283" ];
    };

    # ---------------------------------------------------------
    # Seanime
    # ---------------------------------------------------------
    tailscale-seanime = {
      image = "tailscale/tailscale:latest";
      environmentFiles = [ config.sops.templates."tailscale.env".path ];
      environment = {
        TS_HOSTNAME = "seanime";
        TS_STATE_DIR = "/var/lib/tailscale";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-seanime:/var/lib/tailscale"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
      # Map the Seanime port to the host via the Tailscale sidecar
      ports = [ "3211:43211" ];
    };

    seanime = {
      image = "umagistr/seanime:latest-cuda";
      dependsOn = [ "tailscale-seanime" ];
      extraOptions = [
        "--network=container:tailscale-seanime"
        "--group-add=video"
      ];
      environment = {
        NVIDIA_VISIBLE_DEVICES = "all";
        NVIDIA_DRIVER_CAPABILITIES = "all";
        SEANIME_SERVER_HOST = "0.0.0.0";
        SEANIME_SERVER_URL = "http://seanime";
      };
      volumes = [
        "/var/lib/seanime:/home/seanime/.config/Seanime"
        "/mnt/data4/YouTube/Anime:/anime"
        "/mnt/data4/YouTube/seanime_downloads:/downloads"
      ];
    };

    seanime-proxy = {
      image = "caddy:alpine";
      dependsOn = [ "tailscale-seanime" ];
      extraOptions = [
        "--network=container:tailscale-seanime"
      ];
      cmd = [ "caddy" "reverse-proxy" "--from" ":80" "--to" "127.0.0.1:43211" ];
    };

    # ---------------------------------------------------------
    # Portainer
    # ---------------------------------------------------------
    tailscale-portainer = {
      image = "tailscale/tailscale:latest";
      environmentFiles = [ config.sops.templates."tailscale.env".path ];
      environment = {
        TS_HOSTNAME = "portainer";
        TS_STATE_DIR = "/var/lib/tailscale";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-portainer:/var/lib/tailscale"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
    };

    portainer = {
      image = "portainer/portainer-ce:latest";
      dependsOn = [ "tailscale-portainer" ];
      extraOptions = [
        "--network=container:tailscale-portainer"
      ];
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "/var/lib/portainer:/data"
      ];
    };

    portainer-proxy = {
      image = "caddy:alpine";
      dependsOn = [ "tailscale-portainer" ];
      extraOptions = [
        "--network=container:tailscale-portainer"
      ];
      cmd = [ "caddy" "reverse-proxy" "--from" ":80" "--to" "127.0.0.1:9000" ];
    };

    # ---------------------------------------------------------
    # Copyparty
    # ---------------------------------------------------------
    tailscale-copyparty = {
      image = "tailscale/tailscale:latest";
      environmentFiles = [ config.sops.templates."tailscale.env".path ];
      environment = {
        TS_HOSTNAME = "copyparty";
        TS_STATE_DIR = "/var/lib/tailscale";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-copyparty:/var/lib/tailscale"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
    };

    copyparty = {
      image = "copyparty/ac:latest";
      dependsOn = [ "tailscale-copyparty" ];
      extraOptions = [
        "--network=container:tailscale-copyparty"
        "--user=1000:100"
      ];
      environment = {
        PRTY_CONFIG = "/copyparty.conf";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/mnt/data4:/w"
        "/var/lib/copyparty:/cfg"
        "${config.sops.templates."copyparty.conf".path}:/copyparty.conf:ro"
      ];
    };

    copyparty-proxy = {
      image = "caddy:alpine";
      dependsOn = [ "tailscale-copyparty" ];
      extraOptions = [
        "--network=container:tailscale-copyparty"
      ];
      cmd = [ "caddy" "reverse-proxy" "--from" ":80" "--to" "127.0.0.1:3923" ];
    };

  };
}
