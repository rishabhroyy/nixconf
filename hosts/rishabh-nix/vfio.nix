{ config, pkgs, ... }:

let
  # The devices we want to pass through to the Windows 11 VM.
  # Keep this on the known-working global binding path.
  vfioIds = [ "1002:73df" "1002:ab28" "144d:a80a" "10ec:8125" "1b21:0612" ];
  win11PciDevices = [
    "0000:2f:00.0"
    "0000:2f:00.1"
    "0000:22:00.0"
    "0000:26:00.0"
    "0000:2a:00.1"
    "0000:2a:00.3"
    "0000:29:00.0"
  ];
in
{
  # Kernel parameters for IOMMU, VFIO, and CPU Isolation
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    # Isolate physical cores 4-7 for the Windows 11 VM.
    # Physical cores 0-3 remain shared so NixOS has room to breathe.
    "isolcpus=4-7,12-15"
    "nohz_full=4-7,12-15"
    "rcu_nocbs=4-7,12-15"
    "amd_pstate=active"
    "kvm.ignore_msrs=1"
    "kvm.report_ignored_msrs=0"
    "default_hugepagesz=1G"
    "hugepagesz=1G"
    "hugepages=16"
    ("vfio-pci.ids=" + builtins.concatStringsSep "," vfioIds)
  ];

  powerManagement.cpuFreqGovernor = "performance";

  # Enable nested virtualization for Windows VBS/Core Isolation and AVIC as a
  # normal KVM acceleration path. No live KVM ftrace/kprobe modules are loaded.
  boot.extraModprobeConfig = "options kvm_amd nested=1 avic=1";

  # Load VFIO modules
  boot.initrd.kernelModules = [
    "vfio_pci"
    "vfio"
    "vfio_iommu_type1"
  ];

  # Virtualization settings
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "ignore";
    onShutdown = "shutdown";
    qemu = {
      package = pkgs.qemu_win11;
      runAsRoot = true;
      swtpm.enable = false;
    };
  };

  systemd.services.wait-win11-vfio-devices = {
    description = "Wait for Windows 11 VFIO host devices";
    before = [ "libvirtd.service" ];
    after = [ "systemd-udev-settle.service" ];
    wants = [ "systemd-udev-settle.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      PCI_DEVICES="${builtins.concatStringsSep " " win11PciDevices}"

      for attempt in $(${pkgs.coreutils}/bin/seq 1 45); do
        MISSING=""

        for DEV in $PCI_DEVICES; do
          if [ ! -e "/sys/bus/pci/devices/$DEV" ]; then
            MISSING="$MISSING $DEV"
          fi
        done

        if [ ! -e /dev/vfio/vfio ]; then
          MISSING="$MISSING /dev/vfio/vfio"
        fi

        if [ ! -e /dev/tpmrm0 ]; then
          MISSING="$MISSING /dev/tpmrm0"
        fi

        if [ -z "$MISSING" ]; then
          echo "Windows 11 VFIO host devices are present."
          exit 0
        fi

        echo "Waiting for Windows 11 VFIO host devices:$MISSING"
        ${pkgs.coreutils}/bin/sleep 1
      done

      echo "Timed out waiting for Windows 11 VFIO host devices:$MISSING" >&2
      exit 1
    '';
  };

  systemd.services.libvirtd = {
    after = [ "wait-win11-vfio-devices.service" ];
    requires = [ "wait-win11-vfio-devices.service" ];
  };

  services.udev.extraRules = ''
    # Let the win11 QEMU process open the physical TPM 2.0 resource manager.
    KERNEL=="tpmrm0", GROUP="qemu", MODE="0660"
  '';

  # Hook for VM-to-Host Power Sync
  system.activationScripts.libvirt-hooks.text = let
    hookScript = pkgs.writeShellScript "qemu-hook" ''
      GUEST_NAME="$1"
      OPERATION="$2"
      SUB_OPERATION="$3"
      HUGEPAGES_1G="16"
      HUGEPAGES_1G_PATH="/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"

      allocate_hugepages() {
          echo "$(date): allocating $HUGEPAGES_1G 1G hugepages for $GUEST_NAME" >> /tmp/qemu-hook.log
          if [ ! -w "$HUGEPAGES_1G_PATH" ]; then
              echo "1G hugepages are not available at $HUGEPAGES_1G_PATH" | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook -p err
              exit 1
          fi

          ALLOCATED="$(cat "$HUGEPAGES_1G_PATH")"
          ATTEMPT=1
          while [ "$ALLOCATED" -lt "$HUGEPAGES_1G" ] && [ "$ATTEMPT" -le 8 ]; do
              echo 1 > /proc/sys/vm/compact_memory || true
              echo 3 > /proc/sys/vm/drop_caches || true
              echo 1 > /proc/sys/vm/compact_memory || true
              echo "$HUGEPAGES_1G" > "$HUGEPAGES_1G_PATH"
              ALLOCATED="$(cat "$HUGEPAGES_1G_PATH")"
              if [ "$ALLOCATED" -lt "$HUGEPAGES_1G" ]; then
                  sleep 1
              fi
              ATTEMPT=$((ATTEMPT + 1))
          done

          if [ "$ALLOCATED" -lt "$HUGEPAGES_1G" ]; then
              echo "Failed to allocate $HUGEPAGES_1G 1G hugepages; only got $ALLOCATED" | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook -p err
              ${pkgs.gnugrep}/bin/grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize|MemAvailable' /proc/meminfo | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook -p err
              exit 1
          fi
      }

      release_hugepages() {
          echo "$(date): releasing hugepages for $GUEST_NAME" >> /tmp/qemu-hook.log
          if [ -w "$HUGEPAGES_1G_PATH" ]; then
              echo 0 > "$HUGEPAGES_1G_PATH" || true
          fi
      }

      if [ "$GUEST_NAME" == "win11" ]; then
          # Log the event for debugging
          echo "$(date): win11 $OPERATION $SUB_OPERATION" >> /tmp/qemu-hook.log

          if [[ "$OPERATION" == "prepare" && "$SUB_OPERATION" == "begin" ]]; then
              allocate_hugepages
          fi
          
          if [[ "$OPERATION" == "stopped" || "$OPERATION" == "release" ]]; then
              release_hugepages
          fi
          
          if [[ "$OPERATION" == "stopped" ]]; then
              # Only power off if the lock file does NOT exist
              if [ ! -f /var/lib/libvirt/hooks/no-power-sync ]; then
                  echo "Windows 11 guest $OPERATION. Syncing power off to NixOS host." | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook
                  ${pkgs.systemd}/bin/systemctl poweroff
              else
                  echo "Windows 11 guest $OPERATION. Power sync suppressed by /var/lib/libvirt/hooks/no-power-sync" | ${pkgs.systemd}/bin/systemd-cat -t qemu-hook
              fi
          fi
      fi
    '';
  in ''
    mkdir -p /etc/libvirt/hooks /var/lib/libvirt/hooks
    
    # Place in both /etc and /var paths to ensure libvirt picks it up
    cp -f ${hookScript} /etc/libvirt/hooks/qemu
    cp -f ${hookScript} /var/lib/libvirt/hooks/qemu
    
    chmod +x /etc/libvirt/hooks/qemu /var/lib/libvirt/hooks/qemu

    if ${pkgs.gnugrep}/bin/grep -qw 'win11.no_power_sync=1' /proc/cmdline || \
       ${pkgs.gnugrep}/bin/grep -qw 'no-win11-power-sync' /proc/cmdline; then
      touch /var/lib/libvirt/hooks/no-power-sync
    else
      rm -f /var/lib/libvirt/hooks/no-power-sync
    fi
  '';

  # Systemd service to define the VM from the template XML automatically
  systemd.services.define-win11-vm = {
    description = "Define Windows 11 VFIO VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Wait for secrets to be decrypted by sops-nix
      while [ ! -f /run/secrets/motherboard_uuid ]; do
        echo "Waiting for motherboard_uuid secret..."
        sleep 1
      done
      # Copy the ROM from the local Nix repository to the libvirt directory so QEMU can read it
      # Placed in the qemu subfolder and chowned so AppArmor and the qemu user don't block it
      mkdir -p /var/lib/libvirt/qemu
      cp ${./6700xt.rom} /var/lib/libvirt/qemu/6700xt.rom
      chown root:root /var/lib/libvirt/qemu/6700xt.rom
      chmod 644 /var/lib/libvirt/qemu/6700xt.rom

      enroll_secure_boot_keys_once() {
        NVRAM=/var/lib/libvirt/qemu/nvram/win11_VARS.fd
        TEMPLATE=${pkgs.ovmf_win11.variables}
        MARKER=/var/lib/libvirt/qemu/nvram/win11_VARS.fd.secureboot-enrolled
        INPUT="$NVRAM"

        if [ -f "$MARKER" ] && [ -f "$NVRAM" ]; then
          return
        fi

        if [ ! -f "$INPUT" ]; then
          if [ ! -f "$TEMPLATE" ]; then
            echo "No existing win11 NVRAM and no template at $TEMPLATE" >&2
            exit 1
          fi
          INPUT="$TEMPLATE"
        fi

        mkdir -p "$(${pkgs.coreutils}/bin/dirname "$NVRAM")"
        TMP="$NVRAM.secboot.tmp"

        ${pkgs.python3Packages.virt-firmware}/bin/virt-fw-vars \
          --input "$INPUT" \
          --output "$TMP" \
          --enroll-redhat \
          --secure-boot

        ${pkgs.coreutils}/bin/install -m 0600 "$TMP" "$NVRAM"
        ${pkgs.coreutils}/bin/rm -f "$TMP"
        ${pkgs.coreutils}/bin/date -Is > "$MARKER"
        echo "Enrolled Secure Boot keys into $NVRAM"
      }

      enroll_secure_boot_keys_once

      mkdir -p /var/lib/libvirt/qemu/acpi
      cat > /var/lib/libvirt/qemu/acpi/fake-thermal.asl <<'EOF'
DefinitionBlock ("fake-thermal.aml", "SSDT", 2, "ALASKA", "A M I   ", 0x00000001)
{
    Scope (\_SB)
    {
        ThermalZone (TZ00)
        {
            Name (_TZP, 100)

            Method (_TMP, 0, NotSerialized)
            {
                Return (3032)
            }

            Method (_CRT, 0, NotSerialized)
            {
                Return (3562)
            }
        }
    }
}
EOF
      ${pkgs.acpica-tools}/bin/iasl -ve -p /var/lib/libvirt/qemu/acpi/fake-thermal /var/lib/libvirt/qemu/acpi/fake-thermal.asl >/dev/null
      chmod 644 /var/lib/libvirt/qemu/acpi/fake-thermal.aml

      # Clean slate: full host FACP/DSDT injection was too invasive for this VM.
      # Keep only the tiny synthetic thermal SSDT and QEMU's patched ACPI headers.
      rm -f /var/lib/libvirt/qemu/acpi/FACP.bin
      rm -f /var/lib/libvirt/qemu/acpi/DSDT.aml
      rm -f /var/lib/libvirt/qemu/enable-acpi-spoofing
      rm -f /var/lib/libvirt/qemu/enable-facp-spoofing
      rm -f /var/lib/libvirt/qemu/enable-dsdt-spoofing
      rm -f /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing

      if ${pkgs.libvirt}/bin/virsh dominfo win11 >/dev/null 2>&1; then
        echo "Updating existing win11 VM definition while preserving OVMF NVRAM..."
      fi

      xml_escape() {
        printf '%s' "$1" | ${pkgs.gnused}/bin/sed \
          -e 's/&/\&amp;/g' \
          -e 's/</\&lt;/g' \
          -e 's/>/\&gt;/g' \
          -e "s/'/\&apos;/g"
      }

      dmi_value() {
        VALUE="$(${pkgs.dmidecode}/bin/dmidecode -s "$1" 2>/dev/null | ${pkgs.gnused}/bin/sed '/^$/d' | ${pkgs.coreutils}/bin/head -n1 || true)"
        NORMALIZED="$(printf '%s' "$VALUE" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')"
        if [ -z "$VALUE" ] \
          || [ "$NORMALIZED" = "not specified" ] \
          || [ "$NORMALIZED" = "to be filled by o.e.m." ] \
          || [ "$NORMALIZED" = "to be filled by oem" ] \
          || [ "$NORMALIZED" = "default string" ]; then
          VALUE="$2"
        fi
        xml_escape "$VALUE"
      }

      memory_dmi_field() {
        FIELD="$1"
        ${pkgs.dmidecode}/bin/dmidecode -t 17 2>/dev/null | ${pkgs.gawk}/bin/awk -F: -v field="$FIELD" '
          BEGIN { IGNORECASE = 1 }
          $1 ~ "^[ \t]*" field "$" {
            value = $2
            sub(/^[ \t]+/, "", value)
            sub(/[ \t]+$/, "", value)
            low = tolower(value)
            if (value != "" && low != "unknown" && low != "not specified" &&
                low != "none" && low != "no module installed" &&
                low !~ /qemu|bochs|kvm|vmware|virtualbox|xen/) {
              print value
              exit
            }
          }
        '
      }

      qemu_smbios_value() {
        printf '%s' "$1" | ${pkgs.gnused}/bin/sed \
          -e 's/,/ /g' \
          -e 's/&/\&amp;/g' \
          -e 's/</\&lt;/g' \
          -e 's/>/\&gt;/g' \
          -e "s/'/\&apos;/g"
      }

      valid_serial_value() {
        VALUE="$1"
        NORMALIZED="$(printf '%s' "$VALUE" | ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]' | ${pkgs.gnused}/bin/sed 's/[^a-z0-9]//g')"
        [ -n "$NORMALIZED" ] &&
          [ "$NORMALIZED" != "0" ] &&
          [ "$NORMALIZED" != "00000000" ] &&
          [ "$NORMALIZED" != "0000000000000000" ] &&
          [ "$NORMALIZED" != "unknown" ] &&
          [ "$NORMALIZED" != "none" ]
      }

      RAW_UUID="$(${pkgs.coreutils}/bin/cat /run/secrets/motherboard_uuid)"
      RAW_SERIAL="$(${pkgs.coreutils}/bin/cat /run/secrets/motherboard_serial)"
      RAW_UUID_COMPACT="$(printf '%s' "$RAW_UUID" | ${pkgs.coreutils}/bin/tr -d '-' | ${pkgs.coreutils}/bin/cut -c1-16)"
      DERIVED_SYSTEM_SERIAL="MSI$RAW_UUID_COMPACT"
      DERIVED_CHASSIS_SERIAL="$RAW_SERIAL-C"
      DERIVED_CHASSIS_ASSET="$RAW_SERIAL-A"
      DERIVED_MEMORY_SERIAL="CMK$(${pkgs.coreutils}/bin/printf '%s' "$RAW_SERIAL$RAW_UUID_COMPACT" | ${pkgs.coreutils}/bin/tr -cd '[:alnum:]' | ${pkgs.coreutils}/bin/cut -c1-13)"
      RAW_MEMORY_MANUFACTURER="$(memory_dmi_field Manufacturer)"
      RAW_MEMORY_SERIAL="$(memory_dmi_field "Serial Number")"
      RAW_MEMORY_PART="$(memory_dmi_field "Part Number")"
      RAW_MEMORY_SPEED="$(${pkgs.dmidecode}/bin/dmidecode -t 17 2>/dev/null | ${pkgs.gawk}/bin/awk -F: '
        /^[ \t]*Speed:/ {
          value = $2
          sub(/^[ \t]+/, "", value)
          if (value ~ /^[0-9]+/) {
            print int(value)
            exit
          }
        }
      ')"
      if printf '%s' "$RAW_MEMORY_PART" | ${pkgs.gnugrep}/bin/grep -qi '^CMK'; then
        RAW_MEMORY_MANUFACTURER="Corsair"
      fi
      if [ -z "$RAW_MEMORY_MANUFACTURER" ]; then RAW_MEMORY_MANUFACTURER="Corsair"; fi
      if [ -z "$RAW_MEMORY_PART" ]; then RAW_MEMORY_PART="DDR4-3200"; fi
      if [ -z "$RAW_MEMORY_SPEED" ] || [ "$RAW_MEMORY_SPEED" = "0" ]; then RAW_MEMORY_SPEED="3200"; fi
      if ! valid_serial_value "$RAW_MEMORY_SERIAL"; then RAW_MEMORY_SERIAL="$DERIVED_MEMORY_SERIAL"; fi

      export UUID="$(xml_escape "$RAW_UUID")"
      export SERIAL="$(xml_escape "$RAW_SERIAL")"
      export BIOS_VENDOR="$(dmi_value bios-vendor "American Megatrends International, LLC.")"
      export BIOS_VERSION="$(dmi_value bios-version "1.0")"
      export BIOS_DATE="$(dmi_value bios-release-date "01/01/2024")"
      export SYSTEM_MANUFACTURER="$(dmi_value system-manufacturer "Micro-Star International Co., Ltd.")"
      export SYSTEM_PRODUCT="$(dmi_value system-product-name "MS-7C37")"
      export SYSTEM_VERSION="$(dmi_value system-version "1.0")"
      export SYSTEM_SERIAL="$(dmi_value system-serial-number "$DERIVED_SYSTEM_SERIAL")"
      export BASEBOARD_MANUFACTURER="$(dmi_value baseboard-manufacturer "Micro-Star International Co., Ltd.")"
      export BASEBOARD_PRODUCT="$(dmi_value baseboard-product-name "MPG X570 GAMING EDGE WIFI (MS-7C37)")"
      export BASEBOARD_VERSION="$(dmi_value baseboard-version "1.0")"
      export BASEBOARD_SERIAL="$(dmi_value baseboard-serial-number "$RAW_SERIAL")"
      export CHASSIS_MANUFACTURER="$(dmi_value chassis-manufacturer "Micro-Star International Co., Ltd.")"
      export CHASSIS_VERSION="$(dmi_value chassis-version "1.0")"
      export CHASSIS_SERIAL="$(dmi_value chassis-serial-number "$DERIVED_CHASSIS_SERIAL")"
      export CHASSIS_ASSET="$(dmi_value chassis-asset-tag "$DERIVED_CHASSIS_ASSET")"
      export CHASSIS_SKU="$(dmi_value chassis-sku-number "MS-7C37")"
      export MEMORY_MANUFACTURER="$(qemu_smbios_value "$RAW_MEMORY_MANUFACTURER")"
      export MEMORY_SERIAL="$(qemu_smbios_value "$RAW_MEMORY_SERIAL")"
      export MEMORY_PART="$(qemu_smbios_value "$RAW_MEMORY_PART")"
      export MEMORY_SPEED="$RAW_MEMORY_SPEED"
      export OVMF_CODE="${pkgs.ovmf_win11.firmware}"
      export OVMF_VARS="${pkgs.ovmf_win11.variables}"
      export QEMU_SYSTEM_X86_64="${config.virtualisation.libvirtd.qemu.package}/bin/qemu-system-x86_64"

      export HYPERV_FEATURES="    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vpindex state='on'/>
      <runtime state='on'/>
      <synic state='on'/>
      <stimer state='on'>
        <direct state='on'/>
      </stimer>
      <reset state='on'/>
      <vendor_id state='on' value='GenuineIntel'/>
      <frequencies state='on'/>
      <reenlightenment state='on'/>
      <tlbflush state='on'/>
      <ipi state='on'/>
    </hyperv>"
      export SVM_FEATURE="    <feature policy='require' name='svm'/>"
      export HYPERVCLOCK_TIMER="    <timer name='hypervclock' present='yes'/>"

      export QEMU_COMMANDLINE="  <qemu:commandline>
    <qemu:arg value='-acpitable'/>
    <qemu:arg value='file=/var/lib/libvirt/qemu/acpi/fake-thermal.aml'/>
    <qemu:arg value='-smbios'/>
    <qemu:arg value='type=17,loc_pfx=DIMM,bank=BANK,manufacturer=$MEMORY_MANUFACTURER,serial=$MEMORY_SERIAL,asset=$MEMORY_SERIAL,part=$MEMORY_PART,speed=$MEMORY_SPEED'/>"
      QEMU_COMMANDLINE="$QEMU_COMMANDLINE
  </qemu:commandline>"
      export QEMU_COMMANDLINE
      
      # Substitute the $UUID and $SERIAL variables into the template and define it
      ${pkgs.envsubst}/bin/envsubst \
        '$UUID $SERIAL $BIOS_VENDOR $BIOS_VERSION $BIOS_DATE $SYSTEM_MANUFACTURER $SYSTEM_PRODUCT $SYSTEM_VERSION $SYSTEM_SERIAL $BASEBOARD_MANUFACTURER $BASEBOARD_PRODUCT $BASEBOARD_VERSION $BASEBOARD_SERIAL $CHASSIS_MANUFACTURER $CHASSIS_VERSION $CHASSIS_SERIAL $CHASSIS_ASSET $CHASSIS_SKU $QEMU_SYSTEM_X86_64 $HYPERV_FEATURES $SVM_FEATURE $HYPERVCLOCK_TIMER $QEMU_COMMANDLINE' \
        < ${./win11-template.xml} > /tmp/win11-resolved.xml

      if ${pkgs.gnugrep}/bin/grep -q '\$[A-Z_]' /tmp/win11-resolved.xml; then
        echo "Unresolved placeholders remain in /tmp/win11-resolved.xml"
        ${pkgs.gnugrep}/bin/grep '\$[A-Z_]' /tmp/win11-resolved.xml
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -q "timer name='tsc'.*mode='native'" /tmp/win11-resolved.xml

      ${pkgs.libvirt}/bin/virsh define /tmp/win11-resolved.xml
      ${pkgs.libvirt}/bin/virsh autostart win11 >/dev/null 2>&1 || true
      rm /tmp/win11-resolved.xml
    '';
  };

  environment.systemPackages = with pkgs; [
    virt-manager
    libguestfs
    config.virtualisation.libvirtd.qemu.package
    dmidecode
    envsubst
    lsof
    psmisc
    tpm2-tools
    python3Packages.virt-firmware
    acpica-tools
    (pkgs.writeShellScriptBin "reset-win11-vm-definition" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is running; shut it down before redefining the VM." >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-acpi-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-facp-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-dsdt-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing
      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      echo "win11 VM definition reset to the default stable profile."
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'loader|nvram|secure|<hyperv|hypervclock|qemu:commandline|timer name=.tsc.|feature policy=.require. name=.svm.|feature policy=.disable. name=.hypervisor.' || true
    '')
    (pkgs.writeShellScriptBin "reset-win11-secureboot-nvram" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is running; shut it down before resetting its OVMF variables." >&2
        exit 1
      fi

      NVRAM=/var/lib/libvirt/qemu/nvram/win11_VARS.fd
      if [ -f "$NVRAM" ]; then
        BACKUP="$NVRAM.backup.$(${pkgs.coreutils}/bin/date +%Y%m%d%H%M%S)"
        ${pkgs.coreutils}/bin/cp -a "$NVRAM" "$BACKUP"
        ${pkgs.coreutils}/bin/rm -f "$NVRAM"
        echo "Backed up old OVMF variables to $BACKUP"
      fi

      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      echo "win11 redefined. Secure Boot firmware/NVRAM XML:"
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'loader|nvram|secure' || true
      echo "Start the VM, then check Windows with: Confirm-SecureBootUEFI"
    '')
    (pkgs.writeShellScriptBin "enroll-win11-secureboot-keys" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is running; shut it down before enrolling OVMF Secure Boot keys." >&2
        exit 1
      fi

      NVRAM=/var/lib/libvirt/qemu/nvram/win11_VARS.fd
      TEMPLATE=${pkgs.ovmf_win11.variables}
      INPUT="$NVRAM"

      if [ ! -f "$INPUT" ]; then
        if [ ! -f "$TEMPLATE" ]; then
          echo "No existing win11 NVRAM and no template at $TEMPLATE" >&2
          exit 1
        fi
        INPUT="$TEMPLATE"
      fi

      ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$NVRAM")"
      TMP="$NVRAM.secboot.tmp"
      BACKUP="$NVRAM.backup.$(${pkgs.coreutils}/bin/date +%Y%m%d%H%M%S)"

      if [ -f "$NVRAM" ]; then
        ${pkgs.coreutils}/bin/cp -a "$NVRAM" "$BACKUP"
        echo "Backed up old OVMF variables to $BACKUP"
      fi

      ${pkgs.python3Packages.virt-firmware}/bin/virt-fw-vars \
        --input "$INPUT" \
        --output "$TMP" \
        --enroll-redhat \
        --secure-boot

      ${pkgs.coreutils}/bin/install -m 0600 "$TMP" "$NVRAM"
      ${pkgs.coreutils}/bin/rm -f "$TMP"
      ${pkgs.coreutils}/bin/date -Is > "$NVRAM.secureboot-enrolled"

      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      echo "Enrolled Secure Boot keys into $NVRAM"
      echo "Start the VM, then check Windows with: Confirm-SecureBootUEFI"
    '')
    (pkgs.writeShellScriptBin "free-win11-hugepages" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is still running; shut it down before freeing its hugepages." >&2
        exit 1
      fi

      if [ -w /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]; then
        echo 0 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
      fi

      if [ -w /proc/sys/vm/nr_hugepages ]; then
        echo 0 > /proc/sys/vm/nr_hugepages
      fi

      echo "Hugepages after release:"
      ${pkgs.gnugrep}/bin/grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize|MemAvailable' /proc/meminfo
      echo "1G hugepages:"
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || true
    '')
    (pkgs.writeShellScriptBin "verify-win11-vfio" ''
      set -eu

      echo "== QEMU =="
      XML_QEMU="$(${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnused}/bin/sed -n 's:.*<emulator>\(.*\)</emulator>.*:\1:p')"
      echo "xml: $XML_QEMU"
      if [ -n "$XML_QEMU" ] && [ -x "$XML_QEMU" ]; then
        QEMU_OUT="$(${pkgs.coreutils}/bin/dirname "$(${pkgs.coreutils}/bin/dirname "$XML_QEMU")")"
        echo "out: $QEMU_OUT"
        if [ -f "$QEMU_OUT/nix-support/win11-qemu-patches" ]; then
          echo "qemu-patched-derivation-marker=present"
          ${pkgs.coreutils}/bin/cat "$QEMU_OUT/nix-support/win11-qemu-patches"
        else
          echo "qemu-patched-derivation-marker=missing"
        fi
        if ${pkgs.binutils}/bin/strings "$XML_QEMU" | ${pkgs.gnugrep}/bin/grep -q 'failed to disable hypercall quirk'; then
          echo "qemu-binary-vmcall-string=present"
        else
          echo "qemu-binary-vmcall-string=missing"
        fi
        if ${pkgs.binutils}/bin/strings "$XML_QEMU" | ${pkgs.gnugrep}/bin/grep -q 'tsc-scaling-patch'; then
          echo "qemu-forced-tsc-frequency-log=present"
        else
          echo "qemu-forced-tsc-frequency-log=absent"
        fi
        if ${pkgs.binutils}/bin/strings "$XML_QEMU" | ${pkgs.gnugrep}/bin/grep -q 'qemu-acpi-oem-patch=ALASKA,A M I'; then
          echo "qemu-binary-acpi-string=present"
        else
          echo "qemu-binary-acpi-string=missing"
        fi
      fi
      PID="$(${pkgs.procps}/bin/pgrep -f 'qemu-system-x86_64.*win11' | ${pkgs.coreutils}/bin/head -n1 || true)"
      if [ -n "$PID" ]; then
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o 'tsc-frequency=[^, ]*' || true
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o -- '-acpitable file=[^ ]*' || true
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o -- '-smbios type=17[^ ]*' || true
      fi

      echo
      echo "== TSC =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep "timer name='tsc'" || true
      ${pkgs.coreutils}/bin/echo "tsc-frequency=unforced"
      ${pkgs.systemd}/bin/journalctl -b --no-pager | ${pkgs.gnugrep}/bin/grep -E 'failed to disable hypercall quirk|tsc-scaling-patch' || true
      ${pkgs.systemd}/bin/journalctl -b --no-pager | ${pkgs.gnugrep}/bin/grep 'qemu-acpi-oem-patch=ALASKA,A M I' || true

      echo
      echo "== OVMF / Secure Boot =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'loader|nvram|secure' || true
      OVMF_LOADER="$(${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnused}/bin/sed -n 's:.*<loader[^>]*>\(.*\)</loader>.*:\1:p')"
      if [ -n "$OVMF_LOADER" ] && [ -f "$OVMF_LOADER" ]; then
        ${pkgs.coreutils}/bin/printf 'ovmf-acpi-identity-copy='
        if [ "$OVMF_LOADER" = "${pkgs.ovmf_win11.firmware}" ]; then
          ${pkgs.coreutils}/bin/echo present
        else
          ${pkgs.coreutils}/bin/echo missing
        fi
        OVMF_OUT="$(${pkgs.coreutils}/bin/dirname "$(${pkgs.coreutils}/bin/dirname "$OVMF_LOADER")")"
        ${pkgs.coreutils}/bin/printf 'ovmf-acpi-identity-derivation-marker='
        if [ -f "$OVMF_OUT/nix-support/win11-ovmf-patches" ]; then
          ${pkgs.coreutils}/bin/echo patched
          ${pkgs.coreutils}/bin/cat "$OVMF_OUT/nix-support/win11-ovmf-patches"
        else
          ${pkgs.coreutils}/bin/echo missing
        fi
      fi

      echo
      echo "== CPU / Hypervisor Masking =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E "feature policy='disable' name='hypervisor'|feature policy='require' name='svm'|feature policy='disable' name='svm'|hidden state='on'|timer name='tsc'" || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep "ioapic driver='kvm'" || true
      ${pkgs.coreutils}/bin/printf 'kvm_amd.avic='
      ${pkgs.coreutils}/bin/cat /sys/module/kvm_amd/parameters/avic 2>/dev/null || ${pkgs.coreutils}/bin/echo unknown
      ${pkgs.coreutils}/bin/printf 'hyperv-feature-toggle='
      ${pkgs.coreutils}/bin/echo enabled
      ${pkgs.coreutils}/bin/printf 'hyperv-profile='
      ${pkgs.coreutils}/bin/echo maximal
      ${pkgs.coreutils}/bin/printf 'hyperv-enlightenments='
      if ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -q '<hyperv'; then ${pkgs.coreutils}/bin/echo present; else ${pkgs.coreutils}/bin/echo absent; fi
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E '<hyperv|relaxed|vapic|spinlocks|vpindex|runtime|synic|stimer|direct|reset|vendor_id|frequencies|reenlightenment|tlbflush|ipi' || true
      ${pkgs.coreutils}/bin/printf 'hypervclock-timer='
      if ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -q "timer name='hypervclock'"; then ${pkgs.coreutils}/bin/echo present; else ${pkgs.coreutils}/bin/echo absent; fi

      echo
      echo "== TPM =="
      ${pkgs.coreutils}/bin/ls -l /dev/tpm0 /dev/tpmrm0 2>/dev/null || true
      ${pkgs.coreutils}/bin/cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A4 '<tpm' || true

      echo
      echo "== ACPI =="
      echo "acpi-identity=qemu-header-patch"
      echo "acpi-table-injection=fake-thermal-only"
      echo "legacy-facp-dsdt-injection=removed"
      ${pkgs.coreutils}/bin/ls -l /var/lib/libvirt/qemu/acpi 2>/dev/null || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true

      echo
      echo "== CPU affinity =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E '<vcpu|<topology' || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'vcpupin|emulatorpin|vcpusched|emulatorsched' || true
      echo "runtime-irq-workqueue-repinning=removed"

      echo
      echo "== Hugepages =="
      ${pkgs.gnugrep}/bin/grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize' /proc/meminfo
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || true
    '')
  ];
}
