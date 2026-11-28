# Homelab mode: the default state of this machine. Windows (the win11 VM)
# only runs on request, and while it's off the host owns everything --
# all 16 CPUs, all 32 GiB, the RX 6700 XT, keyboard and mouse -- and the
# monitor shows the dashboard in homelab/.
#
#   win11.service    start = hand the GPU/CPUs/RAM to Windows and boot it,
#                    stop  = shut Windows down (OpenSSH inside it), give it
#                            all back, bring homelab.target up again.
#   homelab.target   everything that needs the 6700 XT while Windows is off:
#                    the kiosk, and later GPU workloads. A GPU workload joins
#                    it with
#                      wantedBy = [ "homelab.target" ];
#                      partOf = [ "homelab.target" ];
#                      unitConfig.ConditionPathExists = "!/run/homelab/windows";
#                    (the condition keeps a nixos-rebuild switch from starting
#                    it while Windows has the card).
#   dashboard        always on, on :80 (loopback for the kiosk, tailnet for
#                    everything else) and https://rishabh-nix.<tailnet>:443.
#
# Preview the dashboard on any machine with
#   python3 hosts/rishabh-nix/homelab/server.py --demo --port 8080
{ config, pkgs, lib, ... }:

let
  cpus = import ./cpu-layout.nix;
  stacks = import ./stacks.nix config.virtualisation.oci-containers.containers;

  gpu = "0000:2f:00.0";
  # Windows' OpenSSH, used to shut it down cleanly from outside: its admin
  # account and its name. Reached over Tailscale (MagicDNS); Windows
  # Firewall doesn't let SSH in over the LAN.
  winSsh = "rishabh@rishabh-pc";
  sshKey = "/var/lib/homelab/win11_ed25519";
  # 16 GiB in 2 MiB pages; matches <memory> in win11-template.xml.
  hugepages = 8192;
  hugepagesPath = "/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages";
  # Exists while Windows owns the GPU, so nothing restarts homelab.target.
  windowsMarker = "/run/homelab/windows";

  path = with pkgs; [ coreutils gnugrep gnused procps psmisc systemd libvirt openssh util-linux efibootmgr gawk ];

  # Shared by the start/stop scripts and the lifecycle monitor.
  common = ''
    export LC_ALL=C
    mkdir -p /run/homelab

    # Mode + message for the dashboard. Messages never contain quotes.
    set_state() {
      printf '{"mode":"%s","message":"%s","since":%s}\n' "$1" "$2" "$(date +%s)" > /run/homelab/state.json.tmp
      mv /run/homelab/state.json.tmp /run/homelab/state.json
      echo "homelab: $1 $2"
    }

    domstate() { virsh domstate win11 2>/dev/null || true; }

    # $1 = CPU list for the host, $2 = same as hex mask, $3 = 1 to keep the
    # VM cores out of deep C-states (cheap wakeups for the guest), 0 to let
    # them sleep normally.
    split_cpus() {
      systemctl set-property --runtime system.slice user.slice init.scope AllowedCPUs="$1"
      echo "$2" > /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true
      echo "$2" > /proc/irq/default_smp_affinity 2>/dev/null || true
      # Some IRQs (kernel-managed ones) refuse a new affinity; that's fine.
      for IRQ in /proc/irq/*/smp_affinity_list; do echo "$1" > "$IRQ" 2>/dev/null || true; done
      for CPU in ${cpus.isolatedWords}; do
        for STATE in /sys/devices/system/cpu/cpu$CPU/cpuidle/state*/; do
          case "$(cat "$STATE/name" 2>/dev/null)" in
            POLL|C1) ;;
            *) echo "$3" > "$STATE/disable" 2>/dev/null || true ;;
          esac
        done
      done
    }

    # The firmware/amdgpu text console sits on the 6700 XT's framebuffer.
    console_bind() {
      for VT in /sys/class/vtconsole/vtcon*; do
        grep -q "frame buffer" "$VT/name" 2>/dev/null && echo "$1" > "$VT/bind" 2>/dev/null || true
      done
    }

    gpu_nodes() { ls /dev/dri/by-path/pci-${gpu}-* 2>/dev/null || true; }
    gpu_users() {
      NODES="$(gpu_nodes)"
      [ -n "$NODES" ] || return 0
      PIDS="$(fuser $NODES 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ' || true)"
      [ -n "$PIDS" ] && ps -o comm= -p $PIDS | sort -u | tr '\n' ' ' || true
    }

    # Undo everything win11.service start did. Safe to run twice: the
    # marker is gone after the first run.
    give_back() {
      [ -e ${windowsMarker} ] || return 0
      echo 0 > ${hugepagesPath} || true
      split_cpus "${cpus.all}" "${cpus.allMask}" 0
      if systemctl is-system-running 2>/dev/null | grep -qE 'stopping'; then
        rm -f ${windowsMarker}
        return 0
      fi
      # libvirt rebinds the GPU to amdgpu right after QEMU exits.
      for _ in $(seq 1 30); do
        readlink /sys/bus/pci/devices/${gpu}/driver 2>/dev/null | grep -q amdgpu && break
        sleep 1
      done
      console_bind 1
      rm -f ${windowsMarker}
      # Even without the GPU, the rest of homelab.target may still be useful.
      systemctl start --no-block homelab.target
      readlink /sys/bus/pci/devices/${gpu}/driver 2>/dev/null | grep -q amdgpu
    }
  '';

  start = pkgs.writeShellScript "win11-start" ''
    set -uo pipefail
    ${common}

    case "$(domstate)" in
      "shut off") ;;
      *) set_state windows ""; exit 0 ;;
    esac

    fail() {
      echo "win11 start failed: $1" >&2
      give_back || true
      set_state error "$1"
      exit 1
    }

    touch ${windowsMarker}
    set_state starting "Handing the GPU to Windows"
    # One call, so it waits for every member's stop job, not just the target.
    systemctl stop homelab.target $(systemctl show -p Wants --value homelab.target)

    for _ in $(seq 1 10); do
      [ -z "$(gpu_users)" ] && break
      sleep 1
    done
    USERS="$(gpu_users)"
    [ -z "$USERS" ] || fail "GPU still in use by $USERS"
    console_bind 0

    set_state starting "Reserving memory"
    echo ${toString hugepages} > ${hugepagesPath}
    if [ "$(cat ${hugepagesPath})" -lt ${toString hugepages} ]; then
      sync
      echo 3 > /proc/sys/vm/drop_caches
      echo 1 > /proc/sys/vm/compact_memory
      echo ${toString hugepages} > ${hugepagesPath}
    fi
    GOT="$(cat ${hugepagesPath})"
    [ "$GOT" -ge ${toString hugepages} ] || fail "Only $((GOT / 512)) of $((${toString hugepages} / 512)) GB free for Windows"

    split_cpus "${cpus.housekeeping}" "${cpus.housekeepingMask}" 1

    set_state starting "Booting Windows"
    virsh start win11 || fail "Windows failed to start, see journalctl -u win11"
    set_state windows ""
  '';

  stop = pkgs.writeShellScript "win11-stop" ''
    set -uo pipefail
    ${common}

    case "$(domstate)" in
      "shut off") ;;
      crashed)
        # Already dead (on_crash=preserve kept it for inspection).
        virsh destroy win11 || true
        ;;
      *)
        set_state stopping "Shutting down Windows"
        if ! ssh -i ${sshKey} -o BatchMode=yes -o ConnectTimeout=5 \
             -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/lib/homelab/known_hosts \
             ${winSsh} 'shutdown /s /t 0'; then
          echo "OpenSSH shutdown failed; falling back to the ACPI power button" >&2
          virsh shutdown win11 || true
        fi
        for _ in $(seq 1 240); do
          [ "$(domstate)" = "shut off" ] && break
          sleep 1
        done
        if [ "$(domstate)" != "shut off" ]; then
          # Never force it. The lifecycle monitor finishes the handoff
          # whenever Windows does stop.
          set_state windows "Windows did not shut down. Shut it down from inside"
          exit 1
        fi
        ;;
    esac

    if give_back; then
      set_state homelab ""
    else
      set_state error "GPU did not return to Linux. Reboot to recover"
    fi
  '';
in
{
  # ---------------------------------------------------------
  # Windows on demand
  # ---------------------------------------------------------
  systemd.services.win11 = {
    description = "Windows 11 (owns the GPU while active)";
    requires = [ "define-win11-vm.service" "libvirtd.service" ];
    wants = [ "network-online.target" ];
    # Stop order on host shutdown is the reverse: Windows goes down over
    # SSH before the network or libvirtd do.
    after = [ "define-win11-vm.service" "libvirtd.service" "network.target" "network-online.target" ];
    inherit path;
    # A nixos-rebuild switch must never shut Windows down.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = start;
      ExecStop = stop;
      TimeoutStartSec = "3min";
      TimeoutStopSec = "5min";
    };
  };

  # Notices Windows stopping by itself (shut down from inside, crash) and
  # hands everything back. Reboots from inside stay in Windows.
  systemd.services.win11-lifecycle-monitor = {
    description = "Return to homelab mode when Windows stops";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    partOf = [ "libvirtd.service" ];
    inherit path;
    serviceConfig = {
      Restart = "always";
      RestartSec = "2s";
    };
    script = ''
      set -uo pipefail
      ${common}
      REBOOT_MARKER=/run/homelab/win11-reboot

      stdbuf -oL virsh event --all --loop --timestamp | while IFS= read -r EVENT; do
        case "$EVENT" in
          *"event 'reboot' for domain"*win11*)
            touch "$REBOOT_MARKER"
            ;;
          *"for domain"*win11*"Started"*)
            rm -f "$REBOOT_MARKER"
            ;;
          *"for domain"*win11*"Crashed"*)
            set_state crashed "Windows stopped responding"
            ;;
          *"for domain"*win11*"Stopped"*)
            (
              # Reboots briefly pass through Stopped; let them come back.
              sleep 5
              if [ -e "$REBOOT_MARKER" ] && [ $(( $(date +%s) - $(stat -c %Y "$REBOOT_MARKER") )) -le 120 ]; then
                exit 0
              fi
              [ "$(domstate)" = "shut off" ] || exit 0
              # Stopping the unit runs the handoff (its ExecStop sees the VM
              # already off). Mid-start or mid-stop, the unit handles it
              # itself. Inactive with the marker still there means an earlier
              # stop gave up waiting: hand back directly.
              case "$(systemctl show -p ActiveState --value win11.service)" in
                active) systemctl stop --no-block win11.service ;;
                activating|deactivating) ;;
                *) [ -e ${windowsMarker} ] && ${stop} ;;
              esac
            ) &
            ;;
        esac
      done
    '';
  };

  # Key the host uses to ask Windows to shut down. Add the .pub line to
  # C:\ProgramData\ssh\administrators_authorized_keys in Windows (`win key`).
  systemd.services.homelab-ssh-key = {
    description = "Generate the key for shutting Windows down over SSH";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!${sshKey}";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /var/lib/homelab
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C "rishabh-nix homelab" -f ${sshKey}
    '';
  };

  systemd.services.homelab-baremetal = {
    description = "Reboot into bare-metal Windows once";
    inherit path;
    serviceConfig.Type = "oneshot";
    script = ''
      ${common}
      BOOTNUM="$(efibootmgr | awk 'BEGIN { IGNORECASE = 1 }
        /^Boot[0-9A-F]{4}/ && /Windows Boot Manager/ { b = $1; gsub(/^Boot|\*/, "", b); print b; exit }')"
      if [ -z "$BOOTNUM" ] || ! efibootmgr --bootnext "$BOOTNUM" >/dev/null; then
        set_state error "No Windows Boot Manager entry to boot into"
        exit 1
      fi
      # The reboot stops win11.service first, so a running VM shuts down cleanly.
      systemctl --no-block reboot
    '';
  };

  # ---------------------------------------------------------
  # Homelab mode: kiosk on the 6700 XT
  # ---------------------------------------------------------
  systemd.targets.homelab = {
    description = "Homelab mode (GPU workloads and the kiosk)";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!${windowsMarker}";
  };

  systemd.tmpfiles.rules = [
    "d /run/homelab 0755 root root -"
    "d /var/lib/homelab 0700 root root -"
  ];

  # cage picks the 6700 XT only, never the Quadro (wlroots splits
  # WLR_DRM_DEVICES on ':', so it can't take the by-path name directly).
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", KERNEL=="card*", KERNELS=="${gpu}", SYMLINK+="dri/homelab-gpu"
  '';

  users.users.kiosk = {
    isNormalUser = true;
    extraGroups = [ "video" "render" "input" ];
  };

  services.cage = {
    enable = true;
    user = "kiosk";
    environment.WLR_DRM_DEVICES = "/dev/dri/homelab-gpu";
    program = pkgs.writeShellScript "homelab-kiosk" ''
      PATH=${lib.makeBinPath (with pkgs; [ coreutils gnugrep gawk wlr-randr curl ])}

      # cage stretches the window across every monitor. Keep only the one
      # picked on the dashboard (/var/lib/homelab-dashboard/display, first
      # monitor by name if unset) and switch the rest off; re-checked every
      # 2 s, so a pick or a hotplug applies on its own.
      (
        APPLIED=""
        while :; do
          OUTPUTS="$(wlr-randr | awk '/^[^ ]/ { print $1 }' | sort)"
          WANT="$(cat /var/lib/homelab-dashboard/display 2>/dev/null)"
          printf '%s\n' "$OUTPUTS" | grep -qx "$WANT" || WANT="$(printf '%s\n' "$OUTPUTS" | head -n1)"
          KEY="$WANT $(echo $OUTPUTS)"
          if [ -n "$OUTPUTS" ] && [ "$KEY" != "$APPLIED" ]; then
            ARGS=""
            for O in $OUTPUTS; do
              if [ "$O" = "$WANT" ]; then ARGS="$ARGS --output $O --on"; else ARGS="$ARGS --output $O --off"; fi
            done
            wlr-randr $ARGS && APPLIED="$KEY"
          fi
          sleep 2
        done
      ) &

      until curl -sf -o /dev/null http://127.0.0.1/; do sleep 1; done
      exec ${pkgs.chromium}/bin/chromium \
        --kiosk --ozone-platform=wayland --no-first-run --noerrdialogs \
        --disable-infobars --disable-features=Translate --password-store=basic \
        --check-for-update-interval=31536000 \
        --renderer-process-limit=1 --disable-extensions \
        --disable-background-networking --disable-component-update \
        --hide-scrollbars \
        --disable-background-timer-throttling --disable-renderer-backgrounding \
        --disable-backgrounding-occluded-windows \
        http://127.0.0.1/
    '';
  };

  # The kiosk's "Local shell" button: a login on tty9 (outside logind's
  # autovt range, so nothing else claims it). Logging out (`exit`) ends the
  # unit and puts the kiosk back on screen. The button restarts it, so a
  # session left behind is replaced, never resumed.
  systemd.services.homelab-shell = {
    description = "Local login on the kiosk monitor";
    unitConfig.ConditionPathExists = "!${windowsMarker}";
    # A rebuild must not kick you out of a running shell.
    restartIfChanged = false;
    environment.TERM = "linux";
    serviceConfig = {
      ExecStartPre = "${pkgs.kbd}/bin/chvt 9";
      ExecStart = "${pkgs.util-linux}/bin/agetty --noclear --login-program ${config.services.getty.loginProgram} - linux";
      ExecStopPost = "${pkgs.kbd}/bin/chvt 1";
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYPath = "/dev/tty9";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      UtmpIdentifier = "tty9";
      IgnoreSIGPIPE = false;
      SendSIGHUP = true;
    };
  };

  systemd.services.cage-tty1 = {
    wantedBy = [ "homelab.target" ];
    partOf = [ "homelab.target" ];
    after = [ "homelab-dashboard.service" ];
    # Keeps cage.nix's own /dev/tty1 condition; repeated conditions are ANDed.
    unitConfig.ConditionPathExists = lib.mkForce [ "/dev/tty1" "!${windowsMarker}" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3s";
    };
  };

  # ---------------------------------------------------------
  # Dashboard (kiosk + remote control)
  # ---------------------------------------------------------
  users.users.homelab = {
    isSystemUser = true;
    group = "homelab";
  };
  users.groups.homelab = { };

  systemd.services.homelab-dashboard = {
    description = "Homelab dashboard";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.systemd ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${./homelab}/server.py --port 80 --state-dir /var/lib/homelab-dashboard --config ${
        pkgs.writeText "homelab.json" (builtins.toJSON {
          inherit gpu;
          vmCpus = cpus.isolatedList;
          disks = [ "/" "/mnt/data4" ];
          stacks = lib.genAttrs stacks.names stacks.units;
        })
      }";
      # Remembers the kiosk's monitor; readable by the kiosk user.
      StateDirectory = "homelab-dashboard";
      StateDirectoryMode = "0755";
      User = "homelab";
      Group = "homelab";
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      Restart = "always";
    };
  };

  # The dashboard user may start/stop Windows, reboot/power off and switch the
  # monitor to a login prompt, nothing else.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "homelab") return;
      var unit = action.lookup("unit"), verb = action.lookup("verb");
      if (unit == "win11.service" && (verb == "start" || verb == "stop")) return polkit.Result.YES;
      if (unit == "homelab-shell.service" && verb == "restart") return polkit.Result.YES;
      if ((unit == "reboot.target" || unit == "poweroff.target" || unit == "homelab-baremetal.service") && verb == "start")
        return polkit.Result.YES;
    });
  '';

  # :80 on the tailnet (and loopback), never the LAN: the dashboard can
  # power the machine off. HTTPS on :443 via tailscale serve.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];
  systemd.services.homelab-tailscale-serve = {
    description = "Serve the dashboard over HTTPS on the tailnet";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # tailscaled may still be logging in.
      for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
        ${config.services.tailscale.package}/bin/tailscale serve --bg --https=443 http://127.0.0.1:80 && exit 0
        ${pkgs.coreutils}/bin/sleep 2
      done
      exit 1
    '';
  };

  # Under contention on the shared housekeeping CPUs, the VM's own threads
  # (vhost-net carries Parsec) win over containers. A priority, not a cap.
  systemd.slices.machine.sliceConfig.CPUWeight = 1000;

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "win" ''
      set -eu
      [ "$(id -u)" = 0 ] || exec /run/wrappers/bin/sudo "$0" "$@"
      case "''${1:-status}" in
        on) exec systemctl start win11.service ;;
        off) exec systemctl stop win11.service ;;
        baremetal) exec systemctl start homelab-baremetal.service ;;
        key) cat ${sshKey}.pub ;;
        status) cat /run/homelab/state.json 2>/dev/null || echo '{"mode":"homelab"}' ;;
        *) echo "usage: win on|off|status|baremetal|key" >&2; exit 2 ;;
      esac
    '')
    (pkgs.writeShellScriptBin "reboot-to-windows" ''exec win baremetal'')
  ];
}
