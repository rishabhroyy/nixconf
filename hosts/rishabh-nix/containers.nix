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
      image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0";
      dependsOn = [ "tailscale-immich" ];
      extraOptions = [
        "--network=container:tailscale-immich"
        "--shm-size=128mb"
      ];
      labels = { "com.centurylinklabs.watchtower.enable" = "false"; };
      environmentFiles = [ config.sops.templates."immich.env".path ];
      environment = {
        POSTGRES_INITDB_ARGS = "--data-checksums";
      };
      volumes = [
        "/home/rishabh/immich/db:/var/lib/postgresql/data"
      ];
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
    # Hokago
    # ---------------------------------------------------------
    tailscale-hokago = {
      image = "tailscale/tailscale:latest";
      environmentFiles = [ config.sops.templates."tailscale.env".path ];
      environment = {
        TS_HOSTNAME = "hokago";
        TS_STATE_DIR = "/var/lib/tailscale";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-hokago:/var/lib/tailscale"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
      # Map the Hokago port to the host via the Tailscale sidecar
      ports = [ "3211:3000" ];
    };

    hokago-postgres = {
      image = "postgres:17-bookworm";
      dependsOn = [ "tailscale-hokago" ];
      extraOptions = [
        "--network=container:tailscale-hokago"
      ];
      environmentFiles = [ config.sops.templates."hokago.env".path ];
      environment = {
        POSTGRES_USER = "hokago";
        POSTGRES_DB = "hokago";
        PGDATA = "/var/lib/postgresql/data/pgdata";
      };
      volumes = [
        "/var/lib/hokago/db:/var/lib/postgresql/data"
      ];
    };

    hokago-valkey = {
      image = "valkey/valkey:8-bookworm";
      dependsOn = [ "tailscale-hokago" ];
      extraOptions = [
        "--network=container:tailscale-hokago"
      ];
      volumes = [
        "/var/lib/hokago/cache/valkey:/data"
      ];
    };

    # Migrations run before boot (postgres has no tables on first start) --
    # a pre-migrate pg_dump snapshot makes every migration reversible
    # in-place, mirroring hokago's own docker-compose.yml.
    hokago = {
      image = "ghcr.io/rishabhroyy/hokago:latest";
      dependsOn = [ "tailscale-hokago" "hokago-postgres" "hokago-valkey" ];
      extraOptions = [
        "--network=container:tailscale-hokago"
        "--group-add=video"
      ];
      environmentFiles = [ config.sops.templates."hokago.env".path ];
      environment = {
        NVIDIA_VISIBLE_DEVICES = "all";
        NVIDIA_DRIVER_CAPABILITIES = "all";
        VALKEY_URL = "redis://127.0.0.1:6379";
        HOKAGO_CONFIG_DIR = "/config";
        HOKAGO_WEB_ROOT = "/app/web";
        PORT = "3000";
        TZ = "America/Los_Angeles";
        HOKAGO_TRUST_PROXY = "true";
      };
      cmd = [ "sh" "-c" ''mkdir -p /config/db-backups && f=/config/db-backups/pre-migrate-$(date +%Y%m%d-%H%M%S).sql.gz && pg_dump --no-owner "postgresql://hokago:$POSTGRES_PASSWORD@127.0.0.1:5432/hokago" | gzip > "$f"; [ "$(wc -c < "$f")" -gt 100 ] || rm -f "$f"; find /config/db-backups -name 'pre-migrate-*.sql.gz' -mtime +14 -delete; pnpm --filter @hokago/db run migrate:deploy && exec node apps/api/dist/index.js'' ];
      volumes = [
        "/var/lib/hokago/config:/config"
        "/mnt/data4/YouTube/Movies:/media/movies:ro"
        "/mnt/data4/YouTube/TV:/media/tv:ro"
        "/mnt/data4/YouTube/Anime:/media/anime:ro"
      ];
    };

    hokago-worker = {
      image = "ghcr.io/rishabhroyy/hokago:latest";
      dependsOn = [ "hokago" ];
      extraOptions = [
        "--network=container:tailscale-hokago"
        "--group-add=video"
      ];
      environmentFiles = [ config.sops.templates."hokago.env".path ];
      environment = {
        NVIDIA_VISIBLE_DEVICES = "all";
        NVIDIA_DRIVER_CAPABILITIES = "all";
        VALKEY_URL = "redis://127.0.0.1:6379";
        HOKAGO_CONFIG_DIR = "/config";
      };
      cmd = [ "sh" "-c" "exec node apps/worker/dist/index.js" ];
      volumes = [
        "/var/lib/hokago/config:/config"
        "/mnt/data4/YouTube/Movies:/media/movies:ro"
        "/mnt/data4/YouTube/TV:/media/tv:ro"
        "/mnt/data4/YouTube/Anime:/media/anime:ro"
      ];
    };

    hokago-proxy = {
      image = "caddy:alpine";
      dependsOn = [ "tailscale-hokago" ];
      extraOptions = [
        "--network=container:tailscale-hokago"
      ];
      cmd = [ "caddy" "reverse-proxy" "--from" ":80" "--to" "127.0.0.1:3000" ];
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
