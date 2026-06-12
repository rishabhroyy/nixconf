# rishabh-vm

Separate NixOS flake for the Oracle Cloud Ampere ARM server. It does not import
or modify the `rishabh-nix` host.

## Architecture

- Native Caddy owns public HTTPS and automatic Let's Encrypt renewal.
- Port 80 stays closed. Caddy can renew with TLS-ALPN-01 over port 443.
- Docker app ports bind only to `127.0.0.1`.
- Authentik declaratively protects every human-facing application.
- Authentik follows its current PostgreSQL-only deployment layout and persists
  its shared application state under `/var/lib/authentik/data`.
- Copyparty consumes Authentik identity headers directly and permits anonymous
  access only to explicitly created `/share/...` links.
- Portainer CE uses its native OAuth support with Authentik.
- Pyrodactyl uses a small checked-in Authentik SSO middleware because upstream
  Pyrodactyl does not currently provide native OAuth/OIDC.
- Wings is deliberately not placed behind interactive SSO: Panel, browser
  consoles, and file transfers authenticate to it using Pterodactyl-compatible
  tokens.
- Wings runs natively because it manages game containers through Docker.
- NixOS 26.05 stable upgrades daily; a systemd timer pulls container images
  daily and only restarts services whose images changed; Wings updates daily
  from Pterodactyl's verified official ARM64 release.

## Confirmed OCI Hardware

- Architecture: ARM64 Ampere
- Shape: 4 OCPUs and 24 GiB RAM
- Boot volume: 200 GB

The Disko configuration destroys and recreates the entire boot disk as GPT,
with a 1 GiB EFI system partition, 8 GiB encrypted swap, and the remainder
(roughly 191 GB) as the NixOS root filesystem. It does not touch separately
attached block volumes.

## DNS

Point these A records at the OCI public IPv4 address:

- `auth.rishabhroy.com`
- `cloud.rishabhroy.com`
- `docker.rishabhroy.com`
- `games.rishabhroy.com`
- `wings.rishabhroy.com`

Remove any AAAA records unless the VM has working public IPv6.

If DNS is hosted by Cloudflare, keep these records **DNS only** rather than
proxied. Port 80 is closed, so Caddy obtains and renews certificates with the
TLS-ALPN-01 challenge directly over port 443.

## OCI Network Security List

The NixOS firewall is authoritative. Mirror it in OCI:

- TCP 22 from your home IP if practical, otherwise from anywhere
- TCP 443 from anywhere
- TCP 2022 from anywhere for Pterodactyl's authenticated SFTP service
- UDP 41641 from anywhere for direct Tailscale connections
- TCP and UDP 25565-25575 from anywhere for game allocations
- No rule for TCP 80
- No rules for 8080, 9000, 9001, or 3923

Adjust the game allocation range in `configuration.nix` and OCI together when
needed.

Keep OCI egress open so the server can reach GitHub, container registries,
Tailscale, Nix caches, and certificate authorities.

## Create The Dedicated SOPS Key

The dedicated private key is stored outside the repository on the Mac:

```text
~/.config/sops/age/rishabh-vm.txt
```

Its public recipient is in `.sops.yaml`. It is intentionally separate from
the desktop key in `~/.config/sops/age/keys.txt`.

Verify that the private key matches `.sops.yaml`:

```bash
age-keygen -y ~/.config/sops/age/rishabh-vm.txt
sed -n 's/^[[:space:]]*- \(age1.*\)$/\1/p' hosts/rishabh-vm/.sops.yaml
```

Both commands must print:

```text
age1zhy9xragqd6hmkszt6aeqaeex6qfg4ee7m9r2880sc4aqzx58cvs02ndnp
```

To edit the encrypted secrets file:

```bash
cd hosts/rishabh-vm
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" sops secrets.yaml
```

Back up `~/.config/sops/age/rishabh-vm.txt` to an encrypted password manager,
encrypted backup disk, or another secure location. Losing both the Mac and this
key means losing the ability to decrypt `secrets.yaml`.

To rotate this dedicated key later, generate a new key outside the repository,
replace the recipient in `.sops.yaml`, and run `sops updatekeys secrets.yaml`:

```bash
age-keygen -o ~/.config/sops/age/rishabh-vm-new.txt
age-keygen -y ~/.config/sops/age/rishabh-vm-new.txt
```

During installation, copy the dedicated key to `/var/lib/sops-nix/key.txt` on
the target. The target copy must be owned by root with mode `0400`.

## Fill Every Secret

Start in the VM flake directory and open the encrypted file:

```bash
cd hosts/rishabh-vm
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt"
sops secrets.yaml
```

Put the following values into the matching YAML fields. Generate each password
independently; do not reuse values.

### Locally Generated Secrets

Generate and save Portainer's bootstrap password. The server generates the
bcrypt hash at runtime and uses the plaintext once to enable native OAuth:

```bash
openssl rand -hex 32  # portainer_admin_password
```

Generate separate database passwords:

```bash
openssl rand -hex 32  # pterodactyl_db_password
openssl rand -hex 32  # pterodactyl_db_root_password
openssl rand -hex 32  # authentik_postgres_password
openssl rand -hex 48  # portainer_oauth_client_secret
openssl rand -hex 48  # pyrodactyl_sso_secret
```

Generate the Pyrodactyl Laravel application key:

```bash
printf 'base64:%s\n' "$(openssl rand -base64 32 | tr -d '\n')"
```

Put the complete single output line beginning with `base64:` in
`pterodactyl_app_key`.

Generate Authentik's secret key and bootstrap password:

```bash
openssl rand -hex 48  # authentik_secret_key
openssl rand -hex 32  # authentik_bootstrap_password
```

Authentik's initial username is `akadmin`. Save the plaintext
`authentik_bootstrap_password` in your password manager.

No real email address is required. The bootstrap account receives the
non-routable identity `akadmin@rishabh-vm.invalid`. Authentik and Pyrodactyl
are not configured to send outbound email, public signup is not configured,
and password-reset emails will not work. Create users yourself in Authentik
and use the documented administrator recovery path when needed.

### Tailscale Auth Key

The recommended path is a tagged server because tagged-device key expiry is
disabled by default:

1. Open <https://login.tailscale.com/admin/acls/file>.
2. Add a `tagOwners` entry if `tag:server` does not already exist:

   ```json
   "tagOwners": {
     "tag:server": ["autogroup:admin"]
   }
   ```

3. Save the policy, then open <https://login.tailscale.com/admin/settings/keys>.
4. Select **Generate auth key**.
5. Give it a description such as `rishabh-vm provisioning`.
6. Enable **Pre-approved** and `tag:server`. Do not enable **Ephemeral**.
7. A one-off key is sufficient for this single install. Enable **Reusable**
   only if you intentionally want the same key to recover/re-enroll the server.
8. Generate the key and put the full `tskey-auth-...` value in
   `tailscale_auth_key`.

Alternative without tags: generate a pre-approved, non-ephemeral auth key,
install the VM, then open the Machines page and manually select **Disable key
expiry** for `rishabh-vm`.

The auth key itself expires in at most 90 days, but the enrolled tagged
device's node-key expiry is disabled by default. After installation, open the
Tailscale Machines page, approve `rishabh-vm` as an exit node, and verify that
device key expiry is disabled. You may then revoke the reusable auth key; the
already-enrolled machine remains authorized.

### Pyrodactyl Wings Config

Leave `pterodactyl_wings_config` at its placeholder during initial installation.
It can only be obtained after the Panel is running and a node has been created.
The first-login section below explains how to retrieve and save it.

### Save And Verify

Save and exit the SOPS editor. Confirm that no ordinary secret placeholder
remains. The Wings placeholder is expected until after the first installation:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" \
  sops --decrypt secrets.yaml | grep -n 'REPLACE'
```

Before installation, the only expected output is the Wings configuration
placeholder. After configuring Wings, this command should produce no output.

DNS records and the OCI public IP address are intentionally not SOPS fields.

### Secret Lifecycle

Several values are initialization credentials or cryptographic identities, not
ordinary passwords that can be rotated by editing SOPS alone. After first boot,
do not change the database passwords, `pterodactyl_app_key`,
`authentik_secret_key`, `authentik_bootstrap_password`, or
`portainer_admin_password` without a coordinated service-specific rotation or
recovery procedure. Changing only the encrypted file can make an existing
database or application inaccessible.

The Tailscale auth key can be revoked after the machine is enrolled. Rotating
`portainer_oauth_client_secret` requires restarting the Authentik worker so its
blueprint reapplies, then running `configure-portainer-oauth.service`.

## Install From Ubuntu

This procedure replaces Ubuntu with NixOS and permanently deletes every file
and partition on the OCI boot disk. The destructive installation commands are
run interactively while SSHed into the server. OCI recovery is not part of the
normal path; keep the OCI web console available only as a last resort.

### 1. Prepare The Mac

The Mac needs SOPS, age, Git, and SSH. It does not need Nix because NixOS is
installed from the temporary installer running on the server. Check the tools:

```bash
command -v sops age-keygen openssl ssh git
```

Install any missing SOPS or age tools with Homebrew:

```bash
brew install sops age
```

### 2. Finish External Setup

Before wiping Ubuntu:

1. Create all five DNS A records listed above and wait for them to resolve.
2. Apply the OCI ingress and egress rules listed above.
3. Fill every pre-install secret; only the Wings placeholder may remain.
4. Verify the dedicated SOPS key and back it up outside this repository.
5. Commit and push `hosts/rishabh-vm` so automatic upgrades can fetch it later.

The repository is public, so neither the Mac nor server needs to be logged
into GitHub.

Verify the public DNS records from the Mac:

```bash
for host in auth cloud docker games wings; do
  printf '%s: ' "$host"
  dig +short A "$host.rishabhroy.com"
done
```

Every command must print the OCI public IPv4 address.

### 3. Inspect The Ubuntu Server

Set the public IP once, confirm Ubuntu SSH works, and inspect the boot disk:

```bash
cd /Users/rishabh/Documents/GitHub/nixconf
export SERVER_IP="REPLACE_WITH_OCI_PUBLIC_IP"

ssh ubuntu@"$SERVER_IP" \
  'uname -m; lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL; sudo test -d /sys/firmware/efi && echo UEFI'
```

Stop unless the output shows:

- `aarch64`
- Ubuntu mounted from `/dev/sda`
- `/dev/sda` is the approximately 200 GB boot disk
- `UEFI`

Change `disko.nix` before proceeding if the boot disk is not `/dev/sda`. Do not
guess: the next step recreates `/dev/sda`'s partition table and erases all
Ubuntu files on it.

### 4. Confirm Secrets And Repository State On The Mac

The Wings placeholder is expected before first boot; no other placeholder is:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" \
  sops --decrypt hosts/rishabh-vm/secrets.yaml | grep -n 'REPLACE'

git status --short
git add README.md hosts/rishabh-vm
git commit -m "add rishabh-vm"
git push
```

Review `git status` before staging and ensure only the intended VM files are
included. The encrypted `secrets.yaml` must be committed and pushed. Never
commit the private SOPS key. If these files were already committed, skip the
commit command and just push.

### 5. Kexec From Ubuntu Into The NixOS Installer

SSH into Ubuntu. Copy the existing Ubuntu user's authorized keys to root so the
RAM-only installer imports them, then launch the ARM64 kexec installer:

```bash
ssh ubuntu@"$SERVER_IP"

sudo install -d -m0700 /root/.ssh
sudo install -m0600 "$HOME/.ssh/authorized_keys" /root/.ssh/authorized_keys
sudo test -s /root/.ssh/authorized_keys
command -v curl || sudo apt-get update
command -v curl || sudo apt-get install -y curl ca-certificates

sudo -i
set -o pipefail
curl -fL \
  https://github.com/nix-community/nixos-images/releases/latest/download/nixos-kexec-installer-noninteractive-aarch64-linux.tar.gz \
  | tar -xzf- -C /root
/root/kexec/run
```

The kexec command waits briefly and then replaces Ubuntu with a NixOS installer
running entirely in RAM. SSH disconnecting is expected. No disk has been wiped
yet, and the installer preserves the old SSH host key.

### 6. Reconnect And Transfer The SOPS Key

Wait about a minute, then reconnect from the Mac as root:

```bash
ssh root@"$SERVER_IP"
```

Keep that installer SSH session open. In a second Mac terminal, transfer the
dedicated SOPS key into the RAM-only installer:

```bash
export SERVER_IP="REPLACE_WITH_OCI_PUBLIC_IP"
scp "$HOME/.config/sops/age/rishabh-vm.txt" \
  root@"$SERVER_IP":/tmp/rishabh-vm-sops-age-key.txt
```

Back in the installer SSH session, verify the architecture, disk, network, and
transferred key before destroying anything:

```bash
chmod 0400 /tmp/rishabh-vm-sops-age-key.txt
uname -m
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL
ip address
ping -c 3 github.com
test -s /tmp/rishabh-vm-sops-age-key.txt
```

Stop unless this still shows `aarch64` and the approximately 200 GB boot disk
as `/dev/sda`.

### 7. Wipe Ubuntu And Install NixOS

Run the destructive phase inside `tmux` so a Mac Wi-Fi drop does not kill the
installation session. In the root installer SSH session, install the temporary
tools and start `tmux`:

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"

nix profile install \
  github:NixOS/nixpkgs/nixos-26.05#git \
  github:NixOS/nixpkgs/nixos-26.05#tmux

tmux new -s nixos-install
```

If SSH disconnects during the install, reconnect and reattach:

```bash
ssh root@"$SERVER_IP"
tmux attach -t nixos-install
```

Inside the `tmux` session, run the commands below. Disko destroys the complete
`/dev/sda` partition table and mounts the new filesystems below `/mnt`:

```bash
git clone https://github.com/rishabhroyy/nixconf.git /tmp/nixconf

cd /tmp/nixconf
nix flake metadata --no-write-lock-file ./hosts/rishabh-vm

nix run github:nix-community/disko/latest -- \
  --mode destroy,format,mount ./hosts/rishabh-vm/disko.nix

mount | grep ' /mnt'
lsblk -f

install -Dm0400 /tmp/rishabh-vm-sops-age-key.txt \
  /mnt/var/lib/sops-nix/key.txt

nixos-install --no-root-passwd --flake ./hosts/rishabh-vm#rishabh-vm
sync
reboot
```

The `disko` command is the irreversible wipe. Do not run it unless `/dev/sda`
was positively identified as the intended OCI boot disk. After it runs, verify
that both the new root and EFI filesystems are mounted below `/mnt`. Do not
reboot unless `nixos-install` completes successfully. If SSH drops before
Disko, rebooting should return to Ubuntu. If SSH drops after Disko starts,
first reconnect as `root` and reattach to `tmux`. If the installer itself is no
longer reachable after the wipe, Ubuntu is gone; the practical recovery choices
are the OCI serial console or rebuilding/reinstalling the boot volume.

### 8. Verify The Fresh NixOS Boot

After `nixos-install` finishes and the VM has rebooted, the Ubuntu account no
longer exists and the final NixOS SSH host key will have changed. The
`ssh-keygen -R` command below only removes the old key from the Mac's local
`known_hosts` file; it does not touch the server and is safe to run even if no
old entry exists. Then connect with the configured `rishabh` account:

```bash
ssh-keygen -R "$SERVER_IP"
ssh rishabh@"$SERVER_IP"
cat /etc/os-release
hostname
lsblk -f
df -h /
swapon --show
sudo systemctl --failed
exit
```

Confirm the operating system is NixOS, the hostname is `rishabh-vm`, `/` is
the large ext4 partition on `/dev/sda`, and the encrypted swap is active. If
SSH does not return, first wait a few minutes and confirm the OCI instance is
running and TCP 22 is still allowed. The OCI serial console is only a last
resort; if it is unavailable, the realistic fallback is to reinstall/rebuild
the boot volume from the start rather than rerunning destructive commands
blindly.

## First Login

```bash
export SERVER_IP="REPLACE_WITH_OCI_PUBLIC_IP"
ssh rishabh@"$SERVER_IP"
sudo systemctl --failed
sudo tailscale status
sudo docker ps
```

Open `https://auth.rishabhroy.com` and log in as `akadmin` using the Authentik
bootstrap password. The checked-in Authentik blueprint automatically creates
the Portainer OAuth provider plus the Copyparty and Pyrodactyl proxy providers,
applications, and embedded-outpost assignments. Confirm all three applications
appear under **Applications**. No manual provider wiring is required.

Enroll a WebAuthn security key or TOTP authenticator for `akadmin`, and create a
second Authentik administrator account as a recovery identity. Authentik is the
gate for every human-facing application, so protecting and retaining access to
it is essential.

### Create Users Without Email

Authentik does not need to send signup or verification email in this setup.
There is no public signup flow. Create each account yourself under **Directory
> Users**, set its password, and give it a unique email-shaped identity such as
`alice@rishabh-vm.invalid`. The reserved `.invalid` domain cannot receive mail;
the value exists only because Pyrodactyl requires a unique valid-looking email
when its SSO middleware creates the matching panel user.

Users sign in with the credentials you set and should enroll MFA. Authentik
administrators can reset a user's password directly or create a recovery link
without configuring SMTP. Portainer identifies users by username, and
Pyrodactyl automatically provisions them on their first visit.

Open `https://games.rishabhroy.com` while signed into Authentik. The SSO
middleware automatically creates the matching Pyrodactyl user. The Authentik
bootstrap user `akadmin` becomes the initial Pyrodactyl administrator.

Open `https://docker.rishabhroy.com` to create the matching Portainer OAuth
user. Portainer creates OAuth users as standard users; an idempotent five-minute
timer promotes only `akadmin` to Portainer administrator.

Node settings:

- FQDN: `wings.rishabhroy.com`
- Communicate over SSL: yes
- Behind proxy: yes
- Daemon port: `443`
- Daemon SFTP port: `2022`
- Server data directory: `/var/lib/pterodactyl/volumes`
- Total memory: at most `18432` MiB, with memory over-allocation disabled
- Total disk: about `120000` MiB, with disk over-allocation disabled. This
  leaves roughly 70 GB for NixOS, containers, Copyparty data, and local backups.

The service normalizes the generated Wings config on every start so that:

- Wings API listens only on `127.0.0.1:8080` behind Caddy.
- Wings TLS stays disabled internally because Caddy terminates TLS.
- Caddy's loopback address is the only trusted proxy.
- SFTP stays on its authenticated SSH-based service port `2022`.
- All root, log, archive, backup, temporary, and server-data paths use the
  persistent `/var/lib/pterodactyl` layout.

Copy the node's generated Wings YAML into `pterodactyl_wings_config`:

1. In Pyrodactyl, open **Admin > Nodes > rishabh-vm > Configuration**.
2. Copy the complete YAML configuration shown by the panel.
3. Open the SOPS file with the command below.
4. Replace the indented Wings placeholder after `pterodactyl_wings_config: |`
   with the complete config, keeping it indented beneath the `|`.

```bash
cd hosts/rishabh-vm
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/rishabh-vm.txt" sops secrets.yaml
git add secrets.yaml
git commit -m "configure rishabh-vm wings"
git push
```

Then deploy:

```bash
sudo nixos-rebuild switch \
  --flake github:rishabhroyy/nixconf?dir=hosts/rishabh-vm#rishabh-vm
```

Create allocations using the VM's public IPv4 and ports 25565-25575.
Keep the combined CPU limits of simultaneously running game servers at or below
roughly 300% so one of the four Ampere cores remains available to the host,
databases, SSO, reverse proxy, and maintenance jobs.

Verify Wings after deploying its configuration:

```bash
sudo systemctl status pterodactyl-wings
sudo journalctl -u pterodactyl-wings --since today
```

## Copyparty

`cloud.rishabhroy.com` uses Authentik header-based SSO and has no anonymous
volume permissions. Authenticated Authentik users are placed in Copyparty's
built-in `acct` group. Share links created while signed in are served under
`/share/...` and remain usable by recipients without an Authentik account.

Copyparty's web UI works through browser SSO. Typical WebDAV clients cannot
complete an interactive Authentik browser login, and FTP, FTPS, SFTP, and SMB
cannot carry an Authentik browser session either. Because no Copyparty-local
passwords are configured and no extra protocol ports are exposed, those access
methods are intentionally unavailable in this flake. SMB is especially
unsuitable for exposure to the public internet.

## SSO Boundary

Every human-facing web UI is gated by Authentik:

- `docker.rishabhroy.com`
- `cloud.rishabhroy.com`, except explicit `/share/...` links
- `games.rishabhroy.com`, except the token-authenticated `/api/remote/...`
  machine API used by Wings

`wings.rishabhroy.com`, game allocation ports, SSH, and Wings SFTP cannot use
browser SSO. Wings provides SFTP, not FTP. Use the host, port, and username
shown by Pyrodactyl. Every user who needs SFTP should add their own SSH public
key from **Account > SSH Keys**. Non-administrator users can use SFTP for
servers they own or servers where they were explicitly granted the `file.sftp`
permission. The exact SFTP username is shown in each server's **Settings** page
and has the form `username.server-id`.

Their Authentik password is never accepted by Wings, even if the Pyrodactyl UI
claims the SFTP password matches the panel password. Use the registered SSH key
instead; no shared SFTP password is stored in SOPS. Adding Authentik
forward-auth to Wings would break Panel communication and browser console
WebSockets.

Portainer uses native OAuth. Copyparty consumes Authentik headers. Pyrodactyl
uses the checked-in `pyrodactyl-sso` middleware, which automatically provisions
users and logs them into the panel after Authentik succeeds. Pyrodactyl is
pre-release software and this middleware patches its Laravel middleware list at
container startup; if an upstream update changes that integration point, the
container deliberately fails instead of silently running without SSO.

## Updates

The server does not log into GitHub and does not mutate this repository.
`system.autoUpgrade` fetches the public GitHub flake, evaluates it, and switches
the machine to it. Container and Wings timers independently fetch current
upstream releases.

This nested flake intentionally has no `flake.lock`. On each automatic upgrade,
Nix resolves the current revisions of the `nixos-26.05`, Disko, and sops-nix
inputs, so package details and versions advance without committing anything to
the repository. The tradeoff is that a build is not perfectly reproducible
later. Adding a lock file would improve reproducibility, but then a separate
trusted workflow would need to update, test, commit, and push that lock file
before the server could consume newer Nix inputs.

Automatic updates cover NixOS packages, this flake after it is pushed to
GitHub, application containers, Wings, certificate renewal, service restarts,
garbage collection, and local database dumps. They cannot automatically fix an
incompatible upstream release, expired domain registration, OCI account issues,
lost secrets, a full disk containing irreplaceable user data, or hardware/cloud
failures.

`rishabhroyy/nixconf` is publicly readable, so the GitHub flake URL works
without a GitHub login. Auto-upgrade only reads the repository; it never
commits, pushes, or otherwise mutates it.

Container image updates are tracked with persistent pending markers. A changed
image triggers an immediate database/config dump, then is restarted only after
all pulls have been attempted. Its marker is removed only after the relevant
database health check or HTTP readiness check succeeds. If a pull or restart
fails, the next daily run retries it. This avoids restarting every database and
application merely because the update timer ran.

## Explicit Assumptions

These values were not all stated explicitly and should be reviewed before
installation:

- The OCI VM has 4 Ampere OCPUs, 24 GiB RAM, and a 200 GB boot volume.
- The OCI boot disk is `/dev/sda`; verify with `lsblk`.
- The server timezone should be `America/Los_Angeles`.
- TCP/UDP `25565-25575` is enough for game allocations.
- Public key-only SSH on TCP 22 is desired as a recovery path.
- Eight GiB of swap, 14 days of local database dumps, and the documented
  maintenance times are acceptable.
- `auth.rishabhroy.com` and `wings.rishabhroy.com` may be added alongside the
  three subdomains you specified because Authentik and Wings need endpoints.
- The Authentik bootstrap identity `akadmin` should be administrator in
  Pyrodactyl and Portainer.

## Maintenance And Recovery

### Expected Involvement

For ordinary operation, expect no weekly or monthly maintenance. The server
automatically applies routine package and application updates, renews
certificates, restarts failed services, cleans disposable data, and creates
local database dumps.

Plan on a short review roughly every three months and a required configuration
update at least every six months:

- Authentik supports only its two newest release lines. Review its release notes
  and advance `authentikImage` to a newer supported line when appropriate.
- NixOS stable releases every six months. Advance `nixos-26.05` before it stops
  receiving security fixes.
- Check `systemctl --failed`, remaining disk space, domain renewal, OCI account
  status, and whether Tailscale still shows `rishabh-vm` as connected with key
  expiry disabled.
- Configure each game server's own Pyrodactyl schedule or startup updater if you
  want that game's binaries, mods, or plugins updated automatically. The host
  can update Pyrodactyl and Wings, but it cannot safely guess how to upgrade
  every game workload.

Unplanned involvement is still possible after an incompatible upstream
container release, a failed NixOS upgrade, disk exhaustion from user/game data,
lost credentials, DNS changes, or an OCI outage. Because no external monitoring
or remote backup was requested, the server cannot notify you or recover
irreplaceable Copyparty files, game worlds, or other user data on its own.

Useful checks:

```bash
sudo systemctl --failed
sudo journalctl -u caddy -u pterodactyl-wings --since today
sudo docker ps
sudo systemctl list-timers
sudo systemctl status rishabh-vm-healthcheck.timer
sudo systemctl status rishabh-vm-disk-guard.timer
```

Database dumps are kept for 14 days under `/var/backups/rishabh-vm`. External
boot-volume backups and uptime monitoring are optional and are not required by
this setup.

No configuration can honestly guarantee that a public, automatically upgraded
server will never need intervention. This setup automatically restarts failed
services, verifies Wings downloads, renews certificates, backs up databases,
updates applications, reclaims disposable data above 85% disk usage without
deleting stopped game-server containers, upgrades NixOS, and reboots in a
maintenance window.
