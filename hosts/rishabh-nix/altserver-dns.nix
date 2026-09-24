{ config, lib, pkgs, ... }:

# Unicast DNS-SD ("wide-area Bonjour", RFC 6763) responder so AltStore on
# the phone can find AltServer (Windows VM, TCP 49500) over Tailscale --
# plain mDNS is multicast-only and Tailscale never carries it between
# nodes. Answers static PTR/SRV/TXT/A records for _altserver._tcp under a
# made-up zone; Tailscale's split-DNS sends the phone's queries for that
# zone to this box instead of the public internet.
let
  zone = "altserver.internal";
  altServerPort = 49500;
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
      conf-file = config.sops.templates."altserver-dns.conf".path;

      ptr-record = [
        "_altserver._tcp.${zone},AltServer._altserver._tcp.${zone}"
      ];
      srv-host = [
        "AltServer._altserver._tcp.${zone},win11.${zone},${toString altServerPort},0,0"
      ];
    };
  };

  # Same scoping pattern as sandbox-podman.nix's docker0 rule: only the
  # tailscale interface, only port 53, nothing else touched.
  networking.firewall.interfaces."tailscale0".allowedUDPPorts = [ 53 ];
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 53 ];
}
