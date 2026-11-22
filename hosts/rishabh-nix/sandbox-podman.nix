{ config, pkgs, lib, ... }:

# Throwaway container stack for local experiments, torn down completely on
# every stop. Runs on rootless podman with its own storage root, backed by
# tmpfs, so nothing it does ever touches persistent disk and a stop leaves
# nothing behind to inspect. The stack itself (compose file, app code, the
# post-start check) lives in sops, not here -- this file only knows how to
# bring one up, verify it, and tear it down; not what it does or why.
let
  # The one port the stack publishes (reached from docker0, see the firewall
  # allow below). The only source port this uid may ever send from, and only
  # on a connection that is already established -- never a new one.
  appPort = 8181;

  # Fixed addressing for the rootless network namespace's uplink, so it never
  # inherits the host's own addresses or routes (pasta copies the host's by
  # default). Same layout slirp4netns used, so nothing inside sees a change.
  netnsAddr = "10.0.2.100";
  netnsPrefix = "24";
  netnsGw = "10.0.2.2";

  # Second, independent egress layer for this uid: its own nftables table,
  # separate from the iptables chain below, so a mistake, flush or reload in
  # one never takes the other with it.
  nftTable = "sandbox_guard";
  # Root-only dump of both layers, taken right after the firewall builds them.
  guardRef = "/run/sandbox-guard.ref";
  allowlistPath = config.sops.secrets.sandbox_stack_egress_allowlist.path;

  ipt = "${pkgs.iptables}/bin/iptables";
  ip6t = "${pkgs.iptables}/bin/ip6tables";
  nft = "${pkgs.nftables}/bin/nft";
  grep = "${pkgs.gnugrep}/bin/grep";
  ipv4Re = "([0-9]{1,3}\\.){3}[0-9]{1,3}";

  # Canonical dump of every static rule restricting this uid, in both layers.
  # Stateless (-s), so counters never register as a change. The per-run pull
  # exception lives in its own chain/set, deliberately outside this dump.
  # Exits non-zero if any part is missing, so a partial dump is never taken
  # as a valid reference.
  guardState = pkgs.writeShellScript "sandbox-guard-state" ''
    set -euo pipefail
    uid="$1"
    echo "## iptables egress"
    ${ipt} -S sandbox-fw-egress
    echo "## iptables OUTPUT"
    ${ipt} -S OUTPUT | ${grep} -F -- "--uid-owner $uid "
    echo "## ip6tables OUTPUT"
    ${ip6t} -S OUTPUT | ${grep} -F -- "--uid-owner $uid "
    echo "## nft"
    ${nft} -s list chain inet ${nftTable} out
    ${nft} -s list chain inet ${nftTable} uid_out
    ${nft} -s list set inet ${nftTable} allow4
  '';

  # Fails (non-zero, reason on stderr) unless both egress layers are exactly
  # what the firewall built, match the current allowlist, end in a drop, and
  # carry no pull exception. Run before anything starts, after the pull,
  # after startup, and periodically while the stack is up.
  guardCheck = pkgs.writeShellScript "sandbox-guard-check" ''
    set -uo pipefail
    bad() { echo "guard: $*" >&2; exit 1; }
    uid="$(${pkgs.coreutils}/bin/id -u svc-sandbox)" || bad "svc-sandbox user missing"

    [ -s ${guardRef} ] || bad "no reference dump -- the firewall never finished building the egress rules"
    now="$(${guardState} "$uid")" || bad "an egress layer is missing (could not dump it)"
    [ "$now" = "$(${pkgs.coreutils}/bin/cat ${guardRef})" ] || bad "egress rules differ from what the firewall built"

    # Shape checks, independent of the reference dump itself.
    ${ipt} -C OUTPUT -m owner --uid-owner "$uid" -j sandbox-fw-egress 2>/dev/null || bad "iptables OUTPUT jump missing"
    [ "$(${ipt} -S sandbox-fw-egress | ${pkgs.coreutils}/bin/tail -n1)" = "-A sandbox-fw-egress -j DROP" ] || bad "iptables chain does not end in DROP"
    ${ip6t} -C OUTPUT -m owner --uid-owner "$uid" -j DROP 2>/dev/null || bad "ip6tables DROP missing"
    out_chain="$(${nft} -s list chain inet ${nftTable} out)" || bad "nft out chain missing"
    printf '%s\n' "$out_chain" | ${grep} -q "type filter hook output priority filter; policy accept;" || bad "nft out chain not hooked as expected"
    printf '%s\n' "$out_chain" | ${grep} -qE "meta skuid (\"?svc-sandbox\"?|$uid) jump uid_out" || bad "nft out chain does not send this uid to its chain"
    uid_chain="$(${nft} -s list chain inet ${nftTable} uid_out)" || bad "nft uid chain missing"
    rules="$(printf '%s\n' "$uid_chain" | ${grep} -vE '^\s*(table|chain|\}|$)')"
    printf '%s\n' "$rules" | ${pkgs.coreutils}/bin/head -n1 | ${grep} -qE '^\s*meta nfproto ipv6 drop$' || bad "nft uid chain does not start by dropping IPv6"
    printf '%s\n' "$rules" | ${pkgs.coreutils}/bin/tail -n1 | ${grep} -qE '^\s*(counter )?drop$' || bad "nft uid chain does not end in drop"

    # Both layers' relay sets must equal the allowlist currently on disk.
    want="$(${grep} -xE '${ipv4Re}' ${allowlistPath} 2>/dev/null | ${pkgs.coreutils}/bin/sort -u)"
    have_ipt="$(${ipt} -S sandbox-fw-egress | ${grep} -F -- '--dport 51820' | ${grep} -oE '${ipv4Re}' | ${pkgs.coreutils}/bin/sort -u)"
    have_nft="$(${nft} -s list set inet ${nftTable} allow4 | ${grep} -oE '${ipv4Re}' | ${pkgs.coreutils}/bin/sort -u)"
    [ "$have_ipt" = "$want" ] || bad "iptables relay set does not match the allowlist"
    [ "$have_nft" = "$want" ] || bad "nft relay set does not match the allowlist"

    # The pull exception must be empty outside the pull itself.
    [ "$(${ipt} -S sandbox-fw-pull)" = "-N sandbox-fw-pull" ] || bad "iptables pull exception not empty"
    if ${nft} -s list set inet ${nftTable} pull4 | ${grep} -qE '${ipv4Re}'; then bad "nft pull exception not empty"; fi
    exit 0
  '';

  # Tries to send one TCP connect / UDP datagram as the given user and prints
  # "reached" or "blocked". Reached = connected, or got an active refusal
  # (RST), or the datagram left the socket -- anything that means the packet
  # got past the local egress rules. Everything else (EPERM from a local
  # drop, timeout) is "blocked".
  hostProbe = pkgs.writeShellScript "sandbox-host-probe" ''
    set -u
    cd /
    out="$(${pkgs.coreutils}/bin/timeout 4 ${pkgs.util-linux}/bin/runuser -u "$1" -- \
      ${pkgs.bash}/bin/bash -c 'exec 3<>"/dev/$0/$1/$2" && printf x >&3' "$2" "$3" "$4" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ] || printf '%s' "$out" | ${grep} -qi 'refused'; then echo reached; else echo blocked; fi
  '';

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
      # A pull that never resulted in a real container (a network hang) is
      # invisible to `down` above: compose only knows to reach things it's
      # tracking, and that was never one. Left alone it survives
      # indefinitely -- observed more than once. svc-sandbox never runs
      # anything of its own choosing, only what this stack starts, so
      # anything still running for it other than its own baseline lingering
      # session (needed for rootless networking, see users.users above) is
      # safe to kill regardless of what specifically got stuck -- no need
      # to know or name what the stack itself actually runs.
      ${pkgs.procps}/bin/pgrep -u svc-sandbox 2>/dev/null | while read -r leftover_pid; do
        leftover_comm="$(${pkgs.procps}/bin/ps -o comm= -p "$leftover_pid" 2>/dev/null)"
        case "$leftover_comm" in
          systemd|dbus-broker-launch|dbus-broker|'(sd-pam)') continue ;;
        esac
        kill "$leftover_pid" 2>/dev/null || true
      done || true
      pull_exception_clear || true
      ${pkgs.coreutils}/bin/install -d -m 0700 -o svc-sandbox -g users "$HOME_DIR"
    }

    # Empties the per-run registry exception in both egress layers. Only ever
    # narrows what is allowed, so it is safe to call at any time.
    pull_exception_clear() {
      ${ipt} -F sandbox-fw-pull 2>/dev/null
      ${nft} flush set inet ${nftTable} pull4 2>/dev/null
    }

    # The rootless network namespace must be wired exactly as configured:
    # exactly one pasta process for this uid, started with the pinned
    # options (and not forwarding any host port itself -- that's
    # rootlessport's job), and the namespace holding none of the host's own
    # addresses, with its default route via the pinned gateway. Needs the
    # caller's p() helper.
    verify_netns() {
      local pids pid n=0 args need ns_addrs ns_route a
      for pid in $(${pkgs.procps}/bin/pgrep -u svc-sandbox); do
        case "$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink "/proc/$pid/exe" 2>/dev/null)")" in
          passt|passt.avx2) n=$((n + 1)); pids="$pid" ;;
        esac
      done
      [ "$n" = 1 ] || { echo "netns: expected exactly one pasta process for svc-sandbox, found $n" >&2; return 1; }
      args=" $(${pkgs.coreutils}/bin/tr '\0' ' ' < "/proc/$pids/cmdline")"
      for need in "-a ${netnsAddr}/${netnsPrefix} " "-g ${netnsGw} " "--map-host-loopback none " "--no-icmp " "-t none " "-u none "; do
        case "$args" in
          *" $need"*) ;;
          *) echo "netns: pasta is missing required option '$need'" >&2; return 1 ;;
        esac
      done

      ns_addrs="$(p unshare --rootless-netns ${pkgs.iproute2}/bin/ip -4 -o addr show 2>/dev/null)" \
        || { echo "netns: could not read the rootless namespace's addresses" >&2; return 1; }
      printf '%s\n' "$ns_addrs" | ${grep} -qF " ${netnsAddr}/${netnsPrefix} " \
        || { echo "netns: pinned address ${netnsAddr}/${netnsPrefix} not present" >&2; return 1; }
      for a in $(${pkgs.iproute2}/bin/ip -4 -o addr show | ${pkgs.gawk}/bin/awk '$2 != "lo" {print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1); do
        if printf '%s\n' "$ns_addrs" | ${grep} -qF " $a/"; then
          echo "netns: rootless namespace carries a host address ($a)" >&2; return 1
        fi
      done
      ns_route="$(p unshare --rootless-netns ${pkgs.iproute2}/bin/ip -4 route show default 2>/dev/null)" \
        || { echo "netns: could not read the rootless namespace's routes" >&2; return 1; }
      [ "$(printf '%s\n' "$ns_route" | ${pkgs.gawk}/bin/awk '{print $1, $2, $3}')" = "default via ${netnsGw}" ] \
        || { echo "netns: default route is not via ${netnsGw}: $ns_route" >&2; return 1; }
    }

    # Live check of the combined effect of both egress layers, from the host,
    # as svc-sandbox: every target below must come back "blocked". Local
    # targets on a closed port answer instantly with a refusal if a packet
    # gets through; UDP targets fail at the socket if dropped -- so neither
    # depends on the far end behaving. A root control runs first and must
    # come back "reached", proving the probe itself can see a packet get
    # through, so a broken probe can never pass as "blocked".
    # $reg_ips (the pull exception's addresses, now removed) is optional.
    probe_host_blocked() {
      local targets addr gw relay results expected
      [ "$(${hostProbe} root tcp 127.0.0.1 1)" = reached ] || { echo "probe: tcp control failed -- probe unusable" >&2; return 1; }
      [ "$(${hostProbe} root udp 127.0.0.1 1)" = reached ] || { echo "probe: udp control failed -- probe unusable" >&2; return 1; }
      targets="tcp,127.0.0.1,1 udp,127.0.0.1,1 tcp,::1,1 udp,::1,1 udp,1.1.1.1,53 tcp,1.1.1.1,443"
      for addr in $(${pkgs.iproute2}/bin/ip -4 -o addr show | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1); do
        targets="$targets tcp,$addr,1 udp,$addr,1"
      done
      gw="$(${pkgs.iproute2}/bin/ip -4 route show default | ${pkgs.gawk}/bin/awk '{print $3; exit}')"
      [ -z "$gw" ] || targets="$targets udp,$gw,53 tcp,$gw,53"
      # An allowlisted address on anything other than the one allowed port.
      relay="$(${grep} -m1 -xE '${ipv4Re}' ${allowlistPath} 2>/dev/null || true)"
      [ -z "$relay" ] || targets="$targets udp,$relay,53 tcp,$relay,443"
      for addr in ''${reg_ips:-}; do targets="$targets tcp,$addr,443"; done

      expected=0
      for _ in $targets; do expected=$((expected + 1)); done
      results="$(
        for t in $targets; do
          ( IFS=, read -r proto addr port <<<"$t"
            echo "$(${hostProbe} svc-sandbox "$proto" "$addr" "$port") $t" ) &
        done
        wait
      )"
      if [ "$(printf '%s\n' "$results" | ${grep} -c '^blocked ')" != "$expected" ]; then
        echo "probe: egress from svc-sandbox got through (or a probe did not report):" >&2
        printf '%s\n' "$results" | ${grep} -v '^blocked ' >&2
        return 1
      fi
    }
  '';
in
{
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
  };

  # Rootless networking is pasta (the only backend podman 6 supports; it was
  # slirp4netns here before). pasta copies the host's own addresses, routes
  # and gateway into the namespace by default -- pinned instead to the same
  # fixed private layout slirp4netns used (-a/-g also stop route and address
  # copying), with no address mapped back to the host's loopback, and no ICMP
  # handler. Egress is still only ever pasta's own host sockets, as this uid,
  # under both egress layers below; sandbox-up checks pasta really started
  # with these and refuses to run otherwise.
  #
  # Port forwarding pinned to rootlessport (today's default, same as under
  # slirp4netns): inbound connections reach the stack from inside its own
  # network, not with the caller's real source address, so the stack's own
  # firewall needs no inbound exception.
  virtualisation.containers.containersConf.settings.network = {
    pasta_options = [
      "-a" "${netnsAddr}/${netnsPrefix}"
      "-g" netnsGw
      "--map-host-loopback" "none"
      "--no-icmp"
    ];
    rootless_port_forwarder = "rootlessport";
  };

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
  # Rebuild both egress layers whenever the allowlist itself changes -- the
  # firewall unit's own text doesn't change with a secret's content, so it
  # would otherwise keep the old set until something else reloaded it.
  sops.secrets.sandbox_stack_egress_allowlist = {
    reloadUnits = [ "firewall.service" ];
  };

  # Host-level egress restriction for svc-sandbox, independent of anything the
  # stack's own containers do to themselves. Matched by uid (owner), not by
  # interface or container, so it holds even if something inside the stack is
  # misconfigured, compromised, or just wrong. Rootless, the namespace has no
  # path out except pasta's own host sockets, which run as this uid.
  #
  # Two layers, each enough on its own, built from the same validated list:
  #   1. iptables chain sandbox-fw-egress (jumped from OUTPUT for this uid)
  #   2. nftables table ${nftTable} (its own output hook for this uid)
  # Each allows exactly:
  #   - UDP to the allowlisted addresses on 51820
  #   - TCP 443 to the per-run pull exception (empty except during the pull)
  #   - replies from the app port on an already-established connection,
  #     out docker0 or lo only (inbound calls into the stack)
  # and drops everything else, plus all IPv6. Afterwards both are dumped to a
  # root-only reference that sandbox-up and the watchdog compare against.
  networking.firewall.extraCommands = ''
    sandbox_uid=$(id -u svc-sandbox 2>/dev/null) || sandbox_uid=""
    if [ -n "$sandbox_uid" ]; then
      # One validated list feeds both layers. This whole script runs under
      # `set -e` (sourced into firewall-start), so a malformed line is
      # skipped rather than aborting the entire firewall reload; skipping is
      # the safe direction (that one address just becomes unreachable).
      relays=""
      if [ -s "${allowlistPath}" ]; then
        while IFS= read -r addr; do
          [ -n "$addr" ] || continue
          if ! printf '%s' "$addr" | grep -qxE '${ipv4Re}'; then
            echo "sandbox egress allowlist: skipping invalid entry: $addr" >&2
            continue
          fi
          relays="$relays $addr"
        done < "${allowlistPath}"
      fi

      # --- layer 2: nftables -------------------------------------------
      # Applied as one atomic transaction (create-if-missing, delete,
      # recreate), so there is never a moment with this table half-built
      # or absent once it has existed.
      nft_elems=""
      for addr in $relays; do
        if [ -n "$nft_elems" ]; then nft_elems="$nft_elems, $addr"; else nft_elems="$addr"; fi
      done
      nft_allow=""
      [ -z "$nft_elems" ] || nft_allow="elements = { $nft_elems }"
      if ! ${nft} -f - <<NFT
    table inet ${nftTable}
    delete table inet ${nftTable}
    table inet ${nftTable} {
      set allow4 {
        type ipv4_addr
        $nft_allow
      }
      set pull4 {
        type ipv4_addr
      }
      chain out {
        type filter hook output priority filter; policy accept;
        meta skuid $sandbox_uid jump uid_out
      }
      chain uid_out {
        meta nfproto ipv6 drop
        ip daddr @allow4 udp dport 51820 accept
        ip daddr @pull4 tcp dport 443 accept
        oifname { "docker0", "lo" } tcp sport ${toString appPort} ct state established accept
        counter drop
      }
    }
    NFT
      then
        echo "sandbox egress: failed to build the nftables layer -- sandbox-up will refuse to start" >&2
      fi

      # --- layer 1: iptables -------------------------------------------
      # Per-run pull exception lives in its own chain so the static chain
      # never changes at runtime. Created once, emptied on every rebuild.
      iptables -N sandbox-fw-pull 2>/dev/null || iptables -F sandbox-fw-pull

      # Built fully under a staging name before OUTPUT ever references it --
      # a flush-then-rebuild of the *live* chain would leave a real window
      # where OUTPUT has no restriction on this uid at all.
      iptables -F sandbox-fw-egress-staging 2>/dev/null || true
      iptables -X sandbox-fw-egress-staging 2>/dev/null || true
      iptables -N sandbox-fw-egress-staging
      iptables -A sandbox-fw-egress-staging -j sandbox-fw-pull
      # Replies on an inbound connection to the app port (accepted by the
      # docker0 INPUT allow above) are still locally generated packets from
      # this uid. ESTABLISHED only, never NEW or RELATED, and only from that
      # one source port, so this can never open a new outbound connection.
      for oif in docker0 lo; do
        iptables -A sandbox-fw-egress-staging -o "$oif" -p tcp --sport ${toString appPort} -m conntrack --ctstate ESTABLISHED -j ACCEPT
      done
      for addr in $relays; do
        iptables -A sandbox-fw-egress-staging -p udp -d "$addr" --dport 51820 -j ACCEPT
      done
      iptables -A sandbox-fw-egress-staging -j DROP

      # Cutover: insert the new (exhaustive -- every packet gets a final
      # ACCEPT/DROP from it) jump ahead of the old one before removing the
      # old one, so no packet is ever evaluated against neither.
      iptables -I OUTPUT -m owner --uid-owner "$sandbox_uid" -j sandbox-fw-egress-staging
      iptables -D OUTPUT -m owner --uid-owner "$sandbox_uid" -j sandbox-fw-egress 2>/dev/null || true

      # Old chain is now unreferenced. Rename keeps the stable name and the
      # kernel reference, so OUTPUT's jump stays valid across it.
      iptables -F sandbox-fw-egress 2>/dev/null || true
      iptables -X sandbox-fw-egress 2>/dev/null || true
      iptables -E sandbox-fw-egress-staging sandbox-fw-egress

      # No IPv6 is ever allowed for this uid. Added only if missing (never
      # delete-then-add), so there is no window without it.
      ip6tables -C OUTPUT -m owner --uid-owner "$sandbox_uid" -j DROP 2>/dev/null \
        || ip6tables -A OUTPUT -m owner --uid-owner "$sandbox_uid" -j DROP

      # Reference dump of both layers, root-only. If any part is missing the
      # dump fails and no reference exists, so sandbox-up refuses to start.
      if ( umask 077; ${guardState} "$sandbox_uid" > ${guardRef}.tmp ); then
        mv -f ${guardRef}.tmp ${guardRef}
      else
        rm -f ${guardRef}.tmp ${guardRef}
        echo "sandbox egress: could not dump the egress layers -- sandbox-up will refuse to start" >&2
      fi
    fi
  '';

  # While the stack is up, re-verify both egress layers every 20s and tear
  # the stack down the moment they are not exactly as built. Skips while
  # sandbox-up/down hold the lock (sandbox-up verifies on its own) and while
  # the firewall is mid-rebuild (its staged cutover keeps both layers in
  # force throughout; the next round re-checks).
  systemd.services.sandbox-guard-watch = {
    description = "Stop the sandbox stack if its egress rules change";
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.util-linux}/bin/mountpoint -q /var/lib/svc-sandbox || exit 0
      fw="$(${pkgs.systemd}/bin/systemctl is-active firewall.service || true)"
      case "$fw" in activating|reloading) exit 0 ;; esac
      exec 9>/run/sandbox.lock
      ${pkgs.util-linux}/bin/flock -n 9 || exit 0
      if ${guardCheck}; then exit 0; fi
      exec 9>&-
      echo "egress rules no longer as built -- stopping the stack" >&2
      /run/current-system/sw/bin/sandbox-down
    '';
  };
  systemd.timers.sandbox-guard-watch = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "20s";
      AccuracySec = "1s";
    };
  };

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

      # Fail closed before anything starts: both host egress layers
      # (networking.firewall.extraCommands, above) must be present, exactly
      # as the firewall built them, matching the allowlist, with no leftover
      # pull exception. A stale one from an earlier unclean run is cleared
      # first -- clearing only ever narrows.
      pull_exception_clear || true
      ${guardCheck} || { echo "sandbox-up: host egress layers not in place -- refusing to start (nixos-rebuild switch first?)" >&2; exit 1; }
      probe_host_blocked || { echo "sandbox-up: host egress probe got through -- refusing to start" >&2; exit 1; }

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

      # The images get pulled fresh by svc-sandbox's own podman on every run
      # (its storage root is the tmpfs above, wiped on teardown). That pull
      # is a host-level HTTPS connection from svc-sandbox, so it needs a
      # narrow, temporary exception: TCP 443 to these registries' currently
      # resolved addresses only, in both layers' dedicated pull chain/set.
      # Every image is pulled up front, then the exception is removed and
      # both layers re-verified before anything starts -- if removal or
      # verification fails, the stack is torn down, and the exception is
      # also cleared by every teardown. Nothing runs while it exists.
      #
      # Each address is taken from a completed TLS handshake whose
      # certificate validated for that exact hostname, so a spoofed DNS
      # answer adds nothing. -4: this uid gets no IPv6 at all anyway.
      # These three keep their blob downloads on the same hostname (not a
      # CDN pool with rotating addresses), which is why they were chosen.
      reg_ips=""
      for reg_host in ghcr.io pkg-containers.githubusercontent.com mirror.gcr.io; do
        reg_ip="$(${pkgs.curl}/bin/curl -4 -s --max-time 5 -o /dev/null -w '%{remote_ip}' "https://$reg_host/" 2>/dev/null)" || true
        printf '%s' "$reg_ip" | ${grep} -qxE '${ipv4Re}' || continue
        ${ipt} -A sandbox-fw-pull -p tcp -d "$reg_ip" --dport 443 -j ACCEPT
        ${nft} add element inet ${nftTable} pull4 "{ $reg_ip }"
        reg_ips="$reg_ips $reg_ip"
      done

      if ! pc pull; then
        echo "sandbox-up: image pull failed" >&2
        teardown
      fi
      pull_exception_clear || true
      ${guardCheck} || { echo "sandbox-up: egress layers not back to baseline after the pull" >&2; teardown; }
      probe_host_blocked || { echo "sandbox-up: host egress probe got through after the pull" >&2; teardown; }

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

      verify_netns || teardown

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
      #
      # PROBE_ADDRS: addresses that must be unreachable from inside the
      # stack -- every host address, the host's default gateway, the
      # rootless namespace's own gateway, and the addresses podman/pasta
      # map back to the host (DNS forwarder, guest-address map), plus the
      # tailnet resolver.
      PROBE_ADDRS="$(
        { ${pkgs.iproute2}/bin/ip -4 -o addr show | ${pkgs.gawk}/bin/awk '$2 != "lo" {print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1
          ${pkgs.iproute2}/bin/ip -4 route show default | ${pkgs.gawk}/bin/awk '{print $3}'
          printf '%s\n' ${netnsGw} 169.254.1.1 169.254.1.2 100.100.100.100
        } | ${grep} -xE '${ipv4Re}' | ${pkgs.coreutils}/bin/sort -u | ${pkgs.coreutils}/bin/tr '\n' ' '
      )"
      POD_DIR="$HOME_DIR" PODMAN="${pkgs.podman}/bin/podman" HOST_IP="$HOST_IP" HOST_GEO="$HOST_GEO" PROBE_ADDRS="$PROBE_ADDRS" \
        ${pkgs.coreutils}/bin/timeout 300 \
        ${pkgs.util-linux}/bin/runuser -u svc-sandbox --whitelist-environment=POD_DIR,PODMAN,HOST_IP,HOST_GEO,PROBE_ADDRS \
        -- ${pkgs.bash}/bin/bash "$HOME_DIR/check.sh"

      # Everything re-verified once more with the full stack running.
      ${guardCheck} || { echo "sandbox-up: egress layers changed during startup" >&2; teardown; }
      verify_netns || teardown
      probe_host_blocked || { echo "sandbox-up: host egress probe got through with the stack running" >&2; teardown; }

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
