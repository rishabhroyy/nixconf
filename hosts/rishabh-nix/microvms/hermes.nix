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

  services.hermes-agent = {
    enable = true;
    # DeepSeek direct for now. deepseek-chat/deepseek-reasoner were retired
    # 2026-07-24; deepseek-v4-flash is the current cheap model ($0.0028/M
    # cache-hit, $0.14/M cache-miss input, $0.28/M output -- thinking mode is
    # its default, so it already spends more reasoning tokens on hard
    # problems and stays cheap on easy ones, no separate "pro" tier needed
    # day to day). For a specific hard task, switch models for that session
    # only with `/model deepseek:deepseek-v4-pro` in the TUI -- no rebuild.
    # Subagents (delegation) use the same cheap model; they're usually doing
    # narrower, simpler work than the main loop. base_url is intentionally
    # NOT set here -- the deepseek provider plugin's own built-in default
    # (https://api.deepseek.com/v1) is correct; overriding it risks getting
    # the /v1 suffix wrong.
    settings = {
      provider = "deepseek";
      model.default = "deepseek-v4-flash";
      delegation = {
        provider = "deepseek";
        model = "deepseek-v4-flash";
      };
      # The deepseek provider plugin's built-in aux-model fallback is still
      # "deepseek-chat" (retired 2026-07-24) as of this writing -- pin the
      # two aux tasks that actually fire in normal use (everything else --
      # kanban, TTS, vision -- is unused here) so they don't depend on that.
      auxiliary = {
        compression = {
          provider = "deepseek";
          model = "deepseek-v4-flash";
        };
        title_generation = {
          provider = "deepseek";
          model = "deepseek-v4-flash";
        };
      };
    };
    environmentFiles = [ "/run/host-secrets/hermes_env" ];
    addToSystemPackages = true;
  };

  # ponytail: baseline coding toolchain -- agent has nothing to build/run
  # projects with otherwise. Extend here (declaratively) as needed; agent
  # can also self-serve extra system packages at runtime now via `nix
  # profile install` / `nix shell` (writableStoreOverlay above), and
  # ad-hoc pip/npm/uv into project dirs or $HOME always just worked.
  environment.systemPackages = with pkgs; [
    git
    python3
    uv
    nodejs
    pnpm
  ];

  system.stateVersion = "24.05";
}
