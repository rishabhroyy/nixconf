{ config, pkgs, ... }:

let
  # Dedicated passthrough devices bind to vfio-pci once during initrd and stay
  # there for the whole NixOS boot.
  vfioIds = [ "1002:73df" "1002:ab28" "144d:a80a" "10ec:8125" "1b21:0612" ];
  win11VfioDevices = [
    "0000:2f:00.0"
    "0000:2f:00.1"
    "0000:22:00.0"
    "0000:26:00.0"
    "0000:2a:00.1"
    "0000:2a:00.3"
    "0000:29:00.0"
  ];
  win11EarlyBoundDevices = [
    "0000:2f:00.0"
    "0000:2f:00.1"
    "0000:22:00.0"
    "0000:26:00.0"
    "0000:29:00.0"
  ];
in
{
  # Kernel parameters for IOMMU, VFIO, and CPU Isolation
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    # Isolate physical cores 4-7 for the Windows 11 VM.
    # Physical cores 0-3 remain shared for NixOS and QEMU housekeeping.
    "isolcpus=domain,managed_irq,4-7,12-15"
    "nohz_full=4-7,12-15"
    "rcu_nocbs=4-7,12-15"
    # Keep offloaded RCU callbacks from waking latency-sensitive guest CPUs.
    "rcu_nocb_poll"
    "irqaffinity=0-3,8-11"
    "workqueue.unbound_cpus=0-3,8-11"
    "systemd.cpu_affinity=0-3,8-11"
    "amd_pstate=active"
    "kvm.ignore_msrs=1"
    "kvm.report_ignored_msrs=0"
    "default_hugepagesz=1G"
    "hugepagesz=1G"
    "hugepages=12"
    ("vfio-pci.ids=" + builtins.concatStringsSep "," vfioIds)
  ];

  powerManagement.cpuFreqGovernor = "performance";

  # Enable nested virtualization for Windows VBS/Core Isolation and AVIC as a
  # normal KVM acceleration path. No live KVM ftrace/kprobe modules are loaded.
  boot.extraModprobeConfig = "options kvm_amd nested=1 avic=1";

  # Load VFIO early so dedicated passthrough devices never bind to host drivers.
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

  # Permit only the low real-time priority requested by the isolated guest
  # vCPUs. Host work and shared guest vCPUs retain normal scheduling.
  systemd.services.libvirtd.serviceConfig.LimitRTPRIO = 1;

  services.udev.extraRules = ''
    # Let the win11 QEMU process open the physical TPM 2.0 resource manager.
    KERNEL=="tpmrm0", GROUP="qemu", MODE="0660"
  '';

  # Libvirt domain autostart races the generated XML and passthrough-device
  # readiness. The dedicated start-win11-vm service owns guest startup.
  systemd.services.disable-win11-libvirt-autostart = {
    description = "Disable libvirt-owned Windows 11 autostart";
    before = [ "libvirtd.service" ];
    requiredBy = [ "libvirtd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/autostart/win11.xml
    '';
  };

  # Hugepages are reserved by the kernel command line. Remove the old
  # synchronous libvirt hook that redundantly compacted memory, dropped caches,
  # and freed those pages during domain lifecycle transitions.
  system.activationScripts.removeLegacyWin11LibvirtHooks.text = ''
    for HOOK in /etc/libvirt/hooks/qemu /var/lib/libvirt/hooks/qemu; do
      if [ -f "$HOOK" ] \
         && ${pkgs.gnugrep}/bin/grep -q 'qemu-hook.log' "$HOOK" \
         && ${pkgs.gnugrep}/bin/grep -q 'hugepages-1048576kB' "$HOOK"; then
        ${pkgs.coreutils}/bin/rm -f "$HOOK"
      fi
    done
  '';

  systemd.services.win11-power-sync-monitor = {
    description = "Power off NixOS after a clean Windows 11 guest shutdown";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    partOf = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "2s";
    };
    script = ''
      set -uo pipefail
      export LC_ALL=C
      REBOOT_MARKER=/run/win11-reboot-requested
      BAREMETAL_NEXT_MARKER=/run/win11-boot-baremetal-next

      set_windows_bootnext() {
        BOOTNUM="$(${pkgs.efibootmgr}/bin/efibootmgr | ${pkgs.gawk}/bin/awk '
          BEGIN { IGNORECASE = 1 }
          /^Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]/ && /Windows Boot Manager/ {
            boot = $1
            gsub(/^Boot/, "", boot)
            gsub(/\*/, "", boot)
            print boot
            exit
          }
        ')"

        if [ -z "$BOOTNUM" ]; then
          echo "Bare-metal Windows was requested, but no Windows Boot Manager UEFI entry exists; leaving NixOS running." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync -p err
          return 1
        fi

        if ${pkgs.efibootmgr}/bin/efibootmgr --bootnext "$BOOTNUM" >/dev/null; then
          ${pkgs.coreutils}/bin/rm -f "$BAREMETAL_NEXT_MARKER"
          echo "Armed Windows Boot Manager (Boot$BOOTNUM) for the next host startup." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
          return 0
        fi

        echo "Failed to arm Windows Boot Manager for the next host startup; leaving NixOS running." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync -p err
        return 1
      }

      ${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.libvirt}/bin/virsh event --all --loop --timestamp |
        while IFS= read -r EVENT; do
          echo "$EVENT" | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync

          case "$EVENT" in
            *"event 'reboot' for domain win11:"*|*"event 'reboot' for domain 'win11':"*)
              ${pkgs.coreutils}/bin/touch "$REBOOT_MARKER"
              echo "Windows 11 requested a reboot; suppressing host poweroff for this transition." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
              ;;
            *"event 'lifecycle' for domain win11: Started Booted"*|*"event 'lifecycle' for domain 'win11': Started Booted"*)
              ${pkgs.coreutils}/bin/rm -f "$REBOOT_MARKER"
              ;;
            *"event 'lifecycle' for domain win11: Stopped Shutdown"*|*"event 'lifecycle' for domain 'win11': Stopped Shutdown"*)
              (
                # Reboots temporarily pass through Stopped Shutdown. Give
                # libvirt time to emit the reboot/start events before deciding.
                ${pkgs.coreutils}/bin/sleep 5

                if [ -e /run/win11-power-sync.disabled ] || \
                   ${pkgs.gnugrep}/bin/grep -qw 'win11.no_power_sync=1' /proc/cmdline || \
                   ${pkgs.gnugrep}/bin/grep -qw 'no-win11-power-sync' /proc/cmdline; then
                  echo "Windows 11 completed a clean guest shutdown; host poweroff is disabled." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
                  exit 0
                fi

                if [ -e "$REBOOT_MARKER" ]; then
                  NOW="$(${pkgs.coreutils}/bin/date +%s)"
                  MARKER_TIME="$(${pkgs.coreutils}/bin/stat -c %Y "$REBOOT_MARKER" 2>/dev/null || echo 0)"
                  MARKER_AGE="$((NOW - MARKER_TIME))"
                  if [ "$MARKER_AGE" -ge 0 ] && [ "$MARKER_AGE" -le 120 ]; then
                    echo "Windows 11 stopped as part of a reboot; leaving NixOS running." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
                    exit 0
                  fi
                  ${pkgs.coreutils}/bin/rm -f "$REBOOT_MARKER"
                fi

                SYSTEM_STATE="$(${pkgs.systemd}/bin/systemctl is-system-running 2>/dev/null || true)"
                case "$SYSTEM_STATE" in
                  running|degraded)
                    ;;
                  *)
                    echo "Windows 11 stopped while NixOS state is '$SYSTEM_STATE'; leaving the existing host shutdown/reboot transaction unchanged." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
                    exit 0
                    ;;
                esac

                CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null || true)"
                if [ "$CURRENT_STATE" = "shut off" ]; then
                  if [ -e "$BAREMETAL_NEXT_MARKER" ] && ! set_windows_bootnext; then
                    exit 0
                  fi
                  echo "Windows 11 completed a clean shutdown and remains off; powering off NixOS." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
                  ${pkgs.systemd}/bin/systemctl poweroff
                else
                  echo "Windows 11 stopped with shutdown reason but current state is '$CURRENT_STATE'; leaving NixOS running." | ${pkgs.systemd}/bin/systemd-cat -t win11-power-sync
                fi
              ) &
              ;;
          esac
        done
    '';
  };

  # Systemd service to define the VM from the template XML automatically
  systemd.services.define-win11-vm = {
    description = "Define Windows 11 VFIO VM";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "3min";
    };
    script = ''
      export LC_ALL=C
      RESOLVED_XML="$(${pkgs.coreutils}/bin/mktemp /run/win11-resolved.XXXXXX)"
      ${pkgs.coreutils}/bin/chmod 0600 "$RESOLVED_XML"
      trap '${pkgs.coreutils}/bin/rm -f "$RESOLVED_XML"' EXIT

      # Both values are required to produce a stable VM identity. Fail cleanly
      # instead of defining a partial domain if secret decryption is unavailable.
      for ATTEMPT in $(${pkgs.coreutils}/bin/seq 1 60); do
        MISSING_SECRETS=""
        [ -f /run/secrets/motherboard_uuid ] || MISSING_SECRETS="$MISSING_SECRETS motherboard_uuid"
        [ -f /run/secrets/motherboard_serial ] || MISSING_SECRETS="$MISSING_SECRETS motherboard_serial"
        [ -z "$MISSING_SECRETS" ] && break
        echo "Waiting for required secrets:$MISSING_SECRETS"
        ${pkgs.coreutils}/bin/sleep 1
      done
      if [ -n "$MISSING_SECRETS" ]; then
        echo "Timed out waiting for required secrets:$MISSING_SECRETS" >&2
        exit 1
      fi
      # Copy the ROM from the local Nix repository to the libvirt directory so QEMU can read it
      # Placed in the qemu subfolder and chowned so AppArmor and the qemu user don't block it
      mkdir -p /var/lib/libvirt/qemu
      cp ${./6700xt.rom} /var/lib/libvirt/qemu/6700xt.rom
      chown root:root /var/lib/libvirt/qemu/6700xt.rom
      chmod 644 /var/lib/libvirt/qemu/6700xt.rom

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
      
      # Resolve the generated identity, firmware, and feature fragments.
      ${pkgs.envsubst}/bin/envsubst \
        '$UUID $BIOS_VENDOR $BIOS_VERSION $BIOS_DATE $SYSTEM_MANUFACTURER $SYSTEM_PRODUCT $SYSTEM_VERSION $SYSTEM_SERIAL $BASEBOARD_MANUFACTURER $BASEBOARD_PRODUCT $BASEBOARD_VERSION $BASEBOARD_SERIAL $CHASSIS_MANUFACTURER $CHASSIS_VERSION $CHASSIS_SERIAL $CHASSIS_ASSET $CHASSIS_SKU $OVMF_CODE $OVMF_VARS $QEMU_SYSTEM_X86_64 $HYPERV_FEATURES $SVM_FEATURE $HYPERVCLOCK_TIMER $QEMU_COMMANDLINE' \
        < ${./win11-template.xml} > "$RESOLVED_XML"

      if ${pkgs.gnugrep}/bin/grep -q '\$[A-Z_]' "$RESOLVED_XML"; then
        echo "Unresolved placeholders remain in generated win11 XML."
        ${pkgs.gnugrep}/bin/grep '\$[A-Z_]' "$RESOLVED_XML"
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -q "timer name='tsc'.*mode='native'" "$RESOLVED_XML"

      ${pkgs.libvirt}/bin/virsh define "$RESOLVED_XML"
      ${pkgs.libvirt}/bin/virsh autostart --disable win11 >/dev/null 2>&1 || true
    '';
  };

  systemd.services.start-win11-vm = {
    description = "Start Windows 11 VFIO VM";
    wantedBy = [ "multi-user.target" ];
    wants = [ "win11-power-sync-monitor.service" ];
    after = [
      "define-win11-vm.service"
      "win11-power-sync-monitor.service"
    ];
    requires = [ "define-win11-vm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      export LC_ALL=C

      if ${pkgs.gnugrep}/bin/grep -qw 'win11.no_autostart=1' /proc/cmdline || \
         ${pkgs.gnugrep}/bin/grep -qw 'no-win11-autostart' /proc/cmdline; then
        echo "win11 autostart disabled by kernel command line."
        exit 0
      fi

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null || true)"
      case "$CURRENT_STATE" in
        "shut off")
          ;;
        running|paused|blocked|crashed|pmsuspended|"in shutdown"|"no state")
          echo "win11 is already active ($CURRENT_STATE); leaving it unchanged."
          exit 0
          ;;
        *)
          echo "Could not determine a safe inactive state for win11: $CURRENT_STATE" >&2
          exit 1
          ;;
      esac

      # Dedicated devices are already bound to vfio-pci. Start the persistent
      # libvirt domain normally and exactly once.
      echo "Starting win11."
      if ! ${pkgs.libvirt}/bin/virsh start win11; then
        ${pkgs.coreutils}/bin/tail -n 80 /var/log/libvirt/qemu/win11.log 2>/dev/null >&2 || true
        exit 1
      fi
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
    (pkgs.writeShellScriptBin "disable-power-sync" ''
      set -eu
      ${pkgs.coreutils}/bin/touch /run/win11-power-sync.disabled
      echo "Power sync disabled until the next host boot or enable-power-sync."
    '')
    (pkgs.writeShellScriptBin "enable-power-sync" ''
      set -eu
      ${pkgs.coreutils}/bin/rm -f /run/win11-power-sync.disabled
      ${pkgs.systemd}/bin/systemctl start win11-power-sync-monitor.service
      echo "Power sync enabled."
    '')
    (pkgs.writeShellScriptBin "reset-win11-vm-definition" ''
      set -eu
      export LC_ALL=C

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11)"
      if [ "$CURRENT_STATE" != "shut off" ]; then
        echo "win11 is not safely shut off ($CURRENT_STATE); refusing to redefine the VM." >&2
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
      export LC_ALL=C

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11)"
      if [ "$CURRENT_STATE" != "shut off" ]; then
        echo "win11 is not safely shut off ($CURRENT_STATE); refusing to reset its OVMF variables." >&2
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
      export LC_ALL=C

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11)"
      if [ "$CURRENT_STATE" != "shut off" ]; then
        echo "win11 is not safely shut off ($CURRENT_STATE); refusing to enroll OVMF Secure Boot keys." >&2
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
      export LC_ALL=C

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11)"
      if [ "$CURRENT_STATE" != "shut off" ]; then
        echo "win11 is not safely shut off ($CURRENT_STATE); refusing to free its hugepages." >&2
        exit 1
      fi

      if [ -w /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]; then
        echo 0 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
      fi

      if [ -w /proc/sys/vm/nr_hugepages ]; then
        echo 0 > /proc/sys/vm/nr_hugepages
      fi

      echo "The next win11 start will fail safely until the host is rebooted and its 1G hugepages are reserved again."
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
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep "poll-control state='on'" || true
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
      ${pkgs.coreutils}/bin/printf 'libvirtd-rtprio-limit='
      ${pkgs.systemd}/bin/systemctl show libvirtd.service --property=LimitRTPRIO --value || true
      ${pkgs.coreutils}/bin/printf 'kernel-command-line='
      ${pkgs.coreutils}/bin/cat /proc/cmdline
      ${pkgs.coreutils}/bin/printf 'rcu-nocb-poll='
      if ${pkgs.gnugrep}/bin/grep -qw 'rcu_nocb_poll' /proc/cmdline; then ${pkgs.coreutils}/bin/echo enabled; else ${pkgs.coreutils}/bin/echo missing; fi
      ${pkgs.coreutils}/bin/printf 'nmi-watchdog='
      ${pkgs.coreutils}/bin/cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || ${pkgs.coreutils}/bin/echo unknown
      ${pkgs.coreutils}/bin/printf 'unbound-workqueue-cpumask='
      ${pkgs.coreutils}/bin/cat /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true
      echo "threads currently executing on latency-sensitive CPUs:"
      ${pkgs.procps}/bin/ps -eLo pid,tid,psr,cls,rtprio,comm --no-headers | ${pkgs.gawk}/bin/awk '
        $3 == 4 || $3 == 5 || $3 == 6 || $3 == 7 ||
        $3 == 12 || $3 == 13 || $3 == 14 || $3 == 15 { print }
      ' || true

      echo
      echo "== Passthrough bindings =="
      for DEVICE in ${builtins.concatStringsSep " " win11VfioDevices}; do
        DRIVER="$(${pkgs.coreutils}/bin/readlink -f "/sys/bus/pci/devices/$DEVICE/driver" 2>/dev/null || true)"
        if [ -n "$DRIVER" ]; then
          echo "$DEVICE -> $DRIVER"
        else
          echo "$DEVICE -> missing or unbound"
        fi
      done

      echo
      echo "== Boot-critical PCI readiness =="
      for DEVICE in ${builtins.concatStringsSep " " win11EarlyBoundDevices}; do
        DEVICE_PATH="/sys/bus/pci/devices/$DEVICE"
        ${pkgs.coreutils}/bin/printf '%s reset-method=' "$DEVICE"
        ${pkgs.coreutils}/bin/cat "$DEVICE_PATH/reset_method" 2>/dev/null || ${pkgs.coreutils}/bin/echo unavailable
        ${pkgs.coreutils}/bin/printf '%s power-state=' "$DEVICE"
        ${pkgs.coreutils}/bin/cat "$DEVICE_PATH/power_state" 2>/dev/null || ${pkgs.coreutils}/bin/echo unavailable
        ${pkgs.coreutils}/bin/printf '%s link=' "$DEVICE"
        SPEED="$(${pkgs.coreutils}/bin/cat "$DEVICE_PATH/current_link_speed" 2>/dev/null || true)"
        WIDTH="$(${pkgs.coreutils}/bin/cat "$DEVICE_PATH/current_link_width" 2>/dev/null || true)"
        ${pkgs.coreutils}/bin/echo "$SPEED x$WIDTH"
      done
      echo "recent PCI/VFIO/NVMe kernel messages:"
      ${pkgs.systemd}/bin/journalctl -b -k --no-pager | ${pkgs.gnugrep}/bin/grep -Ei 'vfio|aer|pcie|nvme|22:00.0|iommu' | ${pkgs.coreutils}/bin/tail -n 120 || true

      echo
      echo "== Lifecycle =="
      ${pkgs.systemd}/bin/systemctl --no-pager --full status disable-win11-libvirt-autostart.service define-win11-vm.service start-win11-vm.service win11-power-sync-monitor.service || true
      LEGACY_HOOKS=0
      for HOOK in /etc/libvirt/hooks/qemu /var/lib/libvirt/hooks/qemu; do
        if [ -e "$HOOK" ]; then
          echo "legacy-qemu-hook-present=$HOOK"
          LEGACY_HOOKS=1
        fi
      done
      if [ "$LEGACY_HOOKS" -eq 0 ]; then
        echo "legacy-qemu-hooks=absent"
      fi
      if [ -e /run/win11-power-sync.disabled ]; then
        echo "power-sync=disabled-for-this-boot"
      else
        echo "power-sync=enabled"
      fi
      if [ -e /run/win11-boot-baremetal-next ]; then
        echo "baremetal-next=waiting-for-clean-guest-shutdown"
      else
        echo "baremetal-next=not-armed"
      fi
      ${pkgs.coreutils}/bin/printf 'domain-state='
      ${pkgs.libvirt}/bin/virsh domstate win11 --reason 2>/dev/null || true
      ${pkgs.coreutils}/bin/printf 'libvirt-autostart='
      ${pkgs.libvirt}/bin/virsh dominfo win11 2>/dev/null | ${pkgs.gnused}/bin/sed -n 's/^Autostart:[[:space:]]*//p' || true
      echo "recent QEMU log:"
      ${pkgs.coreutils}/bin/tail -n 40 /var/log/libvirt/qemu/win11.log 2>/dev/null || true
      echo "startup journal:"
      ${pkgs.systemd}/bin/journalctl -b --no-pager -n 120 -u define-win11-vm.service -u start-win11-vm.service || true

      echo
      echo "== Hugepages =="
      ${pkgs.gnugrep}/bin/grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize' /proc/meminfo
      ${pkgs.coreutils}/bin/printf 'free-1g-hugepages='
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages 2>/dev/null || true
      ${pkgs.coreutils}/bin/printf 'total-1g-hugepages='
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || true
    '')
  ];

}
