{ pkgs, ... }:
{
  microvm = {
    vcpu = 4;
    mem = 8192;
    hypervisor = "qemu";
    interfaces = [{
      type = "user"; # NAT egress only; reachability is over Tailscale, not the LAN.
      id = "vm-hermes";
      mac = "02:00:00:00:00:01";
    }];
    volumes = [{
      # This image file lives on the host's root disk (single ext4 fs, no
      # separate /var partition -- see hardware-configuration.nix) at
      # /var/lib/microvms/hermes/var.img. It's a disk image, not a bind mount:
      # nothing inside the guest's /var (including /home, below) touches the
      # host's real filesystem or the host's real /home/rishabh.
      image = "/var/lib/microvms/hermes/var.img";
      mountPoint = "/var";
      # 150GiB ceiling, not a fixed allocation: microvm.nix creates this via
      # `truncate` (sparse file) and QEMU mounts it with discard=unmap, so it
      # only grows as the guest writes data and shrinks back when the guest
      # deletes + TRIMs (see services.fstrim below). /home lives here too
      # (bind mount below), not just agent state.
      size = 153600;
    } {
      # Writable overlay for /nix/store (see writableStoreOverlay below).
      # Own image rather than a subdir of var.img -- untested combo, keep
      # it isolated in case ordering/mounting turns out to matter.
      image = "/var/lib/microvms/hermes/nix-rw-store.img";
      mountPoint = "/nix/.rw-store";
      size = 51200;
    }];
    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
        # readOnly defaults to false in microvm.nix -- the "ro-store" tag
        # name is just a convention, it doesn't actually enforce anything.
        readOnly = true;
      }
      {
        # Plaintext secrets, decrypted host-side from the regular
        # secrets.yaml and copied in by hermes-secrets-sync.service on the
        # host (see configuration.nix) -- this guest never holds a sops key.
        source = "/var/lib/microvms/hermes/secrets";
        mountPoint = "/run/host-secrets";
        tag = "secrets";
        proto = "virtiofs";
        readOnly = true;
      }
    ];

    # Overlays the nix-rw-store volume (above) as the writable upper layer
    # on top of the /nix/.ro-store host share, merged at /nix/store. Guest
    # keeps reusing the host's pre-built paths but can also `nix profile
    # install` / `nix shell` / build things itself -- writes land in the
    # overlay, which persists (it's a real volume, unlike root).
    writableStoreOverlay = "/nix/.rw-store";
    # Doc warning: registerClosure (on by default) "may be incompatible
    # with a persistent writable store overlay." Verify boot succeeds with
    # both on before relying on this; if not, this is the first thing to
    # flip off.
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "hermes-agent";

  # Periodic TRIM so deleted guest data actually frees space back on the
  # host's sparse var.img (the QEMU drive already has discard=unmap wired).
  services.fstrim.enable = true;

  # /home is on ephemeral root by default; bind-mount it onto this guest's
  # OWN persistent /var volume (var.img above) so anything dropped there
  # survives a reboot. This is the guest's isolated /var/home -- not the
  # host's real /home/rishabh, which the guest can't see at all.
  systemd.tmpfiles.rules = [ "d /var/home 0755 root root -" ];
  fileSystems."/home" = {
    device = "/var/home";
    fsType = "none";
    options = [ "bind" ];
  };

  # Root is rebuilt from the Nix store every boot; only /var persists.
  # Host keys must live on /var or SSH trust resets every boot.
  services.openssh = {
    enable = true;
    hostKeys = [{
      path = "/var/lib/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }];
  };

  users.users.rishabh = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keyFiles = [
      ../keys/mac.pub
      ../keys/windows.pub
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  services.tailscale = {
    enable = true;
    authKeyFile = "/run/host-secrets/tailscale_auth_key";
  };

  # Assumes the account is already linked/registered (signal-cli's state
  # lives in ~/.local/share/signal-cli, under rishabh's persistent /home --
  # if it's not registered yet, run signal-cli manually first, then this
  # will pick up that same state on every start). Bound to localhost only,
  # matching the manual command this replaces -- nothing else in the guest
  # needs to reach it over the network.
  #
  # Phone number comes from the synced secret (/run/host-secrets), not a
  # literal here -- an earlier version hardcoded it and it ended up
  # committed and pushed to a public repo.
  systemd.services.signal-cli-daemon = {
    description = "signal-cli HTTP daemon";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "rishabh";
      ExecStart = pkgs.writeShellScript "signal-cli-daemon" ''
        exec ${pkgs.signal-cli}/bin/signal-cli --account "$(cat /run/host-secrets/signal_phone_number)" daemon --http 127.0.0.1:8080
      '';
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Hermes itself is installed as a plain package (flake.nix), not through
  # services.hermes-agent -- that module ties the CLI to a shared, package-
  # manager-"managed" HERMES_HOME and unconditionally drops a `.managed`
  # marker in it, which makes `hermes setup` / `hermes config edit` refuse
  # to run. Going unmanaged means `hermes setup` works normally as rishabh,
  # and with no HERMES_HOME override, it defaults to ~/.hermes --
  # i.e. /home/rishabh/.hermes, which is already persistent (the /home
  # bind mount above). Nothing further needed for persistence.

  # ponytail: baseline coding toolchain -- agent has nothing to build/run
  # projects with otherwise. Extend here (declaratively) as needed; agent
  # can also self-serve extra system packages at runtime via `nix profile
  # install` / `nix shell` (writableStoreOverlay above), and ad-hoc
  # pip/npm/uv into project dirs or $HOME always just worked.
  environment.systemPackages = with pkgs; [
    git
    python3
    uv
    nodejs
    pnpm
    signal-cli
  ];

  system.stateVersion = "24.05";
}
