# Deployment & Testing Plan: Ghost-Host

This document outlines the step-by-step process for deploying the Ghost-Host NixOS configuration and testing the Windows 11 VM bypass capabilities.

## Phase 1: Secrets & Configuration Prep (Do this on your MacBook)

**Yes! It is highly recommended to do all secret generation on your MacBook first.** This way, your `nixconf` repository is 100% ready to deploy before you even touch the target machine.

### 1. Extract Motherboard Identifiers
If you haven't already, get the physical UUID and Serial Number from the target machine (you can do this via Windows PowerShell before wiping, or via a live Linux USB):
- **Windows:** `Get-WmiObject win32_baseboard | Select-Object SerialNumber` and `Get-WmiObject win32_computersystemproduct | Select-Object UUID`
- **Linux:** `sudo cat /sys/class/dmi/id/product_uuid` and `sudo cat /sys/class/dmi/id/board_serial`

### 2. Generate Your SOPS Key & Encrypt Secrets (On MacBook)
We use `sops-nix` to securely store these values. You can do this on your Mac using Homebrew (or Nix if you have it installed).
1. Install the required tools on your Mac:
   ```bash
   brew install age sops
   ```
2. Generate an Age key:
   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   ```
   *CRITICAL: Backup this `keys.txt` file securely (e.g., to a password manager or secure USB drive). You will need to physically copy it to the target machine later!*
3. Get your **public key** from the output above (it starts with `age1...`), and create a `.sops.yaml` in the root of the repository:
   ```yaml
   creation_rules:
     - path_regex: hosts/rishabh-nix/secrets.yaml$
       key_groups:
       - age:
         - "age1yourpublickey..." # Replace with your public key
   ```
4. Generate a secure hash for your `rishabh` login password. If you don't have `mkpasswd` on Mac, you can generate an SHA-512 crypt hash using Python:
   ```bash
   python3 -c "import crypt, getpass; print(crypt.crypt(getpass.getpass(), crypt.mksalt(crypt.METHOD_SHA512)))"
   ```
   *Type your desired password and copy the resulting hash string.*
5. **Download your GPU BIOS**: Download your `6700xt.rom` from TechPowerUp and save it exactly as `hosts/rishabh-nix/6700xt.rom` inside this repository.
6. Edit `hosts/rishabh-nix/secrets.yaml` to include:
   - Your extracted `motherboard_uuid` and `motherboard_serial`
   - Your `tailscale_auth_key` (this automatically authenticates BOTH the host and sidecars!)
   - Your `user_password` hash
   - Your `ssh_public_key` (Find this on your Mac by running `cat ~/.ssh/id_ed25519.pub`. This is how you will SSH into the NixOS host securely).
   - Your `ssh_public_key_windows` (Grab this from your Windows VM if you have one, or leave it blank/duplicate your Mac key if you don't).
6. Encrypt the file:
   ```bash
   sops -e -i hosts/rishabh-nix/secrets.yaml
   ```
7. Commit and push your changes to GitHub. Your repo is now ready!

---

## Phase 2: Installing NixOS on the Target

1. Boot the NixOS Live USB on the target machine.
2. Connect to the internet.
3. Partition and format your target NixOS drive (Disk 2) and mount it to `/mnt`.
4. Generate your hardware config:
   ```bash
   nixos-generate-config --root /mnt
   ```
5. Clone your fully prepped repository to the live environment:
   ```bash
   git clone https://github.com/rishabhroyy/nixconf.git /mnt/etc/nixos/nixconf
   ```
6. Copy the `hardware-configuration.nix` generated in step 4 into your cloned repo:
   ```bash
   cp /mnt/etc/nixos/hardware-configuration.nix /mnt/etc/nixos/nixconf/hosts/rishabh-nix/
   ```
7. **The most important step:** Transfer your `keys.txt` from your Mac (via a secure USB stick) to the target machine exactly where SOPS expects it:
   ```bash
   mkdir -p /mnt/root/.config/sops/age/
   cp /path/to/usb/keys.txt /mnt/root/.config/sops/age/keys.txt
   ```
8. Install NixOS using your flake:
   ```bash
   nixos-install --flake /mnt/etc/nixos/nixconf#rishabh-nix
   ```
9. **Reboot:** You are done with the live USB!
   ```bash
   reboot
   ```
10. **Set your Samba Password:** Once your new NixOS system has booted up and you log in, open a terminal and set your SMB password (which Windows will use to access the drives):
   ```bash
   sudo smbpasswd -a rishabh
   ```
---

## Phase 2: VM Network Bootstrapping

Because we pass through the physical NVMe, your Windows 11 OS will boot perfectly. I have explicitly added `<boot order='1'/>` to the NVMe passthrough block in the XML, so the virtual UEFI will automatically attempt to boot from it immediately.

We are passing the **physical 2.5GbE Realtek NIC** directly into the VM. This means the Windows 11 VM behaves exactly as if it were plugged into your router physically with that port.

**How to prepare the network driver:**
If Windows 11 doesn't already have the Realtek 2.5Gbe drivers installed:
1. Download the latest Realtek 2.5GbE network drivers on your physical Windows install *before* installing NixOS, and leave them on your Desktop.
2. Once the VM boots, simply install the Realtek drivers from your Desktop as normal. 
3. The VM will instantly connect to your router via the 2.5G port and grab its own DHCP IP. NixOS will use the 1G port on the motherboard for its own connection.

---

## Phase 3: Anti-Cheat Verification (Testing)

Before launching Vanguard or Genshin, perform these checks inside the Windows 11 guest:

### 1. SMBIOS & Licensing Check
Open PowerShell as Administrator:
```powershell
Get-WmiObject win32_baseboard | Format-List Product,Manufacturer,SerialNumber,Version
Get-WmiObject win32_computersystemproduct | Format-List UUID
```
**Expected Result**: The output MUST match your physical motherboard exactly. Windows Activation should say "Windows is activated with a digital license linked to your Microsoft account".

### 2. Hyper-V Stealth Check
Open Task Manager -> Performance -> CPU.
- Ensure "Virtualization: Enabled" is shown.
- Ensure that you do **not** see "Virtual Machine: Yes".

### 3. Device Manager Audit
Open Device Manager. Ensure there are **NO** devices with the following names:
- Red Hat VirtIO Balloon
- QEMU USB Tablet
- Standard VGA Graphics Adapter (unless it's your actual secondary GPU)
- QEMU Harddisk

### 4. Vanguard Test
1. Launch the Riot Client and start Vanguard.
2. Reboot the VM as requested by Vanguard.
3. Launch Valorant. Run a standard Deathmatch.
4. If you complete the Deathmatch without an "Error VAN9001" or "VAN152", the stealth configuration has successfully bypassed the KVM heuristic checks!
