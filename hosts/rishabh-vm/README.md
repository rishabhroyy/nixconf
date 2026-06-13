# rishabh-vm

Reusable x86_64 NixOS server configuration for Rishabh's self-hosted service
stack. This flake is intentionally separate from the `rishabh-nix` desktop
host.

It preserves the existing identity and application configuration:

- hostname and Tailscale name: `rishabh-vm`
- domains under `rishabhroy.com`
- SSH keys in `keys/`
- dedicated SOPS recipient in `.sops.yaml`
- encrypted `secrets.yaml`
- Authentik, Portainer, Copyparty, Pyrodactyl, and Wings configuration

It is provider-neutral and does not assume a particular disk size.

## Services

- Caddy provides public HTTPS and automatic certificate renewal over port 443.
- Authentik provides SSO for every human-facing web application.
- Portainer CE uses native OAuth with Authentik.
- Copyparty consumes Authentik identity headers and allows anonymous access
  only through explicitly created share links.
- Pyrodactyl uses the checked-in Authentik middleware.
- Wings runs natively and manages game-server containers through Docker.
- Tailscale advertises the server as an exit node.
- NixOS, containers, and Wings update automatically on schedules.

## Hardware Baseline

The flake targets `x86_64-linux` and expects UEFI.

The checked-in `hardware-configuration.nix` is a portable starter using:

- an ext4 root filesystem labeled `nixos`
- a vfat EFI system partition labeled `ESP`, mounted at `/boot`
- common SATA, NVMe, USB, and VirtIO initrd modules

The main configuration enables systemd-boot for the default UEFI target.
Before deploying, replace `hardware-configuration.nix` with the target
machine's generated hardware configuration. This is the only file intended to
contain machine-specific filesystem and kernel-module details.

Recommended resources depend heavily on game-server workloads. Start with at
least 4 CPU cores, 16 GiB RAM, and 150 GB storage.

## DNS

Point these A records at the server's public IPv4 address:

- `auth.rishabhroy.com`
- `cloud.rishabhroy.com`
- `docker.rishabhroy.com`
- `games.rishabhroy.com`
- `wings.rishabhroy.com`

Remove AAAA records unless the server has working public IPv6. If using
Cloudflare DNS, keep the records **DNS only**. Port 80 remains closed; Caddy
uses TLS-ALPN-01 over port 443.

## Firewall

The NixOS firewall permits only:

- TCP 22 for key-only SSH
- TCP 443 for HTTPS
- TCP 2022 for Wings SFTP
- UDP 41641 for direct Tailscale connections
- TCP and UDP 25565-25575 for game allocations

Mirror those rules in any provider, router, or upstream firewall. Keep outbound
access available for Nix caches, GitHub, container registries, Tailscale, and
certificate authorities.

Adjust the game allocation range in both `configuration.nix` and
`services.nix` if needed.

## Dedicated SOPS Key

The dedicated private age key remains outside the repository:

```text
~/.config/sops/age/rishabh-vm.txt
```

Verify it matches the recipient in `.sops.yaml`:

```bash
age-keygen -y ~/.config/sops/age/rishabh-vm.txt
sed -n 's/^[[:space:]]*- \(age1.*\)$/\1/p' hosts/rishabh-vm/.sops.yaml
```

Both commands must print:

```text
age1zhy9xragqd6hmkszt6aeqaeex6qfg4ee7m9r2880sc4aqzx58cvs02ndnp
```

Edit the encrypted secrets file with:

```bash
cd hosts/rishabh-vm
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" sops secrets.yaml
```

Back up the private key separately. During installation, place it on the target
at `/var/lib/sops-nix/key.txt`, owned by root with mode `0400`.

## Secrets

The encrypted `secrets.yaml` contains:

- Tailscale enrollment key
- Pyrodactyl database credentials and Laravel application key
- generated Wings configuration
- Authentik database, secret, and bootstrap credentials
- Portainer bootstrap password and OAuth secret
- Pyrodactyl SSO middleware secret

Existing cryptographic identities and database passwords may be retained for a
future deployment. Do not rotate database passwords, application keys, or
Authentik's secret merely by editing SOPS after services contain persistent
data; those require coordinated service-specific rotation.

Before a new deployment, decrypt the file and inspect placeholders:

```bash
cd hosts/rishabh-vm
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" \
  sops --decrypt secrets.yaml | grep -n REPLACE
```

The Wings placeholder is expected until a Pyrodactyl node exists. Generate a
fresh Tailscale auth key if the stored enrollment key has expired or was
revoked.

No outbound email is configured. Authentik's initial account is `akadmin` with
the non-routable address `akadmin@rishabh-vm.invalid`. Create users manually;
public signup and email password resets are unavailable.

## Prepare For New Hardware

From a NixOS installer on the future x86_64 target:

1. Partition and format the target using your preferred installer workflow.
2. Label the ext4 root filesystem `nixos`.
3. Label the vfat EFI system partition `ESP` and mount it at `/mnt/boot`.
4. Mount root at `/mnt`.
5. Generate hardware configuration:

   ```bash
   sudo nixos-generate-config --root /mnt
   ```

6. Review `/mnt/etc/nixos/hardware-configuration.nix`.
7. Replace this repository's `hosts/rishabh-vm/hardware-configuration.nix`
   with the reviewed generated file.
8. Ensure the generated file and `configuration.nix` do not define conflicting
   bootloaders or filesystems.
9. Commit and push the hardware change before installation so automatic
   upgrades can fetch the same configuration later.

For non-UEFI systems, replace the systemd-boot settings in `configuration.nix`.
For unusual storage, encryption, RAID, ZFS, or provider images, configure the
filesystems and required modules appropriately in `hardware-configuration.nix`.

## Install NixOS

From the mounted NixOS installer environment:

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"

sudo install -Dm0400 /path/to/rishabh-vm.txt \
  /mnt/var/lib/sops-nix/key.txt

sudo nixos-install --no-root-passwd \
  --flake 'github:rishabhroyy/nixconf?dir=hosts/rishabh-vm#rishabh-vm'
```

Do not reboot unless installation completes successfully. After reboot, remove
the previous SSH host key from the client and connect as `rishabh`:

```bash
ssh-keygen -R "SERVER_IP_OR_HOSTNAME"
ssh rishabh@"SERVER_IP_OR_HOSTNAME"
```

`ssh-keygen -R` only modifies the client's local `known_hosts` file.

## First Boot

Verify the base system:

```bash
cat /etc/os-release
hostname
lsblk -f
df -h /
sudo systemctl --failed
sudo tailscale status
sudo docker ps
sudo systemctl list-timers
```

In Tailscale, approve `rishabh-vm` as an exit node and confirm device key expiry
is disabled.

Open `https://auth.rishabhroy.com` and sign in as `akadmin` using the Authentik
bootstrap password. Enroll MFA and create a second administrator identity.

The checked-in Authentik blueprint creates the Portainer OAuth provider and the
Copyparty/Pyrodactyl proxy providers. Open each application once while signed
into Authentik:

- `https://docker.rishabhroy.com`
- `https://cloud.rishabhroy.com`
- `https://games.rishabhroy.com`

Portainer creates OAuth users as standard users; a timer promotes only
`akadmin` to administrator. Pyrodactyl automatically provisions users after
Authentik succeeds.

## Configure Wings

Create the Pyrodactyl node with:

- FQDN: `wings.rishabhroy.com`
- SSL: enabled
- behind proxy: enabled
- daemon port: `443`
- daemon SFTP port: `2022`
- server data directory: `/var/lib/pterodactyl/volumes`

Choose memory, disk, CPU, and allocation limits appropriate for the future
hardware.

Copy the complete generated node YAML from **Admin > Nodes > rishabh-vm >
Configuration** into `pterodactyl_wings_config`:

```bash
cd hosts/rishabh-vm
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" sops secrets.yaml
git add secrets.yaml
git commit -m "configure rishabh-vm wings"
git push
```

Deploy it:

```bash
sudo nixos-rebuild switch \
  --flake 'github:rishabhroyy/nixconf?dir=hosts/rishabh-vm#rishabh-vm'
```

Wings automatically downloads the verified release matching the host
architecture.

## Access Boundaries

Every human-facing web UI is gated by Authentik:

- Portainer uses native OAuth.
- Copyparty consumes Authentik identity headers.
- Pyrodactyl uses the checked-in SSO middleware.
- Copyparty share links remain usable without an Authentik account.

Browser SSO cannot protect SSH, game ports, Wings SFTP, or non-browser
Copyparty protocols. This configuration intentionally exposes no Copyparty FTP,
SFTP, SMB, or WebDAV authentication.

Wings SFTP uses port 2022 and SSH keys registered by each Pyrodactyl user.
Non-administrator users can use SFTP for servers where they have the required
file permissions.

## Updates And Maintenance

The server reads the public GitHub repository without logging into GitHub or
mutating it.

Automatic jobs cover:

- NixOS package and configuration upgrades
- container image updates with readiness checks
- verified Wings updates
- certificate renewal
- failed-service recovery
- Nix and Docker garbage collection
- local database/configuration dumps

This nested flake intentionally has no `flake.lock`, so automatic upgrades
resolve current `nixos-26.05` and sops-nix revisions. Advance the NixOS release
approximately every six months and Authentik's pinned release line as needed.

Automatic maintenance cannot recover lost user data, fix incompatible upstream
releases, renew domains, repair failed hardware, or replace external backups
and monitoring.

Useful checks:

```bash
sudo systemctl --failed
sudo journalctl -u caddy -u pterodactyl-wings --since today
sudo docker ps
sudo systemctl list-timers
sudo systemctl status rishabh-vm-healthcheck.timer
sudo systemctl status rishabh-vm-disk-guard.timer
```

Database dumps are retained for 14 days under `/var/backups/rishabh-vm`.
