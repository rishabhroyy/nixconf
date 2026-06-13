{ config, lib, pkgs, ... }:

let
  authentikImage = "ghcr.io/goauthentik/server:2026.5";
  wingsAsset = "wings_linux_amd64";

  authentikForwardAuth = ''
    reverse_proxy /outpost.goauthentik.io/* 127.0.0.1:9001
    forward_auth 127.0.0.1:9001 {
      uri /outpost.goauthentik.io/auth/caddy
      copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Entitlements X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt X-Authentik-Meta-Jwks X-Authentik-Meta-Outpost X-Authentik-Meta-Provider X-Authentik-Meta-App X-Authentik-Meta-Version
      trusted_proxies private_ranges
    }
  '';

  securityHeaders = ''
    header {
      Strict-Transport-Security "max-age=31536000"
      X-Content-Type-Options "nosniff"
      X-Frame-Options "SAMEORIGIN"
      Referrer-Policy "strict-origin-when-cross-origin"
      -Server
    }
  '';
in
{
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      live-restore = true;
      log-driver = "journald";
    };
  };
  virtualisation.oci-containers.backend = "docker";

  # Docker installs forwarding rules ahead of the normal host firewall. Keep
  # Wings-created game containers inside the explicitly approved public range.
  systemd.services.docker-public-port-policy = {
    description = "Restrict public traffic forwarded into Docker";
    wantedBy = [ "multi-user.target" "docker.service" ];
    partOf = [ "docker.service" ];
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      iptables=${pkgs.iptables}/bin/iptables
      "$iptables" -N DOCKER-USER 2>/dev/null || true
      "$iptables" -F DOCKER-USER
      "$iptables" -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      "$iptables" -A DOCKER-USER -i docker+ -j ACCEPT
      "$iptables" -A DOCKER-USER -i br+ -j ACCEPT
      "$iptables" -A DOCKER-USER -i tailscale0 -j ACCEPT
      "$iptables" -A DOCKER-USER -p tcp --dport 25565:25575 -j ACCEPT
      "$iptables" -A DOCKER-USER -p udp --dport 25565:25575 -j ACCEPT
      "$iptables" -A DOCKER-USER -j DROP
    '';
  };

  systemd.services.create-app-networks = {
    description = "Create private Docker networks";
    wantedBy = [ "multi-user.target" "docker.service" ];
    partOf = [ "docker.service" ];
    before = map (name: "docker-${name}.service") [
      "authentik-postgres"
      "authentik-server"
      "authentik-worker"
      "pterodactyl-mariadb"
      "pterodactyl-redis"
      "pyrodactyl-panel"
    ];
    requires = [ "docker.service" "docker-public-port-policy.service" ];
    after = [ "docker.service" "docker-public-port-policy.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.docker}/bin/docker network inspect authentik >/dev/null 2>&1 ||
        ${pkgs.docker}/bin/docker network create authentik
      ${pkgs.docker}/bin/docker network inspect pterodactyl >/dev/null 2>&1 ||
        ${pkgs.docker}/bin/docker network create pterodactyl
    '';
  };

  virtualisation.oci-containers.containers = {
    portainer = {
      image = "portainer/portainer-ce:latest";
      ports = [ "127.0.0.1:9000:9000" ];
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "/var/lib/portainer:/data"
        "/run/portainer/admin-password-hash:/run/secrets/portainer_admin_password_hash:ro"
      ];
      cmd = [ "--admin-password-file=/run/secrets/portainer_admin_password_hash" ];
    };

    copyparty = {
      image = "copyparty/ac:latest";
      ports = [ "127.0.0.1:3923:3923" ];
      environment = {
        PRTY_CONFIG = "/copyparty.conf";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/srv/copyparty:/w"
        "/var/lib/copyparty:/cfg"
        "${config.sops.templates."copyparty.conf".path}:/copyparty.conf:ro"
      ];
    };

    pterodactyl-mariadb = {
      image = "mariadb:11.4";
      cmd = [ "--default-authentication-plugin=mysql_native_password" ];
      environmentFiles = [ config.sops.templates."pterodactyl.env".path ];
      environment = {
        MYSQL_DATABASE = "panel";
        MYSQL_USER = "pterodactyl";
      };
      volumes = [ "/var/lib/pterodactyl/database:/var/lib/mysql" ];
      extraOptions = [
        "--network=pterodactyl"
        "--health-cmd=healthcheck.sh --connect --innodb_initialized"
        "--health-interval=15s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=60s"
      ];
    };

    pterodactyl-redis = {
      image = "redis:7-alpine";
      volumes = [ "/var/lib/pterodactyl/redis:/data" ];
      extraOptions = [
        "--network=pterodactyl"
        "--health-cmd=redis-cli ping"
        "--health-interval=15s"
        "--health-timeout=5s"
        "--health-retries=10"
      ];
    };

    pyrodactyl-panel = {
      image = "ghcr.io/pyrodactyl-oss/pyrodactyl:latest";
      dependsOn = [ "pterodactyl-mariadb" "pterodactyl-redis" ];
      ports = [ "127.0.0.1:8081:80" ];
      cmd = [ "/bin/ash" "/pyrodactyl-sso/install.sh" ];
      environmentFiles = [ config.sops.templates."pterodactyl.env".path ];
      environment = {
        APP_URL = "https://games.rishabhroy.com";
        APP_TIMEZONE = "America/Los_Angeles";
        APP_ENV = "production";
        APP_ENVIRONMENT_ONLY = "false";
        DB_CONNECTION = "mariadb";
        HASHIDS_LENGTH = "8";
        CACHE_DRIVER = "redis";
        SESSION_DRIVER = "redis";
        QUEUE_DRIVER = "redis";
        MAIL_DRIVER = "log";
        MAIL_MAILER = "log";
        PTERODACTYL_SEND_INSTALL_NOTIFICATION = "false";
        PTERODACTYL_SEND_REINSTALL_NOTIFICATION = "false";
        REDIS_HOST = "pterodactyl-redis";
        DB_HOST = "pterodactyl-mariadb";
        DB_PORT = "3306";
        DB_DATABASE = "panel";
        DB_USERNAME = "pterodactyl";
        TRUSTED_PROXIES = "*";
      };
      volumes = [
        "/var/lib/pterodactyl/panel-var:/app/var"
        "/var/lib/pterodactyl/panel-logs:/app/storage/logs"
        "${./pyrodactyl-sso/AuthentikSso.php}:/app/app/Http/Middleware/AuthentikSso.php:ro"
        "${./pyrodactyl-sso/install.sh}:/pyrodactyl-sso/install.sh:ro"
      ];
      extraOptions = [
        "--network=pterodactyl"
        "--add-host=wings.rishabhroy.com:host-gateway"
      ];
    };

    authentik-postgres = {
      image = "postgres:16-alpine";
      environmentFiles = [ config.sops.templates."authentik.env".path ];
      environment = {
        POSTGRES_DB = "authentik";
        POSTGRES_USER = "authentik";
      };
      volumes = [ "/var/lib/authentik/postgres:/var/lib/postgresql/data" ];
      extraOptions = [
        "--network=authentik"
        "--health-cmd=pg_isready -U authentik -d authentik"
        "--health-interval=15s"
        "--health-timeout=5s"
        "--health-retries=10"
        "--health-start-period=60s"
      ];
    };

    authentik-server = {
      image = authentikImage;
      dependsOn = [ "authentik-postgres" ];
      cmd = [ "server" ];
      ports = [ "127.0.0.1:9001:9000" ];
      environmentFiles = [ config.sops.templates."authentik.env".path ];
      environment = {
        AUTHENTIK_POSTGRESQL__HOST = "authentik-postgres";
        AUTHENTIK_POSTGRESQL__USER = "authentik";
        AUTHENTIK_POSTGRESQL__NAME = "authentik";
      };
      volumes = [
        "/var/lib/authentik/data:/data"
        "/var/lib/authentik/templates:/templates"
      ];
      extraOptions = [ "--network=authentik" "--shm-size=512m" ];
    };

    authentik-worker = {
      image = authentikImage;
      dependsOn = [ "authentik-postgres" ];
      cmd = [ "worker" ];
      environmentFiles = [ config.sops.templates."authentik.env".path ];
      environment = {
        AUTHENTIK_POSTGRESQL__HOST = "authentik-postgres";
        AUTHENTIK_POSTGRESQL__USER = "authentik";
        AUTHENTIK_POSTGRESQL__NAME = "authentik";
      };
      volumes = [
        "/var/lib/authentik/data:/data"
        "/var/lib/authentik/certs:/certs"
        "/var/lib/authentik/templates:/templates"
        "${./authentik-blueprint.yaml}:/blueprints/custom/rishabh-vm.yaml:ro"
      ];
      extraOptions = [ "--network=authentik" "--shm-size=512m" ];
    };

  };

  systemd.services.portainer-admin-password = {
    description = "Generate Portainer's bcrypt bootstrap password";
    wantedBy = [ "multi-user.target" ];
    before = [ "docker-portainer.service" ];
    requiredBy = [ "docker-portainer.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.apacheHttpd pkgs.coreutils ];
    script = ''
      set -eu
      install -d -m 0700 /run/portainer
      ${pkgs.apacheHttpd}/bin/htpasswd -nbB admin "$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.portainer_admin_password.path})" |
        ${pkgs.coreutils}/bin/cut -d: -f2- > /run/portainer/admin-password-hash
      chmod 0400 /run/portainer/admin-password-hash
    '';
  };

  systemd.services.configure-portainer-oauth = {
    description = "Configure Portainer CE native OAuth against Authentik";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker-portainer.service" "docker-authentik-server.service" "network-online.target" ];
    requires = [ "docker-portainer.service" "docker-authentik-server.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    script = ''
      set -eu

      ready=false
      for attempt in $(seq 1 60); do
        if curl --fail --silent http://127.0.0.1:9000/api/status >/dev/null; then
          ready=true
          break
        fi
        sleep 5
      done
      "$ready" || {
        echo "Portainer did not become ready" >&2
        exit 1
      }

      password="$(cat ${config.sops.secrets.portainer_admin_password.path})"
      client_secret="$(cat ${config.sops.secrets.portainer_oauth_client_secret.path})"
      token="$(curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data "$(jq -nc --arg password "$password" '{username:"admin", password:$password}')" \
        http://127.0.0.1:9000/api/auth | jq -er .jwt)"

      payload="$(jq -nc --arg secret "$client_secret" '{
        AuthenticationMethod: 3,
        ForceSecureCookies: true,
        OAuthSettings: {
          ClientID: "rishabh-vm-portainer",
          ClientSecret: $secret,
          AccessTokenURI: "https://auth.rishabhroy.com/application/o/token/",
          AuthorizationURI: "https://auth.rishabhroy.com/application/o/authorize/",
          ResourceURI: "https://auth.rishabhroy.com/application/o/userinfo/",
          RedirectURI: "https://docker.rishabhroy.com/",
          UserIdentifier: "preferred_username",
          Scopes: "openid profile email",
          OAuthAutoCreateUsers: true,
          DefaultTeamID: 0,
          SSO: true,
          LogoutURI: "https://auth.rishabhroy.com/application/o/portainer/end-session/",
          AuthStyle: 0
        }
      }')"

      curl --fail --silent --show-error --request PUT \
        --header "Authorization: Bearer $token" \
        --header 'Content-Type: application/json' \
        --data "$payload" \
        http://127.0.0.1:9000/api/settings >/dev/null
    '';
  };

  systemd.timers.configure-portainer-oauth = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };

  systemd.services.promote-portainer-sso-admin = {
    description = "Promote the Authentik bootstrap identity in Portainer";
    after = [ "docker-portainer.service" "configure-portainer-oauth.service" ];
    requires = [ "docker-portainer.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    script = ''
      set -eu

      password="$(cat ${config.sops.secrets.portainer_admin_password.path})"
      token="$(curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data "$(jq -nc --arg password "$password" '{username:"admin", password:$password}')" \
        http://127.0.0.1:9000/api/auth | jq -er .jwt)"
      user="$(curl --fail --silent --show-error \
        --header "Authorization: Bearer $token" \
        http://127.0.0.1:9000/api/users |
        jq -c '[.[] | select(.Username == "akadmin")] | first // {}')"
      test "$(printf '%s' "$user" | jq -r '.Id // empty')" != "" || exit 0
      test "$(printf '%s' "$user" | jq -r .Role)" = 1 && exit 0

      id="$(printf '%s' "$user" | jq -r .Id)"
      curl --fail --silent --show-error --request PUT \
        --header "Authorization: Bearer $token" \
        --header 'Content-Type: application/json' \
        --data '{"Username":"akadmin","Role":1}' \
        "http://127.0.0.1:9000/api/users/$id" >/dev/null
    '';
  };

  systemd.timers.promote-portainer-sso-admin = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "5m";
      Persistent = true;
    };
  };

  systemd.services.update-app-containers = {
    description = "Pull application images and restart changed containers";
    after = [ "docker.service" "network-online.target" ];
    requires = [ "docker.service" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.docker pkgs.systemd pkgs.coreutils pkgs.curl ];
    script = ''
      set -eu

      pending=/var/lib/rishabh-vm/update-pending
      mkdir -p "$pending"

      wait_healthy() {
        name="$1"
        attempts=0
        while [ "$attempts" -lt 60 ]; do
          status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$name" 2>/dev/null || true)"
          case "$status" in
            healthy|running) return 0 ;;
          esac
          attempts=$((attempts + 1))
          sleep 5
        done
        echo "$name did not become healthy" >&2
        return 1
      }

      wait_http() {
        name="$1"
        url="$2"
        attempts=0
        while [ "$attempts" -lt 60 ]; do
          code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "$url" || true)"
          case "$code" in
            2*|3*|4*) return 0 ;;
          esac
          attempts=$((attempts + 1))
          sleep 5
        done
        echo "$name did not become ready" >&2
        return 1
      }

      pull_failed=false
      pull_image() {
        image="$1"
        marker="$2"
        before="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
        if ! docker pull "$image"; then
          pull_failed=true
          return
        fi
        after="$(docker image inspect --format '{{.Id}}' "$image")"
        if [ "$before" != "$after" ]; then
          touch "$pending/$marker"
        fi
      }

      pull_image portainer/portainer-ce:latest portainer
      pull_image copyparty/ac:latest copyparty
      pull_image mariadb:11.4 pterodactyl-mariadb
      pull_image redis:7-alpine pterodactyl-redis
      pull_image ghcr.io/pyrodactyl-oss/pyrodactyl:latest pyrodactyl-panel
      pull_image postgres:16-alpine authentik-postgres
      pull_image ${authentikImage} authentik

      for marker in "$pending"/*; do
        if [ -e "$marker" ]; then
          systemctl start backup-app-databases.service
          break
        fi
      done

      if [ -e "$pending/pterodactyl-mariadb" ]; then
        touch "$pending/pyrodactyl-panel"
        systemctl restart docker-pterodactyl-mariadb.service
        wait_healthy pterodactyl-mariadb
        rm -f "$pending/pterodactyl-mariadb"
      fi
      if [ -e "$pending/pterodactyl-redis" ]; then
        touch "$pending/pyrodactyl-panel"
        systemctl restart docker-pterodactyl-redis.service
        wait_healthy pterodactyl-redis
        rm -f "$pending/pterodactyl-redis"
      fi
      if [ -e "$pending/pyrodactyl-panel" ]; then
        systemctl restart docker-pyrodactyl-panel.service
        wait_http pyrodactyl-panel http://127.0.0.1:8081/
        rm -f "$pending/pyrodactyl-panel"
      fi
      if [ -e "$pending/authentik-postgres" ]; then
        touch "$pending/authentik"
        systemctl restart docker-authentik-postgres.service
        wait_healthy authentik-postgres
        rm -f "$pending/authentik-postgres"
      fi
      if [ -e "$pending/authentik" ]; then
        systemctl restart docker-authentik-server.service docker-authentik-worker.service
        wait_http authentik-server http://127.0.0.1:9001/-/health/ready/
        rm -f "$pending/authentik"
      fi
      if [ -e "$pending/portainer" ]; then
        systemctl restart docker-portainer.service
        wait_http portainer http://127.0.0.1:9000/api/status
        rm -f "$pending/portainer"
      fi
      if [ -e "$pending/copyparty" ]; then
        systemctl restart docker-copyparty.service
        wait_http copyparty http://127.0.0.1:3923/
        rm -f "$pending/copyparty"
      fi

      if "$pull_failed"; then
        echo "One or more image pulls failed; successful updates were still applied" >&2
        exit 1
      fi
    '';
  };

  systemd.timers.update-app-containers = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  # Generic `docker system prune` also deletes stopped game-server containers.
  # Only remove images and build cache that no container still references.
  systemd.services.rishabh-vm-docker-prune = {
    description = "Prune unused Docker images and build cache";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.docker ];
    script = ''
      set -eu
      docker image prune --all --force --filter=until=720h
      docker builder prune --all --force --filter=until=720h
    '';
  };

  systemd.timers.rishabh-vm-docker-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  systemd.services.backup-app-databases = {
    description = "Create local application database backups";
    after = [ "docker-pterodactyl-mariadb.service" "docker-authentik-postgres.service" ];
    requires = [ "docker-pterodactyl-mariadb.service" "docker-authentik-postgres.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.docker pkgs.gzip pkgs.findutils pkgs.coreutils pkgs.gnutar ];
    script = ''
      set -eu
      stamp="$(date --utc +%Y%m%dT%H%M%SZ)"
      destination="/var/backups/rishabh-vm/$stamp"
      mkdir -p "$destination"

      docker exec pterodactyl-mariadb sh -c \
        'exec mariadb-dump -upterodactyl -p"$MYSQL_PASSWORD" panel' \
        | gzip > "$destination/pyrodactyl-panel.sql.gz"
      docker exec authentik-postgres pg_dump -U authentik authentik \
        | gzip > "$destination/authentik.sql.gz"
      tar -C /var/lib -czf "$destination/service-config.tar.gz" \
        authentik/certs authentik/data copyparty portainer pterodactyl/panel-var

      find /var/backups/rishabh-vm -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf -- {} +
    '';
  };

  systemd.timers.backup-app-databases = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:30:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /srv/copyparty 0750 1000 100 -"
    "d /var/backups/rishabh-vm 0700 root root -"
    "d /var/lib/rishabh-vm 0700 root root -"
    "d /var/lib/rishabh-vm/update-pending 0700 root root -"
    "d /var/lib/copyparty 0750 1000 100 -"
    "d /var/lib/portainer 0700 root root -"
    "d /var/lib/pterodactyl 0700 root root -"
    "d /var/lib/pterodactyl/wings 0700 root root -"
    "d /var/lib/pterodactyl/wings/bin 0700 root root -"
    "d /var/lib/pterodactyl/wings/config 0700 root root -"
    "d /var/lib/pterodactyl/archives 0700 root root -"
    "d /var/lib/pterodactyl/backups 0700 root root -"
    "d /var/lib/pterodactyl/volumes 0700 root root -"
    "d /var/log/pterodactyl 0700 root root -"
    "d /tmp/pterodactyl 0700 root root -"
    "d /var/lib/authentik 0700 root root -"
    "d /var/lib/authentik/certs 0700 root root -"
    "d /var/lib/authentik/data 0700 root root -"
    "d /var/lib/authentik/postgres 0700 root root -"
    "d /var/lib/authentik/templates 0700 root root -"
  ];

  systemd.services.pterodactyl-wings-update = {
    description = "Install the latest verified official Pterodactyl Wings release";
    wantedBy = [ "multi-user.target" ];
    before = [ "pterodactyl-wings.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -eu
      destination=/var/lib/pterodactyl/wings/bin/wings
      temporary="$(mktemp)"
      trap 'rm -f "$temporary"' EXIT

      release="$(${pkgs.curl}/bin/curl --fail --silent --show-error --location --retry 5 \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/pterodactyl/wings/releases/latest)"
      url="$(printf '%s' "$release" | ${pkgs.jq}/bin/jq -er '.assets[] | select(.name == "${wingsAsset}") | .browser_download_url')"
      digest="$(printf '%s' "$release" | ${pkgs.jq}/bin/jq -er '.assets[] | select(.name == "${wingsAsset}") | .digest | sub("^sha256:"; "")')"

      ${pkgs.curl}/bin/curl --fail --location --retry 5 --output "$temporary" "$url"
      printf '%s  %s\n' "$digest" "$temporary" | ${pkgs.coreutils}/bin/sha256sum --check -
      chmod 0755 "$temporary"
      "$temporary" version
      if ! test -e "$destination" || ! ${pkgs.diffutils}/bin/cmp -s "$temporary" "$destination"; then
        was_active=false
        if ${pkgs.systemd}/bin/systemctl is-active --quiet pterodactyl-wings.service; then
          was_active=true
        fi
        if test -e "$destination"; then
          install -m 0755 "$destination" "$destination.previous"
        fi
        install -m 0755 "$temporary" "$destination"
        if "$was_active"; then
          ${pkgs.systemd}/bin/systemctl restart pterodactyl-wings.service || true
          sleep 15
          if ! ${pkgs.systemd}/bin/systemctl is-active --quiet pterodactyl-wings.service; then
            echo "new Wings release failed to stay active; restoring previous binary" >&2
            install -m 0755 "$destination.previous" "$destination"
            ${pkgs.systemd}/bin/systemctl restart pterodactyl-wings.service
            exit 1
          fi
        fi
      fi
    '';
  };

  systemd.timers.pterodactyl-wings-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:45:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  systemd.services.pterodactyl-wings = {
    description = "Pterodactyl Wings";
    wantedBy = [ "multi-user.target" ];
    after = [
      "docker.service"
      "docker-public-port-policy.service"
      "network-online.target"
      "pterodactyl-wings-update.service"
    ];
    requires = [
      "docker.service"
      "docker-public-port-policy.service"
    ];
    wants = [ "pterodactyl-wings-update.service" ];
    serviceConfig = {
      WorkingDirectory = "/var/lib/pterodactyl/wings";
      ExecCondition = "${pkgs.writeShellScript "pterodactyl-wings-configured" ''
        test -x /var/lib/pterodactyl/wings/bin/wings
        ! ${pkgs.gnugrep}/bin/grep -q REPLACE_WITH_CONFIG ${config.sops.secrets.pterodactyl_wings_config.path}
      ''}";
      ExecStartPre = "${pkgs.writeShellScript "prepare-pterodactyl-wings-config" ''
        set -eu
        ${pkgs.coreutils}/bin/install -m 0600 \
          ${config.sops.secrets.pterodactyl_wings_config.path} \
          /var/lib/pterodactyl/wings/config/config.yml

        ${pkgs.yq-go}/bin/yq -i '
          .api.host = "127.0.0.1" |
          .api.port = 8080 |
          .api.ssl.enabled = false |
          .api.trusted_proxies = ["127.0.0.1"] |
          .sftp.bind_address = "0.0.0.0" |
          .sftp.bind_port = 2022 |
          .system.root_directory = "/var/lib/pterodactyl" |
          .system.log_directory = "/var/log/pterodactyl" |
          .system.data = "/var/lib/pterodactyl/volumes" |
          .system.archive_directory = "/var/lib/pterodactyl/archives" |
          .system.backup_directory = "/var/lib/pterodactyl/backups" |
          .system.tmp_directory = "/tmp/pterodactyl" |
          .system.username = "pterodactyl"
        ' /var/lib/pterodactyl/wings/config/config.yml
      ''}";
      ExecStart = "/var/lib/pterodactyl/wings/bin/wings --config /var/lib/pterodactyl/wings/config/config.yml";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 1048576;
      TasksMax = "infinity";
      UMask = "0077";
    };
  };

  systemd.services.rishabh-vm-healthcheck = {
    description = "Recover failed rishabh-vm services";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils pkgs.curl pkgs.gnugrep pkgs.systemd ];
    script = ''
      set -u

      for maintenance in \
        backup-app-databases.service \
        nixos-upgrade.service \
        pterodactyl-wings-update.service \
        update-app-containers.service
      do
        systemctl is-active --quiet "$maintenance" && exit 0
      done

      recover_unit() {
        unit="$1"
        if ! systemctl is-active --quiet "$unit"; then
          systemctl reset-failed "$unit" || true
          systemctl restart "$unit" || true
        fi
      }

      check_http() {
        unit="$1"
        url="$2"
        code="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 "$url" || true)"
        case "$code" in
          2*|3*|4*) ;;
          *) systemctl restart "$unit" || true ;;
        esac
      }

      for unit in \
        docker.service \
        docker-public-port-policy.service \
        create-app-networks.service \
        caddy.service \
        docker-authentik-postgres.service \
        docker-authentik-server.service \
        docker-authentik-worker.service \
        docker-copyparty.service \
        docker-portainer.service \
        docker-pterodactyl-mariadb.service \
        docker-pyrodactyl-panel.service \
        docker-pterodactyl-redis.service \
        tailscaled.service
      do
        recover_unit "$unit"
      done

      check_http docker-authentik-server.service http://127.0.0.1:9001/-/health/ready/
      check_http docker-copyparty.service http://127.0.0.1:3923/
      check_http docker-portainer.service http://127.0.0.1:9000/api/status
      check_http docker-pyrodactyl-panel.service http://127.0.0.1:8081/

      if test -x /var/lib/pterodactyl/wings/bin/wings &&
        ! grep -q REPLACE_WITH_CONFIG ${config.sops.secrets.pterodactyl_wings_config.path}; then
        recover_unit pterodactyl-wings.service
        check_http pterodactyl-wings.service http://127.0.0.1:8080/
      fi
    '';
  };

  systemd.timers.rishabh-vm-healthcheck = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "5m";
      Persistent = true;
    };
  };

  systemd.services.rishabh-vm-disk-guard = {
    description = "Reclaim disposable storage before the root disk fills";
    serviceConfig.Type = "oneshot";
    path = [
      config.nix.package
      pkgs.coreutils
      pkgs.docker
      pkgs.findutils
      pkgs.systemd
    ];
    script = ''
      set -eu
      usage="$(df --output=pcent / | tail -n 1 | tr -dc '0-9')"
      if [ "$usage" -lt 85 ]; then
        exit 0
      fi

      nix-collect-garbage --delete-older-than 7d
      docker image prune --all --force --filter=until=168h
      docker builder prune --all --force --filter=until=168h
      journalctl --vacuum-size=1G
      find /var/backups/rishabh-vm -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf -- {} +

      usage="$(df --output=pcent / | tail -n 1 | tr -dc '0-9')"
      if [ "$usage" -ge 95 ]; then
        echo "root filesystem remains at $usage% after cleanup; user data requires intervention" |
          systemd-cat --identifier=rishabh-vm-disk-guard --priority=crit
      fi
    '';
  };

  systemd.timers.rishabh-vm-disk-guard = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "1h";
    };
  };

  services.caddy = {
    enable = true;
    globalConfig = ''
      auto_https disable_redirects
      servers {
        protocols h1 h2
      }
    '';
    virtualHosts = {
      "auth.rishabhroy.com".extraConfig = ''
        ${securityHeaders}
        reverse_proxy 127.0.0.1:9001
      '';

      "cloud.rishabhroy.com".extraConfig = ''
        ${securityHeaders}
        request_body {
          max_size 20GB
        }
        route {
          @copyparty_share path /share /share/*
          reverse_proxy @copyparty_share 127.0.0.1:3923 {
            header_up -X-Authentik-Username
            header_up -X-Authentik-Groups
            header_up X-Copyparty-Proxy true
          }
          ${authentikForwardAuth}
          reverse_proxy 127.0.0.1:3923 {
            header_up X-Copyparty-Proxy true
          }
        }
      '';

      "games.rishabhroy.com".extraConfig = ''
        ${securityHeaders}
        request_body {
          max_size 100MB
        }
        route {
          @wings_panel_api path /api/remote /api/remote/*
          reverse_proxy @wings_panel_api 127.0.0.1:8081
          ${authentikForwardAuth}
          reverse_proxy 127.0.0.1:8081 {
            header_up -X-Pyrodactyl-Sso-Secret
            header_up X-Pyrodactyl-Sso-Secret "{$PYRODACTYL_SSO_SECRET}"
          }
        }
      '';

      "wings.rishabhroy.com".extraConfig = ''
        ${securityHeaders}
        reverse_proxy 127.0.0.1:8080
      '';

      "docker.rishabhroy.com".extraConfig = ''
        ${securityHeaders}
        reverse_proxy 127.0.0.1:9000
      '';
    };
  };

  systemd.services.caddy.after = [
    "docker-authentik-server.service"
    "docker-copyparty.service"
    "docker-portainer.service"
    "docker-pyrodactyl-panel.service"
  ];

  systemd.services.caddy.serviceConfig.EnvironmentFile = config.sops.templates."caddy.env".path;
}
