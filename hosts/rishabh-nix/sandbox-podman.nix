{ config, pkgs, lib, ... }:

# Throwaway container stack for local experiments, torn down completely on
# every stop. Runs on rootless podman with its own storage root, backed by
# tmpfs, so nothing it does ever touches persistent disk and a stop leaves
# nothing behind to inspect. The stack itself (compose file, app code, the
# post-start check) lives in sops, not here -- this file only knows how to
# bring one up, verify it, and tear it down; not what it does or why.
let
  lib_sh = pkgs.writeShellScript "sandbox-lib.sh" ''
    # Makes exactly one HTTP request described by a {method,url,headers,body}
    # JSON file -- data, never executed. Bounded so an unreachable endpoint
    # can't hang the caller, and prints the real status/body on failure so
    # "wrong key" (401), "not found" (404), and "unreachable" (timeout) are
    # distinguishable instead of one opaque failure.
    run_http_hook() {
      local path="$1"
      [ -s "$path" ] || return 0
      local method url body
      method="$(${pkgs.jq}/bin/jq -r '.method // empty' "$path")"
      url="$(${pkgs.jq}/bin/jq -r '.url // empty' "$path")"
      body="$(${pkgs.jq}/bin/jq -r '.body // empty' "$path")"
      if [ -z "$method" ] || [ -z "$url" ]; then
        echo "run_http_hook: $path has no method/url -- skipping" >&2
        return 0
      fi
      local -a hdr_args=()
      while IFS= read -r h; do hdr_args+=(-H "$h"); done < <(${pkgs.jq}/bin/jq -r '.headers // {} | to_entries[] | "\(.key): \(.value)"' "$path")
      local resp status
      resp="$(${pkgs.curl}/bin/curl -s --max-time 10 -w $'\n%{http_code}' -X "$method" "$url" "''${hdr_args[@]}" ''${body:+-d "$body"} 2>&1)" \
        || { echo "run_http_hook: $method $url -- could not connect (''${resp:-no output})" >&2; return 1; }
      status="''${resp##*$'\n'}"
      if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
        echo "run_http_hook: $method $url -> HTTP $status: ''${resp%$'\n'*}" >&2
        return 1
      fi
    }

    # Removes the running stack and its scratch dir entirely. Safe to call
    # when there's nothing to remove. $HOME_DIR is set by the caller.
    teardown_stack() {
      # runuser doesn't change directory, so podman/podman-compose below
      # would otherwise inherit whatever directory this script itself was
      # invoked from (e.g. an interactive shell's $HOME) -- svc-sandbox
      # has no permission to even enter that, which fails every podman
      # call with "cannot chdir ... Permission denied", not just this one.
      cd "$HOME_DIR"
      if ${pkgs.util-linux}/bin/mountpoint -q "$HOME_DIR"; then
        # Subshell closes the lock fd before podman-compose runs -- without
        # this, conmon (podman's per-container monitor, which deliberately
        # outlives the command that started it) inherits it too, and the
        # lock never frees for as long as any container it started stays up.
        ( exec 9>&- 2>/dev/null; ${pkgs.coreutils}/bin/timeout 30 ${pkgs.util-linux}/bin/runuser -u svc-sandbox -- ${pkgs.podman-compose}/bin/podman-compose -f "$HOME_DIR/pod.yaml" down -v --rmi all >/dev/null 2>&1 ) || true
        ${pkgs.util-linux}/bin/umount "$HOME_DIR" 2>/dev/null || ${pkgs.util-linux}/bin/umount -l "$HOME_DIR" || true
      fi
      ${pkgs.coreutils}/bin/install -d -m 0700 -o svc-sandbox -g users "$HOME_DIR"
    }
  '';
in
{
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
  };

  # Modern podman defaults rootless networking to pasta, under which some
  # containers that manage their own tunnel/interface can fail outright
  # (seen in the wild as a healthcheck that never turns healthy, not a
  # capability/permission error -- the container itself isn't doing
  # anything wrong, the rootless network path underneath it just behaves
  # differently). slirp4netns is the older, better-tested rootless backend
  # for that case and ships with podman regardless of which one is
  # configured as default.
  virtualisation.containers.containersConf.settings.network.default_rootless_network_cmd = "slirp4netns";

  # hokago's own containers (Docker) reach this stack's published app port
  # to register/health-check it (see sandbox_stack_on_ready in sops). A
  # connection made by the host itself to that same address is treated as
  # loopback-equivalent (both ends are locally owned) and never hits this
  # rule at all -- but a real container on docker0 genuinely traverses that
  # interface, and NixOS's firewall drops new inbound connections on any
  # interface with no explicit allow, docker0 included. Scoped to docker0
  # and this one port only: no route, no trustedInterfaces, nothing that
  # touches podman's own interfaces -- the sandbox still has no path
  # toward hokago or its tailscale sidecar in the other direction.
  networking.firewall.interfaces."docker0".allowedTCPPorts = [ 8181 ];

  users.users.svc-sandbox = {
    isNormalUser = true;
    createHome = true;
    home = "/var/lib/svc-sandbox";
    hashedPassword = "!";
    shell = "${pkgs.shadow}/bin/nologin";
    # Invoked via runuser, never a real login -- without lingering there's
    # no systemd user session or D-Bus bus for this account at all, which
    # rootless podman's network backend (netavark/aardvark-dns) hard-fails
    # without, not just degrades gracefully like it does for the cgroup
    # manager choice.
    linger = true;
  };

  # sops-nix fails activation on a missing key, so all five must exist --
  # use an empty placeholder for any you aren't using yet.
  #   _blob       compose file for the stack. Its first-listed service is
  #               brought up alone and waited on before anything else --
  #               order in the file is what matters, not any given name.
  #   _app_src    app source mounted into one of the containers
  #   _check      post-start check script; anything but a clean exit
  #               (including a timeout) tears the whole stack back down
  #   _on_ready   HTTP call to make once the check passes (JSON, see
  #               run_http_hook above)
  #   _on_down    HTTP call to make when tearing down
  sops.secrets.sandbox_stack_blob = {};
  sops.secrets.sandbox_stack_app_src = {};
  sops.secrets.sandbox_stack_check = {};
  sops.secrets.sandbox_stack_on_ready = {};
  sops.secrets.sandbox_stack_on_down = {};

  environment.systemPackages = with pkgs; [
    podman-compose
    jq
    (pkgs.writeShellScriptBin "sandbox-up" ''
      set -euo pipefail
      source ${lib_sh}

      HOME_DIR=/var/lib/svc-sandbox
      LOCK=/run/sandbox.lock
      POD_UID=$(${pkgs.coreutils}/bin/id -u svc-sandbox)
      POD_GID=$(${pkgs.glibc.getent}/bin/getent group users | ${pkgs.coreutils}/bin/cut -d: -f3)
      export XDG_RUNTIME_DIR=/run/user/$POD_UID

      exec 9>"$LOCK"
      ${pkgs.util-linux}/bin/flock -n 9 || { echo "sandbox-up: already running" >&2; exit 1; }

      teardown() {
        echo "sandbox-up: did not complete -- removing the stack" >&2
        run_http_hook ${config.sops.secrets.sandbox_stack_on_down.path} || true
        teardown_stack
        # A trap for INT/TERM (unlike ERR under `set -e`) doesn't itself end
        # the script, just runs this handler and resumes -- without the
        # explicit exit, ctrl-C during a wait loop would tear down and then
        # keep running.
        exit 1
      }
      trap teardown ERR INT TERM

      ${pkgs.coreutils}/bin/mkdir -p -m 0700 "$XDG_RUNTIME_DIR"
      ${pkgs.coreutils}/bin/chown svc-sandbox: "$XDG_RUNTIME_DIR"

      teardown_stack   # clear any stale state left by a previous unclean stop
      # Numeric ids, not names -- tmpfs's uid=/gid= are mount(2) options
      # resolved before the syscall, and not every util-linux version
      # resolves symbolic names there reliably.
      ${pkgs.util-linux}/bin/mount -t tmpfs -o size=4G,mode=0700,uid=$POD_UID,gid=$POD_GID tmpfs "$HOME_DIR"
      # Re-anchor here: teardown_stack's own cd (just above) now points at
      # the pre-mount directory this tmpfs just shadowed, not the fresh one.
      cd "$HOME_DIR"

      ${pkgs.coreutils}/bin/install -m 0600 -o svc-sandbox -g users ${config.sops.secrets.sandbox_stack_blob.path} "$HOME_DIR/pod.yaml"
      ${pkgs.coreutils}/bin/install -m 0600 -o svc-sandbox -g users ${config.sops.secrets.sandbox_stack_app_src.path} "$HOME_DIR/app.js"
      ${pkgs.coreutils}/bin/install -m 0700 -o svc-sandbox -g users ${config.sops.secrets.sandbox_stack_check.path} "$HOME_DIR/check.sh"

      # Subshells close the lock fd before podman/podman-compose run -- see
      # the matching comment in teardown_stack above. `up -d` is the one
      # that actually matters (it starts conmon, which persists for the
      # container's whole lifetime), but every call goes through the same
      # two helpers, so closing it here covers all of them uniformly.
      p() { ( exec 9>&- 2>/dev/null; ${pkgs.util-linux}/bin/runuser -u svc-sandbox -- ${pkgs.podman}/bin/podman "$@" ); }
      pc() { ( exec 9>&- 2>/dev/null; ${pkgs.util-linux}/bin/runuser -u svc-sandbox -- ${pkgs.podman-compose}/bin/podman-compose -f "$HOME_DIR/pod.yaml" "$@" ); }

      # The compose file's first-listed service, whatever it's named --
      # brought up alone and waited on before anything else, rather than
      # trusting compose's own depends_on/condition to enforce that.
      # A failed command inside an if/|| condition doesn't trip the ERR trap
      # (that's specifically exempted under set -e) -- everything below that
      # can fail after the mount/secret-install above calls teardown directly
      # instead of a bare exit, so cleanup isn't skipped on these paths too.
      PRIMARY="$(pc config --services 2>/dev/null | ${pkgs.coreutils}/bin/head -1)"
      [ -n "$PRIMARY" ] || { echo "sandbox-up: could not read any service from the compose file" >&2; teardown; }
      if ! pc up -d "$PRIMARY"; then
        echo "sandbox-up: could not start $PRIMARY -- check the compose file and image references" >&2
        teardown
      fi
      primary_ok=0
      for i in $(${pkgs.coreutils}/bin/seq 1 30); do
        [ "$(p inspect --format '{{.State.Health.Status}}' "$PRIMARY" 2>/dev/null)" = "healthy" ] && { primary_ok=1; break; }
        sleep 1
      done
      [ "$primary_ok" = "1" ] || { echo "sandbox-up: $PRIMARY never became healthy (check its own logs: podman logs $PRIMARY)" >&2; teardown; }

      # --no-recreate: without it this can tear down and rebuild the primary
      # just waited on above, restarting its network namespace out from
      # under everything attached to it.
      pc up -d --no-recreate

      # Post-start check, bounded so a hang in here can't hang this script
      # forever. It execs into every other container the stack defines, so
      # a service that never actually started (bad command, crash loop,
      # missing image) fails there with a clear error -- no separate
      # "is everything running" pass needed first.
      POD_DIR="$HOME_DIR" PODMAN="${pkgs.podman}/bin/podman" \
        ${pkgs.coreutils}/bin/timeout 180 \
        ${pkgs.util-linux}/bin/runuser -u svc-sandbox --whitelist-environment=POD_DIR,PODMAN \
        -- ${pkgs.bash}/bin/bash "$HOME_DIR/check.sh"

      trap - ERR INT TERM
      echo "sandbox-up: ready."

      run_http_hook ${config.sops.secrets.sandbox_stack_on_ready.path} \
        || echo "sandbox-up: on-ready hook failed (see above) -- stack is up and safe, but the integration may not be" >&2
    '')
    (pkgs.writeShellScriptBin "sandbox-down" ''
      set -euo pipefail
      source ${lib_sh}

      HOME_DIR=/var/lib/svc-sandbox
      LOCK=/run/sandbox.lock
      POD_UID=$(${pkgs.coreutils}/bin/id -u svc-sandbox)
      export XDG_RUNTIME_DIR=/run/user/$POD_UID

      exec 9>"$LOCK"
      ${pkgs.util-linux}/bin/flock -w 30 9 || { echo "sandbox-down: sandbox-up is still holding the lock -- if it's stuck, check: podman ps (as svc-sandbox)" >&2; exit 1; }

      run_http_hook ${config.sops.secrets.sandbox_stack_on_down.path} || true
      teardown_stack

      echo "sandbox-down: removed. verifying..."
      cd /tmp   # svc-sandbox can't be entered from here either -- same reason as teardown_stack's own cd
      # Under set -e this assignment (unlike an if/||-condition use of the
      # same command) DOES abort the script on failure -- fall back to a
      # value that still prints instead of skipping both checks below on
      # some unrelated rootless-podman hiccup.
      # stderr intentionally left alone here (not merged in) -- podman can
      # print benign warnings on a perfectly successful, empty ps, and
      # merging those into $remaining would misreport a clean teardown as
      # "containers still present: <warning text>".
      remaining="$(${pkgs.util-linux}/bin/runuser -u svc-sandbox -- ${pkgs.podman}/bin/podman ps -a --format '{{.Names}}')" \
        || remaining="(could not check -- podman ps itself failed)"
      if [ -n "$remaining" ]; then
        echo "sandbox-down: WARNING -- containers still present: $remaining" >&2
      else
        echo "sandbox-down: confirmed -- no containers remain"
      fi
      if ${pkgs.util-linux}/bin/mountpoint -q "$HOME_DIR"; then
        echo "sandbox-down: WARNING -- $HOME_DIR is still mounted" >&2
      else
        echo "sandbox-down: confirmed -- $HOME_DIR is not mounted (tmpfs gone)"
      fi
    '')
  ];

  environment.shellAliases = {
    sandbox-up = "sudo /run/current-system/sw/bin/sandbox-up";
    sandbox-down = "sudo /run/current-system/sw/bin/sandbox-down";
  };
}
