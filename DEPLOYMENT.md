# Deployment Notes

This repository is a personal NixOS configuration, not a generic installer.
Before deploying, review the host-specific disk UUIDs, PCI addresses, GPU ROM,
SOPS keys, and encrypted secrets.

## Rebuild

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix --cores 14
```

This applies changes in place. Automatic upgrades use the same behavior and
never reboot the host. Kernel, initrd, bootloader, VFIO device-binding,
hugepage-reservation, and firmware changes require a later reboot before they
take effect.

## Required Secrets

Secrets are managed with `sops-nix` from `hosts/rishabh-nix/secrets.yaml`.
The host must be able to decrypt them through either:

- `/root/.config/sops/age/keys.txt`
- the configured host SSH key fallback

The VM definition expects motherboard identity and Tailscale secrets to be
available at activation time.

## Windows VM

Useful host-side checks:

```bash
sudo systemctl status define-win11-vm.service
sudo systemctl status start-win11-vm.service
sudo systemctl status win11-power-sync-monitor.service
sudo virsh list --all
sudo verify-win11-vfio
```

`verify-win11-vfio` includes the current startup journal, QEMU log tail,
boot-critical PCI reset methods and link state, hugepage availability, and
whether any legacy synchronous QEMU hook remains.

The `start-win11-vm.service` unit owns VM autostart. It disables libvirt's
independent autostart path, waits for the generated VM definition, then starts
Windows normally exactly once. It never pauses, probes, detaches, resets,
reboots, destroys, or retries the guest automatically.

The dedicated GPU, boot NVMe, SATA controller, and NIC bind directly to
`vfio-pci` during initrd and remain there for the NixOS boot. Their domain XML
uses `managed='no'`, so libvirt does not detach or reattach host drivers. Only
the two shared-ID USB controllers use libvirt-managed handoff.

The VM's hugepages are reserved once by the kernel command line and remain
reserved for the host boot. No libvirt hook compacts memory, drops caches,
allocates pages, or frees pages during VM lifecycle events. This deliberately
trades reclaiming 16 GiB after VM shutdown for deterministic subsequent starts.

Routine boot never rewrites the VM's persistent OVMF NVRAM. Secure Boot key
enrollment is an explicit maintenance action through
`sudo enroll-win11-secureboot-keys`, not part of domain definition or autostart.

The VM keeps an 8-core / 16-thread topology. Four physical cores remain shared
with NixOS, while four are isolated for latency-sensitive guest work. Only the
vCPU threads pinned to isolated cores use low-priority real-time round-robin
scheduling; QEMU housekeeping and host workloads keep normal scheduling.
Windows' first four guest cores map to the isolated cores so foreground work,
device interrupts, and DPCs are more likely to avoid host scheduling jitter.
KVM poll-control briefly waits for guest wakeups to avoid some scheduler
round trips, and `rcu_nocb_poll` prevents offloaded RCU callback processing
from repeatedly waking the isolated guest CPUs. The host NMI watchdog remains
enabled for hard-lockup diagnosis.

The host-only `win11-power-sync-monitor.service` watches libvirt lifecycle
and reboot events. It powers off NixOS only after libvirt reports the specific
normal shutdown reason `Stopped Shutdown` and the domain remains off after a
short guard period. Reboots, crashes, forced stops, failed boots, and stuck
firmware leave NixOS running. Existing NixOS shutdown or reboot transactions
are never replaced by a VM-triggered poweroff.

Useful maintenance helpers:

```bash
sudo reset-win11-vm-definition
sudo reset-win11-secureboot-nvram
sudo enroll-win11-secureboot-keys
sudo free-win11-hugepages
sudo reboot-to-windows
```

`reset-win11-secureboot-nvram` replaces the VM's persistent OVMF variables, so
use it only when firmware variables are broken or intentionally being reset.

After the previous forced resets, allow Windows Automatic Repair to finish or
boot Windows bare-metal once before returning to VFIO. Do not use `virsh reset`
as a recovery action; inspect `sudo verify-win11-vfio` and the service journal
instead.

## One-Time Boot Switching

From NixOS, arm the next host startup for the bare-metal Windows boot entry:

```bash
sudo reboot-to-windows
```

From Windows, run PowerShell as Administrator from this repo checkout:

```powershell
.\tools\windows-reboot-to-nixos.ps1
```

Both commands use UEFI BootNext/bootsequence, so the change is one-time rather
than a permanent boot order edit. `reboot-to-windows` records the request but
does not stop the VM, write BootNext early, or reboot the host. Shut down
Windows normally when ready. After that clean shutdown, the power-sync monitor
writes BootNext immediately before powering off NixOS, so an unrelated earlier
host reboot cannot consume the request. The command warns if power sync is
disabled or unavailable.

## Power Sync

Power sync is entirely host-side. A clean Windows shutdown powers off NixOS;
other VM stop reasons leave NixOS running.

```bash
sudo enable-power-sync
sudo disable-power-sync
```

`disable-power-sync` leaves the lifecycle monitor running but prevents it from
powering off NixOS. It remains effective across service restarts and
configuration switches until `enable-power-sync` is run or the NixOS host
boots again.

The physical power button requests a clean guest shutdown and lets the same
lifecycle monitor power off the host. It never cuts host power merely because
a timeout expired.

To skip VM autostart for one boot, edit the boot entry and add either:

```text
win11.no_autostart=1
```

or:

```text
no-win11-autostart
```

To disable power sync for one boot, edit the boot entry and add either kernel
parameter:

```text
win11.no_power_sync=1
```

or:

```text
no-win11-power-sync
```

## Samba

The `data4` share is intended for local network access:

```text
\\rishabh-nix\data4
```

Create or refresh the Samba password with:

```bash
sudo smbpasswd -a rishabh
```

If local name resolution fails, use the host LAN IP instead of the NetBIOS name.

Immich is also exposed on the local network:

```text
http://rishabh-nix:2283
```

## Tailscale

The host advertises itself as an exit node. Approve the route in the Tailscale
admin console, then select this machine as the exit node from a client.

## Hermes Agent MicroVM

A `microvm.nix` guest (`hermes`) runs Nous Research's Hermes Agent
(Nix/NixOS support is Tier 2 / best-effort upstream), with 4 vCPU / 8GB RAM
(carved out of the Windows VM's allocation, see "RAM budget" below) and a
disk image capped at 150GB (`/var/lib/microvms/hermes/var.img`, on the
host's root disk — the host has one ext4 filesystem, no separate `/var`
partition). That's a ceiling, not a reservation: the image is sparse and
grows/shrinks with actual usage (see "Disk sizing" below). It joins your
tailnet independently of the host and is reachable only over Tailscale, not
the LAN. Config is fully declarative, in
`hosts/rishabh-nix/microvms/hermes.nix` — nothing is set up by hand inside
the guest.

### 1. Add the API key

Same file, same key, same `sops` workflow you already use for everything
else on this host:

```bash
sops hosts/rishabh-nix/secrets.yaml
```

Add:

```yaml
hermes_env: |
  DEEPSEEK_API_KEY=sk-...              # platform.deepseek.com -> API keys
```

`hermes_env` becomes the guest's `environmentFiles` entry, so every line in
it is just `VAR=value`, one provider key per line — that's also where
you'll add `OPENROUTER_API_KEY` or a Moonshot/Kimi key later (see step 4).
Hermes reuses the host's existing `tailscale_auth_key` to join the tailnet
(no separate key) — that key must be **reusable** in the Tailscale admin
console, since both the host and Hermes authenticate with it.

The host decrypts this as usual (it's already trusted with everything in
that file). A systemd oneshot, `hermes-secrets-sync` (in
`configuration.nix`), copies out `hermes_env` and the existing
`tailscale_auth_key` to `/var/lib/microvms/hermes/secrets/`, a directory
shared read-only into the guest at `/run/host-secrets`, before the microvm
starts. The guest itself never holds a decryption key or sees the encrypted
file — if it's ever compromised it can only read those plaintext values, not
the rest of `secrets.yaml` (motherboard IDs, immich/copyparty passwords,
your login password).

### 2. Start it up

```bash
sudo nixos-rebuild switch --flake .#rishabh-nix
```

One command: builds the guest, decrypts and syncs the two secrets in, and
autostarts it (`microvm.autostart = [ "hermes" ]`). No separate file, no
separate key, no manual bootstrap step.

Windows' RAM cut (16GB -> 12GB, freeing 4GB for Hermes) needs a **host
reboot** too — see "RAM budget" below.

### 3. Verify and connect

```bash
systemctl status microvm@hermes      # on the host: is the guest up?
```

Find the guest's tailnet name/IP in the Tailscale admin console (hostname
`hermes-agent`), then:

```bash
ssh rishabh@hermes-agent             # over Tailscale, MagicDNS
systemctl status hermes-agent        # in the guest: is the agent running?
journalctl -u hermes-agent -f        # tail logs, e.g. to confirm the model/key are accepted
hermes --tui
```

`addToSystemPackages = true` puts `hermes` / `hermes-agent` / `hermes-acp` on
PATH. Because config is declarative, `hermes setup` / `hermes config set` /
`hermes config edit` / `hermes gateway install` are all blocked in-guest —
edit `hosts/rishabh-nix/microvms/hermes.nix` and rebuild instead.

The exact env var name for a new provider and the `provider`/`model.default`
string format are inferred from Hermes's docs (best-effort Tier 2 support,
not fully spelled out there) — `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY`
are confirmed, `DEEPSEEK_API_KEY` follows the same `<PROVIDER>_API_KEY`
pattern but isn't documented verbatim. If the service fails to authenticate,
`journalctl -u hermes-agent -f` will name the problem directly; fix the var
name or `settings` block in `hermes.nix` and rebuild.

### 4. Switching providers later (Kimi, OpenRouter, ...)

`hermes.nix` currently has:

```nix
services.hermes-agent.settings = {
  provider = "deepseek";
  model.default = "deepseek-v4-flash";
  delegation = {
    provider = "deepseek";
    model = "deepseek-v4-flash";
  };
  auxiliary = {
    compression.provider = "deepseek";
    compression.model = "deepseek-v4-flash";
    title_generation.provider = "deepseek";
    title_generation.model = "deepseek-v4-flash";
  };
};
```

(`model.base_url` is deliberately not set — the `deepseek` provider plugin's
own built-in default, `https://api.deepseek.com/v1`, is correct; an earlier
draft of this config overrode it to `https://api.deepseek.com`, missing the
required `/v1` suffix. The `auxiliary` block exists because the plugin's
built-in aux-model fallback is still the retired `deepseek-chat` as of this
writing — pinned here for the two aux tasks that actually fire day-to-day.)

To switch: add the new provider's key to `hermes_env` (step 1) and change
`provider`/`model.default`. `deepseek`, `openrouter`, `anthropic`, `gemini`,
`xai`, and others are native providers; Kimi/Moonshot isn't a listed native
provider, so route it through OpenRouter instead — `provider = "openrouter";`
with `model.default` set to OpenRouter's model id (e.g.
`"moonshotai/kimi-k2"` — check https://openrouter.ai/models for the exact
slug). OpenRouter also re-exposes DeepSeek and most other models under one
key, if you'd rather standardize on a single provider going forward.
Rebuild to apply.

### Cost tiering (DeepSeek only)

`deepseek-chat`/`deepseek-reasoner` were retired 2026-07-24; the config above
already uses their replacements. Two current models, same account:

- **`deepseek-v4-flash`** — what both `model.default` and `delegation.model`
  use. $0.0028/M input (cache hit) / $0.14/M input (cache miss) / $0.28/M
  output. Thinking mode is its *default* behavior — it already spends more
  reasoning tokens on hard problems and fewer on easy ones, so cost scales
  with difficulty automatically without needing a pricier model day to day.
- **`deepseek-v4-pro`** — ~3x the price ($0.435/M miss input, $0.87/M
  output). Not wired into `hermes.nix`; for an occasional genuinely hard
  task, switch just that session with `/model deepseek:deepseek-v4-pro` in
  the TUI, no rebuild needed, falls back to flash next session.

Subagents (`delegation`) stay on flash too — they're typically narrower,
simpler work than the main loop, so there's little reason to pay pro pricing
there. I didn't wire cost overrides for the `auxiliary` tasks (title
generation, session search, curator, etc.) — DeepSeek doesn't clearly
support vision/embedding under this provider, and guessing wrong there risks
silently breaking those features rather than saving a trivial amount.

**Estimated daily cost**, assuming DeepSeek's blended cache-hit/miss pricing
above (actual mix depends on how repetitive your context is session to
session — check DeepSeek's usage dashboard after a few days to calibrate):

| Usage level | Turns/day | Est. cost/day | Est. cost/month |
|---|---|---|---|
| Light (occasional chat/small tasks) | ~50 | ~$0.01 | ~$0.40 |
| Heavy (active coding agent, subagents running) | ~500 | ~$0.30 | ~$9 |

Even heavy daily use stays under $10/month on flash. The one thing that can
surprise you: a long-running gateway service that's polling/idling on a
messaging platform still makes occasional auxiliary-model calls even with no
real work happening — negligible in dollars, but don't be alarmed by a
nonzero baseline on the DeepSeek dashboard.

### Disk sizing

`size = 153600` in `hermes.nix` is a 150GB ceiling, not an upfront
allocation. microvm.nix creates `var.img` with `truncate` (a sparse file —
`ls -l` shows 150G, `du` shows actual bytes written), and QEMU mounts it with
`discard=unmap`, so space frees back to the host when the guest deletes
files, as long as TRIM runs — `services.fstrim.enable = true` in `hermes.nix`
does that periodically. Check real usage on the host with
`du -h /var/lib/microvms/hermes/var.img`, or from inside the guest with `df
-h /var`.

### Persistence inside the guest

The guest's `/` is rebuilt from the Nix store on every boot — only `/var`
persists. That now covers:

- hermes-agent's own state (`stateDir` defaults to `/var/lib/hermes` —
  linked messaging accounts, sessions, memory)
- the SSH host key (pinned to `/var/lib/ssh`, otherwise SSH trust resets
  every boot)
- **`/home`** — bind-mounted onto `/var/home` in `hermes.nix`, so anything
  you drop there by hand (dotfiles, cloned repos, ad-hoc scripts) now
  survives reboots too

Anything written outside `/var` (system packages installed imperatively,
edits to files elsewhere under `/`) is still wiped every boot — install
extra packages via `extraPackages`/`extraPythonPackages` in `hermes.nix`
instead.

### RAM budget

Total host RAM is 32GB. Windows was a static, unballooned 16GB
(`win11-template.xml`, `hugepages=16` in `vfio.nix`) — both trimmed to 12GB
to give Hermes room. **Windows' hugepage reservation is set at kernel
boot**, so the `hugepages=12` change in `vfio.nix` needs a full host reboot
(not just `nixos-rebuild switch`) to actually free the 4GB back to the pool
— until you reboot, the kernel still has 16GB of hugepages locked down even
though the VM XML only asks for 12.
