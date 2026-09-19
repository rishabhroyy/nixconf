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

  # sops-nix fails activation on a missing key, so all six must exist --
  # use an empty placeholder for any you aren't using yet.
  #   _blob              compose file for the stack. Its first-listed service
  #                      is brought up alone and waited on before anything
  #                      else -- order in the file is what matters, not any
  #                      given name.
  #   _app_src           app source mounted into one of the containers
  #   _check             post-start check script; anything but a clean exit
  #                      (including a timeout) tears the whole stack back down
  #   _on_ready          HTTP call to make once the check passes (JSON, see
  #                      run_http_hook above)
  #   _on_down           HTTP call to make when tearing down
  #   _egress_allowlist  one IP per line -- see the OUTPUT rule below
  sops.secrets.sandbox_stack_blob = {};
  sops.secrets.sandbox_stack_app_src = {};
  sops.secrets.sandbox_stack_check = {};
  sops.secrets.sandbox_stack_on_ready = {};
  sops.secrets.sandbox_stack_on_down = {};
  sops.secrets.sandbox_stack_egress_allowlist = {};

  # Host-level backstop, independent of anything the stack's own containers
  # do to themselves: no matter what runs inside that netns or what its own
  # internal rules say, the *host* only ever lets svc-sandbox's traffic reach
  # a fixed, small set of addresses on one UDP port -- everything else from
  # that uid is dropped before it ever leaves this machine. Matched by uid
  # (owner module), not by interface or container, so it holds even if
  # something inside the stack is misconfigured, compromised, or just wrong.
  # A dedicated chain (flushed and rebuilt every activation, same pattern
  # nixos-fw itself uses for its own chains just above) keeps this rule from
  # duplicating across every rebuild/firewall restart instead of appending
  # forever.
  networking.firewall.extraCommands = ''
    sandbox_uid=$(id -u svc-sandbox 2>/dev/null) || sandbox_uid=""
    if [ -n "$sandbox_uid" ]; then
      # Built fully under a staging name before OUTPUT ever references it --
      # a flush-then-rebuild of the *live* chain would leave a real window
      # (however brief) where OUTPUT has no restriction on this uid at all,
      # falling through to its own default ACCEPT for however long the
      # rebuild takes. Building off to the side first and only then cutting
      # over removes that window rather than just shrinking it.
      iptables -F sandbox-fw-egress-staging 2>/dev/null || true
      iptables -X sandbox-fw-egress-staging 2>/dev/null || true
      iptables -N sandbox-fw-egress-staging
      # Reply traffic for a connection accepted elsewhere (the docker0
      # app-port INPUT rule above, for hokago's own calls into this stack)
      # is still a locally-generated packet from this uid on OUTPUT -- without
      # this, replies on that already-accepted connection would hit the same
      # default DROP as everything else below. Only ESTABLISHED,RELATED,
      # never NEW -- a brand new outbound attempt still has to clear the
      # destination allowlist below regardless of what this uid has open.
      iptables -A sandbox-fw-egress-staging -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      if [ -s "${config.sops.secrets.sandbox_stack_egress_allowlist.path}" ]; then
        while IFS= read -r addr; do
          [ -n "$addr" ] || continue
          # This whole script runs under `set -e` (it's sourced into
          # firewall-start, which is itself `bash -e`) -- one malformed line
          # here (a bad fetch, a bad manual edit) would otherwise abort the
          # *entire* firewall reload partway through, not just skip this
          # entry. Skipping it is also the safe direction: the only effect
          # of dropping one entry is that gluetun's tunnel to that address
          # would fail to connect, never a wider allowance.
          if ! printf '%s' "$addr" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            echo "sandbox egress allowlist: skipping invalid entry: $addr" >&2
            continue
          fi
          iptables -A sandbox-fw-egress-staging -p udp -d "$addr" --dport 51820 -j ACCEPT
        done < "${config.sops.secrets.sandbox_stack_egress_allowlist.path}"
      fi
      iptables -A sandbox-fw-egress-staging -j DROP

      # Cutover: insert the new (fully-populated, exhaustive -- every packet
      # gets a final ACCEPT/DROP from it) jump ahead of the old one before
      # removing the old one. Both briefly exist together, but the new rule
      # is checked first and never falls through to the old one, so there is
      # no packet, at any point, evaluated against neither.
      iptables -I OUTPUT -m owner --uid-owner "$sandbox_uid" -j sandbox-fw-egress-staging
      iptables -D OUTPUT -m owner --uid-owner "$sandbox_uid" -j sandbox-fw-egress 2>/dev/null || true

      # Old chain is now unreferenced -- safe to remove. Renaming the
      # staging chain into the stable name (rather than leaving it as
      # "-staging") keeps the name sandbox-up's own check looks for, and
      # rename preserves the chain's existing kernel reference, so the jump
      # OUTPUT already has into it stays valid across the rename.
      iptables -F sandbox-fw-egress 2>/dev/null || true
      iptables -X sandbox-fw-egress 2>/dev/null || true
      iptables -E sandbox-fw-egress-staging sandbox-fw-egress

      # No allowlist entries exist for IPv6 (the stack disables it
      # internally) -- close that path at the host too instead of leaving it
      # merely unused.
      ip6tables -D OUTPUT -m owner --uid-owner "$sandbox_uid" -j DROP 2>/dev/null || true
      ip6tables -A OUTPUT -m owner --uid-owner "$sandbox_uid" -j DROP
    fi
  '';

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

      # Fail closed before anything starts: the host egress backstop
      # (networking.firewall.extraCommands, above) is a second, independent
      # layer this whole design depends on, not an optional extra. If a
      # rebuild hasn't reloaded the firewall yet, or the rule was dropped
      # some other way, that's exactly the situation the stack must never
      # run under -- nothing else here checks for it once containers exist.
      ${pkgs.iptables}/bin/iptables -L OUTPUT -n 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q "sandbox-fw-egress" \
        || { echo "sandbox-up: host egress backstop chain missing -- refusing to start (nixos-rebuild switch first?)" >&2; exit 1; }

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

      # The images below get pulled fresh by svc-sandbox's own podman on
      # every single run -- the compose stack's storage root is the same
      # tmpfs mounted above, wiped on every teardown by design, so nothing
      # ever survives between sessions to reuse. That pull is a real host-
      # level HTTPS connection from svc-sandbox, subject to the same egress
      # backstop as everything else on that uid -- without an exception,
      # the very next command would fail every single time.
      #
      # Scoped to exactly what's needed (443 only, only these registries'
      # currently-resolved IPs), added here rather than as a toggle around
      # just the pull: a temporary widen-then-retighten was considered and
      # rejected on purpose -- a failed retighten step would leave the
      # sandbox open far wider than this bounded, standing exception ever
      # is. Resolved here (not in the boot-time firewall rule) because DNS
      # may not be up yet that early in boot; this runs on-demand, well
      # after. Not removed on teardown -- reset (below) and refreshed to
      # current IPs on every sandbox-up instead, so a stale entry (a cloud
      # IP long since reassigned to someone else) can never outlive one run.
      #
      # Reset just this subset first -- safe unconditionally, since removing
      # an allow rule can only ever narrow what's already default-denied,
      # never open anything, and this fully completes before the pull that
      # actually needs these entries even starts.
      while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        ${pkgs.iptables}/bin/iptables -D sandbox-fw-egress $rule
      done < <(${pkgs.iptables}/bin/iptables -S sandbox-fw-egress 2>/dev/null | ${pkgs.gnugrep}/bin/grep -- '--dport 443' | ${pkgs.gnused}/bin/sed 's/^-A sandbox-fw-egress //')

      # A plain DNS lookup here would trust whatever the resolver hands
      # back with no way to verify it -- a spoofed/poisoned answer gets
      # permanently allowlisted the same as a real one. Actually completing
      # a TLS handshake and checking the cert validates for this exact
      # hostname closes that: a spoofed IP fails certificate validation and
      # curl reports nothing, so nothing gets added for it.
      #
      # -4 is load-bearing, not a style choice: several of these hostnames
      # publish AAAA records, this host has real working IPv6, and curl's
      # default happy-eyeballs behavior does pick a v6 address in practice
      # on this host. `iptables` (as opposed to `ip6tables`) rejects a v6
      # address outright, and under this script's `set -e` that would abort
      # and tear down the whole stack. IPv6 is unconditionally blocked for
      # this uid anyway (see the ip6tables rule above), so there's nothing
      # to gain from ever preferring it here.
      #
      # A single connection per hostname is enough for all three of these
      # specifically -- each one's actual blob/layer download stays on the
      # same hostname it started on (confirmed by tracing the redirect for
      # each), resolving to one small, stable address, not a CDN edge with
      # a large rotating pool. That property is *why* these three were
      # chosen (mirror.gcr.io over docker.io for the same reason): a
      # registry whose blob storage redirects to shared CDN infrastructure
      # (Docker Hub's docker.io, or AWS ECR Public's CloudFront-fronted
      # blobs) can hand podman's own later pull a different address than
      # whichever one this resolved, silently dropped by the rule below --
      # confirmed in practice, not theoretical.
      for reg_host in ghcr.io pkg-containers.githubusercontent.com mirror.gcr.io; do
        reg_ip="$(${pkgs.curl}/bin/curl -4 -s --max-time 5 -o /dev/null -w '%{remote_ip}' "https://$reg_host/" 2>/dev/null)"
        [ -n "$reg_ip" ] || continue
        ${pkgs.iptables}/bin/iptables -C sandbox-fw-egress -p tcp -d "$reg_ip" --dport 443 -j ACCEPT 2>/dev/null \
          || ${pkgs.iptables}/bin/iptables -I sandbox-fw-egress 1 -p tcp -d "$reg_ip" --dport 443 -j ACCEPT
      done

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

      # check.sh itself runs directly on the host as svc-sandbox below (not
      # inside any podman netns), so its own top-level network calls are
      # subject to the same host egress backstop everything else on that
      # uid is -- a bare curl there would just be dropped. Fetched here, as
      # root, unrestricted, once, rather than carving a hole in that rule
      # for an unrelated diagnostic lookup.
      HOST_IP="$(${pkgs.curl}/bin/curl -s --max-time 5 https://api.ipify.org)"
      [ -n "$HOST_IP" ] || { echo "sandbox-up: could not read the host's own public IP" >&2; teardown; }
      HOST_GEO="$(${pkgs.curl}/bin/curl -s --max-time 5 "http://ip-api.com/json/$HOST_IP" 2>/dev/null)"

      # Post-start check, bounded so a hang in here can't hang this script
      # forever. It execs into every other container the stack defines, so
      # a service that never actually started (bad command, crash loop,
      # missing image) fails there with a clear error -- no separate
      # "is everything running" pass needed first.
      POD_DIR="$HOME_DIR" PODMAN="${pkgs.podman}/bin/podman" HOST_IP="$HOST_IP" HOST_GEO="$HOST_GEO" \
        ${pkgs.coreutils}/bin/timeout 180 \
        ${pkgs.util-linux}/bin/runuser -u svc-sandbox --whitelist-environment=POD_DIR,PODMAN,HOST_IP,HOST_GEO \
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
