{ config, pkgs, ... }:

let
  # HTTPS for each sidecar: https://<app>.<tailnet>.ts.net -> the app's local port.
  # `tailscale serve` is tailnet-only (public exposure would need Funnel, which is never
  # enabled here). Plain http://<app> keeps going through each stack's Caddy proxy on :80
  # (except samechan: HTTPS only, see below).
  tsServe = port: pkgs.writeText "ts-serve-${toString port}.json" (builtins.toJSON {
    TCP."443".HTTPS = true;
    Web."\${TS_CERT_DOMAIN}:443".Handlers."/".Proxy = "http://127.0.0.1:${toString port}";
  });
in
{
  # samechan's container runs as uid 1000 (node) and keeps all its data here
  systemd.tmpfiles.rules = [
    "d /var/lib/samechan 0700 1000 1000 -"
    "d /var/lib/samechan-hindsight 0700 root root -" # Hindsight's Postgres
  ];

  # Enable Docker
  virtualisation.docker.enable = true;
  # Weekly `docker system prune`: stopped containers, dangling images (old
  # tags left behind by update-containers), unused networks, build cache.
  # No --all (would delete images of stacks that are merely stopped, which
  # then re-pull a possibly newer :release on start) and no --volumes.
  virtualisation.docker.autoPrune = {
    enable = true;
    dates = "weekly";
  };
  virtualisation.oci-containers.backend = "docker";

  # Tailscale Sidecars and Services
  # Keep background services on the housekeeping CPUs while the
  # latency-sensitive CPU cores remain available to the Windows guest.
  # Every container runs under one shared slice capped at 400% -- half of
  # the 8 housekeeping logical CPUs, for ALL containers combined (docker's
  # --cpus is per-container, so it couldn't do this). Without it a single
  # library-scan burst (hokago-worker's ffmpeg trickplay sweeps measured at
  # 1236% across these 8 CPUs) can saturate the same cores QEMU's emulator
  # thread and passthrough-device IRQs depend on, starving the VM even
  # though its own isolated cores are untouched.
  systemd.slices.oci-containers.sliceConfig = {
    CPUQuota = "400%";
    AllowedCPUs = "0-3,8-11";
  };
  virtualisation.oci-containers.containers = builtins.mapAttrs (_: container:
    container // {
      extraOptions = (container.extraOptions or []) ++ [ "--cgroup-parent=oci-containers.slice" ];
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
        TS_SERVE_CONFIG = "/config/serve.json";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-immich:/var/lib/tailscale"
        "${tsServe 2283}:/config/serve.json:ro"
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
      environment = {
        # Sidecar containers share tailscale-immich's network namespace,
        # so container-name DNS doesn't resolve -- must use 127.0.0.1.
        IMMICH_MACHINE_LEARNING_URL = "http://127.0.0.1:3003";
      };
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
        "--device=nvidia.com/gpu=all"
      ];
      environmentFiles = [ config.sops.templates."immich.env".path ];
      # v3.3.0+: re-exported (numerically identical) models in an optimized
      # format -- faster, less VRAM, no re-run of jobs needed.
      environment.MACHINE_LEARNING_MODEL_REVISION = "v2";
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
        TS_SERVE_CONFIG = "/config/serve.json";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-hokago:/var/lib/tailscale"
        "${tsServe 3000}:/config/serve.json:ro"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
      # Loopback-only -- 127.0.0.1, never 0.0.0.0 or the LAN IP. A
      # narrower binding than routing through the Tailscale sidecar
      # below: nothing running directly on this host needs to leave the
      # machine to reach a container running on it.
      ports = [ "127.0.0.1:3211:3000" ];
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
      # BullMQ queue is ephemeral — no RDB/AOF persistence needed.
      # Default "save 3600 1" + "stop-writes-on-bgsave-error yes" forks
      # BGSAVE to /data/dump.rdb; with wrong host perms that MISCONFs and
      # blocks all writes (bull:artwork/metadata). Disable persistence and
      # ensure writes are never blocked even if a future BGSAVE fails.
      cmd = [
        "--save"
        ""
        "--appendonly"
        "no"
        "--stop-writes-on-bgsave-error"
        "no"
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
        "--device=nvidia.com/gpu=all"
      ];
      environmentFiles = [ config.sops.templates."hokago.env".path ];
      environment = {
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
        "/mnt/data4/YouTube/Anime:/media/anime:rw"
        "/mnt/data4/YouTube/K-Drama:/media/kdrama:ro"
      ];
    };

    hokago-worker = {
      image = "ghcr.io/rishabhroyy/hokago:latest";
      dependsOn = [ "hokago" ];
      extraOptions = [
        "--network=container:tailscale-hokago"
        "--device=nvidia.com/gpu=all"
      ];
      environmentFiles = [ config.sops.templates."hokago.env".path ];
      environment = {
        VALKEY_URL = "redis://127.0.0.1:6379";
        HOKAGO_CONFIG_DIR = "/config";
      };
      cmd = [ "sh" "-c" "exec node apps/worker/dist/index.js" ];
      volumes = [
        "/var/lib/hokago/config:/config"
        "/mnt/data4/YouTube/Movies:/media/movies:ro"
        "/mnt/data4/YouTube/TV:/media/tv:ro"
        "/mnt/data4/YouTube/Anime:/media/anime:rw"
        "/mnt/data4/YouTube/K-Drama:/media/kdrama:ro"
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
        TS_SERVE_CONFIG = "/config/serve.json";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-portainer:/var/lib/tailscale"
        "${tsServe 9000}:/config/serve.json:ro"
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
        TS_SERVE_CONFIG = "/config/serve.json";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-copyparty:/var/lib/tailscale"
        "${tsServe 3923}:/config/serve.json:ro"
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

    # ---------------------------------------------------------
    # Samechan (private image -- pulled with rishabh's gh login, see
    # samechanDocker in configuration.nix)
    # ---------------------------------------------------------
    tailscale-samechan = {
      image = "tailscale/tailscale:latest";
      environmentFiles = [ config.sops.templates."tailscale.env".path ];
      environment = {
        TS_HOSTNAME = "samechan";
        TS_STATE_DIR = "/var/lib/tailscale";
        TS_SERVE_CONFIG = "/config/serve.json";
      };
      volumes = [
        "/dev/net/tun:/dev/net/tun"
        "/var/lib/tailscale-samechan:/var/lib/tailscale"
        "${tsServe 8787}:/config/serve.json:ro"
      ];
      extraOptions = [
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
    };

    # Local embeddings for samechan (CPU is plenty). samechan pulls the
    # model into it on first use.
    samechan-ollama = {
      image = "ollama/ollama:latest";
      dependsOn = [ "tailscale-samechan" ];
      extraOptions = [
        "--network=container:tailscale-samechan"
      ];
      environment = {
        OLLAMA_HOST = "127.0.0.1:11434";
      };
      volumes = [
        "/var/lib/samechan-ollama:/root/.ollama"
      ];
    };

    # Hindsight's database: Postgres + pgvector. Loopback only inside the
    # sidecar's network, so trust auth (no password to manage).
    samechan-hindsight-db = {
      image = "pgvector/pgvector:pg18";
      dependsOn = [ "tailscale-samechan" ];
      extraOptions = [
        "--network=container:tailscale-samechan"
      ];
      environment = {
        POSTGRES_USER = "hindsight";
        POSTGRES_DB = "hindsight";
        POSTGRES_HOST_AUTH_METHOD = "trust";
      };
      cmd = [ "postgres" "-c" "listen_addresses=127.0.0.1" ];
      volumes = [
        "/var/lib/samechan-hindsight/db:/var/lib/postgresql"
      ];
    };

    # Hindsight: samechan's long-term memory store (API-only image, embedder/reranker baked
    # in, runs offline). Its model calls go to samechan's bridge on 127.0.0.1:8790,
    # which forwards them over NEAR E2EE; one path per job for cost tracking.
    samechan-hindsight = {
      image = "ghcr.io/vectorize-io/hindsight-api:1.2.0";
      dependsOn = [ "tailscale-samechan" "samechan-hindsight-db" ];
      extraOptions = [
        "--network=container:tailscale-samechan"
        "--stop-timeout=75"
      ];
      environment = let bridge = "http://127.0.0.1:8790"; in {
        HINDSIGHT_API_HOST = "127.0.0.1"; # default 0.0.0.0 would be tailnet-exposed
        HINDSIGHT_API_DATABASE_URL = "postgresql://hindsight@127.0.0.1:5432/hindsight";
        HINDSIGHT_API_WORKER_ID = "samechan";
        HINDSIGHT_API_LLM_PROVIDER = "openai";
        HINDSIGHT_API_LLM_API_KEY = "bridge"; # not a secret: loopback-only bridge
        HINDSIGHT_API_LLM_MODEL = "samechan"; # the bridge picks the actual model
        HINDSIGHT_API_LLM_BASE_URL = "${bridge}/memory/v1";
        HINDSIGHT_API_RETAIN_LLM_BASE_URL = "${bridge}/retain/v1";
        HINDSIGHT_API_CONSOLIDATION_LLM_BASE_URL = "${bridge}/observe/v1";
        HINDSIGHT_API_REFLECT_LLM_BASE_URL = "${bridge}/reflect/v1";
        HINDSIGHT_API_MENTAL_MODEL_REFRESH_LLM_BASE_URL = "${bridge}/reflect/v1";
        HINDSIGHT_API_LLM_TIMEOUT = "300";
        HINDSIGHT_API_SKIP_LLM_VERIFICATION = "true";
        HINDSIGHT_API_LLM_TRACE_ENABLED = "false"; # would store prompts
        HINDSIGHT_API_LLM_CACHE_AFFINITY = "none";
        HINDSIGHT_API_MCP_ENABLED = "false";
        HINDSIGHT_API_DEFAULT_TIMEZONE = "America/Los_Angeles";
        HF_HUB_OFFLINE = "1";
        TRANSFORMERS_OFFLINE = "1";
        TZ = "America/Los_Angeles";
      };
    };

    samechan = {
      image = "ghcr.io/rishabhroyy/samechan:latest";
      dependsOn = [ "tailscale-samechan" "samechan-ollama" ];
      extraOptions = [
        "--network=container:tailscale-samechan"
      ];
      environment = {
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/samechan:/data"
      ];
    };

    # No plain-http proxy for samechan: HTTPS via `tailscale serve` only, the one path that
    # sets Tailscale-User-Login, which samechan's optional tailnet lock checks (an :80
    # proxy would pass a forged header straight through).

  };
}
