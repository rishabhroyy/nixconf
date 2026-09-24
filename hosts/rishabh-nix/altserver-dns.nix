{ config, lib, pkgs, ... }:

# Unicast DNS-SD ("wide-area Bonjour", RFC 6763) responder so AltStore on
# the phone can find AltServer (Windows VM) over Tailscale -- plain mDNS
# is multicast-only and Tailscale never carries it between nodes. Answers
# static PTR/TXT/A records for _altserver._tcp under a made-up zone, plus
# a live-tracked SRV record; Tailscale's split-DNS sends the phone's
# queries for that zone to this box instead of the public internet.
#
# AltServer binds a random ephemeral port every launch (confirmed: 61502
# one run, 50161 the next -- no documented flag/config to pin it), so the
# SRV record's port can't be a static value like the rest of the zone. rishabh-nix
# shares a LAN bridge (br0) with the Windows VM, so avahi here can browse
# AltServer's real mDNS broadcast and just mirror whatever port it's
# actually using right now.
let
  zone = "altserver.internal";
  srvStateFile = "/var/lib/altserver-dns/srv.conf";
in
{
  sops.secrets.altserver_tailnet_name = {};
  sops.secrets.altserver_server_id = {};

  # cname/txt-record reference secrets, so they can't be baked into
  # dnsmasq's normal (world-readable, nix-store) settings file -- rendered
  # instead into a root-only file at activation time and pulled in via
  # dnsmasq's own conf-file include.
  sops.templates."altserver-dns.conf" = {
    content = ''
      cname=win11.${zone},rishabh-pc.${config.sops.placeholder.altserver_tailnet_name}
      txt-record=AltServer._altserver._tcp.${zone},serverID=${config.sops.placeholder.altserver_server_id}
    '';
    restartUnits = [ "dnsmasq.service" ];
  };

  # Browses (never publishes) mDNS, scoped to the LAN bridge only -- this
  # box has no business advertising itself over Bonjour, it just needs to
  # see AltServer's real announcement to read its live port back out.
  services.avahi = {
    enable = true;
    interfaces = [ "br0" ];
    publish.enable = false;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/altserver-dns 0755 root root -"
    "f ${srvStateFile} 0644 root root -"
  ];

  systemd.services.altserver-port-sync = {
    description = "Mirror AltServer's live mDNS port into the DNS-SD zone";
    after = [ "avahi-daemon.service" ];
    requires = [ "avahi-daemon.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      port=$(${pkgs.avahi}/bin/avahi-browse -r -t -p _altserver._tcp 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F';' '$1=="="{print $9; exit}')

      # AltServer not currently announcing (off, or between launches) --
      # leave the last-known-good port in place rather than clobbering it.
      if [ -z "$port" ]; then
        exit 0
      fi

      newline="srv-host=AltServer._altserver._tcp.${zone},win11.${zone},$port,0,0"
      if [ "$(cat ${srvStateFile} 2>/dev/null)" != "$newline" ]; then
        echo "$newline" > ${srvStateFile}
        ${pkgs.systemd}/bin/systemctl reload-or-restart dnsmasq.service
      fi
    '';
  };

  systemd.timers.altserver-port-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10s";
      OnUnitActiveSec = "30s";
    };
  };

  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false; # this box's own DNS resolution is untouched
    settings = {
      port = 53;
      interface = "tailscale0";
      bind-interfaces = true;
      no-resolv = true;
      no-hosts = true;
      domain-needed = true;
      conf-file = [
        config.sops.templates."altserver-dns.conf".path
        srvStateFile
      ];

      ptr-record = [
        "_altserver._tcp.${zone},AltServer._altserver._tcp.${zone}"
      ];
    };
  };

  # Same scoping pattern as sandbox-podman.nix's docker0 rule: only the
  # tailscale interface, only port 53, nothing else touched.
  networking.firewall.interfaces."tailscale0".allowedUDPPorts = [ 53 ];
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 53 ];
}
