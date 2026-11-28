{ config, pkgs, ... }:

let
  cpus = import ./cpu-layout.nix;
  # The boot NVMe binds to vfio-pci once during initrd and
  # stay there for the whole NixOS boot. The RX 6700 XT (1002:73df, its HDMI
  # audio 1002:ab28) is not in this list: it drives the homelab dashboard
  # while Windows is off, and libvirt hands it to vfio-pci at VM start
  # (managed='yes' in win11-template.xml, see homelab.nix).
  # 10ec:8125 (the 2.5GbE NIC) intentionally not in this list -- it's
  # host-owned now, bridged as br0, and shared with the win11 guest over a
  # virtio-net interface instead of raw PCI passthrough. See networking
  # config in configuration.nix and the win11 domain's <interface> in
  # win11-template.xml.
  # The ASMedia SATA controller (1b21:0612, 26:00.0) is host-owned: its
  # SanDisk SSD is Linux's /mnt/ssd, shared to Windows over Samba.
  vfioIds = [ "144d:a80a" ];
  win11VfioDevices = [
    "0000:2f:00.0"
    "0000:2f:00.1"
    "0000:22:00.0"
    "0000:2a:00.1"
    "0000:2a:00.3"
  ];
in
{
  # Kernel parameters for IOMMU, VFIO, and CPU Isolation
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    # No boot-time CPU isolation (isolcpus/nohz_full/rcu_nocbs): homelab.nix
    # moves the host off the win11 vCPU cores only while Windows runs, so
    # they're the host's whenever it's off.
    "amd_pstate=active"
    "kvm.ignore_msrs=1"
    "kvm.report_ignored_msrs=0"
    # Default halt_poll_ns (200us) isn't enough headroom for the guest's
    # bursty HLT pattern: its frequent short HLTs were dropping straight into
    # the host's C2 idle state, starving the boost algorithm. A longer
    # busy-poll window keeps short guest idle gaps out of C-states. Only
    # vCPU threads poll, so it costs nothing while Windows is off.
    "kvm.halt_poll_ns=500000"
    # No hugepages reserved at boot: homelab.nix allocates the VM's 2 MiB
    # pages at Windows start and frees them at stop.
    ("vfio-pci.ids=" + builtins.concatStringsSep "," vfioIds)
  ];

  powerManagement.cpuFreqGovernor = "performance";

  # AVIC as a normal KVM acceleration path. No nested virtualization: SVM is
  # hidden from the guest (see SVM_FEATURE), so it could never use it.
  boot.extraModprobeConfig = "options kvm_amd nested=0 avic=1";

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

  # Permit only the low real-time priority requested for the win11 emulator
  # thread (emulatorsched in the template).
  systemd.services.libvirtd.serviceConfig.LimitRTPRIO = 1;

  services.udev.extraRules = ''
    # Let the win11 QEMU process open the physical TPM 2.0 resource manager.
    KERNEL=="tpmrm0", GROUP="qemu", MODE="0660"
  '';

  # Libvirt domain autostart races the generated XML and passthrough-device
  # readiness. win11.service (homelab.nix) owns guest startup.
  systemd.services.disable-win11-libvirt-autostart = {
    description = "Disable libvirt-owned Windows 11 autostart";
    before = [ "libvirtd.service" ];
    requiredBy = [ "libvirtd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/autostart/win11.xml
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
      <tlbflush state='on'/>
      <ipi state='on'/>
      <avic state='on'/>
    </hyperv>"
      # <avic> tells Windows to skip SynIC auto-EOI, which would otherwise make
      # KVM inhibit AVIC once the enlightenments above are active.
      # SVM is hidden (host-passthrough would pass it through) so Windows can't
      # start its own Hyper-V for VBS/HVCI and run nested on KVM. Bare-metal
      # Windows still sees the real CPU and keeps VBS. Required with the
      # hypervisor CPUID bit visible: with SVM exposed too, Windows hangs at
      # boot trying to launch Hyper-V.
      export HOUSEKEEPING_CPUS="${cpus.housekeeping}"
      export SVM_FEATURE="    <feature policy='disable' name='svm'/>"
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
        '$UUID $BIOS_VENDOR $BIOS_VERSION $BIOS_DATE $SYSTEM_MANUFACTURER $SYSTEM_PRODUCT $SYSTEM_VERSION $SYSTEM_SERIAL $BASEBOARD_MANUFACTURER $BASEBOARD_PRODUCT $BASEBOARD_VERSION $BASEBOARD_SERIAL $CHASSIS_MANUFACTURER $CHASSIS_VERSION $CHASSIS_SERIAL $CHASSIS_ASSET $CHASSIS_SKU $OVMF_CODE $OVMF_VARS $QEMU_SYSTEM_X86_64 $HYPERV_FEATURES $SVM_FEATURE $HYPERVCLOCK_TIMER $QEMU_COMMANDLINE $HOUSEKEEPING_CPUS' \
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
      export LC_ALL=C

      CURRENT_STATE="$(${pkgs.libvirt}/bin/virsh domstate win11)"
      if [ "$CURRENT_STATE" != "shut off" ]; then
        echo "win11 is not safely shut off ($CURRENT_STATE); refusing to redefine the VM." >&2
        exit 1
      fi

      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      echo "win11 VM definition reset to the default stable profile."
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'loader|nvram|secure|<hyperv|hypervclock|qemu:commandline|timer name=.tsc.|feature policy=.disable. name=.svm.' || true
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
        if ${pkgs.binutils}/bin/strings "$XML_QEMU" | ${pkgs.gnugrep}/bin/grep -q 'qemu-acpi-oem-patch=ALASKA,A M I'; then
          echo "qemu-binary-acpi-string=present"
        else
          echo "qemu-binary-acpi-string=missing"
        fi
      fi
      PID="$(${pkgs.procps}/bin/pgrep -f 'qemu-system-x86_64.*win11' | ${pkgs.coreutils}/bin/head -n1 || true)"
      if [ -n "$PID" ]; then
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o -- '-acpitable file=[^ ]*' || true
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o -- '-smbios type=17[^ ]*' || true
      fi

      echo
      echo "== TSC =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep "timer name='tsc'" || true
      ${pkgs.systemd}/bin/journalctl -b --no-pager | ${pkgs.gnugrep}/bin/grep 'failed to disable hypercall quirk' || true
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
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E "feature policy='disable' name='svm'|hidden state='on'|timer name='tsc'" || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep "ioapic driver='kvm'" || true
      ${pkgs.coreutils}/bin/printf 'kvm_amd.avic='
      ${pkgs.coreutils}/bin/cat /sys/module/kvm_amd/parameters/avic 2>/dev/null || ${pkgs.coreutils}/bin/echo unknown
      ${pkgs.coreutils}/bin/printf 'hyperv-enlightenments='
      if ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -q '<hyperv'; then ${pkgs.coreutils}/bin/echo present; else ${pkgs.coreutils}/bin/echo absent; fi
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E '<hyperv|relaxed|vapic|spinlocks|vpindex|runtime|synic|stimer|direct|reset|vendor_id|frequencies|tlbflush|ipi|avic' || true
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
      ${pkgs.coreutils}/bin/ls -l /var/lib/libvirt/qemu/acpi 2>/dev/null || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true

      echo
      echo "== CPU boost / idle states (VM cores) =="
      ${pkgs.coreutils}/bin/printf 'kvm.halt_poll_ns='
      ${pkgs.coreutils}/bin/cat /sys/module/kvm/parameters/halt_poll_ns 2>/dev/null || ${pkgs.coreutils}/bin/echo unknown
      for CPU in ${cpus.isolatedWords}; do
        FREQ="$(${pkgs.coreutils}/bin/cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_cur_freq 2>/dev/null || echo unknown)"
        MINFREQ="$(${pkgs.coreutils}/bin/cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_min_freq 2>/dev/null || echo unknown)"
        ${pkgs.coreutils}/bin/printf 'cpu%s scaling_cur_freq=%s scaling_min_freq=%s ' "$CPU" "$FREQ" "$MINFREQ"
        for STATE in /sys/devices/system/cpu/cpu$CPU/cpuidle/state*/; do
          NAME="$(${pkgs.coreutils}/bin/cat "$STATE/name" 2>/dev/null || true)"
          DISABLED="$(${pkgs.coreutils}/bin/cat "$STATE/disable" 2>/dev/null || true)"
          ${pkgs.coreutils}/bin/printf '%s:disable=%s ' "$NAME" "$DISABLED"
        done
        echo
      done

      echo
      echo "== CPU affinity =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E '<vcpu|<topology' || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'vcpupin|emulatorpin|emulatorsched' || true
      ${pkgs.coreutils}/bin/printf 'libvirtd-rtprio-limit='
      ${pkgs.systemd}/bin/systemctl show libvirtd.service --property=LimitRTPRIO --value || true
      ${pkgs.coreutils}/bin/printf 'kernel-command-line='
      ${pkgs.coreutils}/bin/cat /proc/cmdline
      ${pkgs.coreutils}/bin/printf 'host-slice-cpus='
      ${pkgs.systemd}/bin/systemctl show system.slice --property=AllowedCPUs --value || true
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
      echo "== Passthrough PCI state =="
      for DEVICE in ${builtins.concatStringsSep " " win11VfioDevices}; do
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
      ${pkgs.systemd}/bin/systemctl --no-pager --full status disable-win11-libvirt-autostart.service define-win11-vm.service win11.service win11-lifecycle-monitor.service homelab.target || true
      ${pkgs.coreutils}/bin/printf 'homelab-state='
      ${pkgs.coreutils}/bin/cat /run/homelab/state.json 2>/dev/null || echo none
      ${pkgs.coreutils}/bin/printf 'domain-state='
      ${pkgs.libvirt}/bin/virsh domstate win11 --reason 2>/dev/null || true
      ${pkgs.coreutils}/bin/printf 'libvirt-autostart='
      ${pkgs.libvirt}/bin/virsh dominfo win11 2>/dev/null | ${pkgs.gnused}/bin/sed -n 's/^Autostart:[[:space:]]*//p' || true
      echo "recent QEMU log:"
      ${pkgs.coreutils}/bin/tail -n 40 /var/log/libvirt/qemu/win11.log 2>/dev/null || true
      echo "startup journal:"
      ${pkgs.systemd}/bin/journalctl -b --no-pager -n 120 -u define-win11-vm.service -u win11.service -u win11-lifecycle-monitor.service || true

      echo
      echo "== Hugepages =="
      ${pkgs.gnugrep}/bin/grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize' /proc/meminfo
      ${pkgs.coreutils}/bin/printf 'free-2m-hugepages='
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-2048kB/free_hugepages 2>/dev/null || true
      ${pkgs.coreutils}/bin/printf 'total-2m-hugepages='
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || true
    '')
  ];

}
