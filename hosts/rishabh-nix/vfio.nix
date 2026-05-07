{ config, pkgs, ... }:

let
  # The devices we want to pass through to the Windows 11 VM.
  # Keep this on the known-working global binding path while we isolate the
  # Vanguard-specific kernel changes.
  vfioIds = [ "1002:73df" "1002:ab28" "144d:a80a" "10ec:8125" "1b21:0612" ];
in
{
  # Kernel parameters for IOMMU, VFIO, and CPU Isolation
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    # Isolate Cores 2-7 and 10-15 (Physical pairs) for the Windows 11 VM
    "isolcpus=2-7,10-15"
    "nohz_full=2-7,10-15"
    "rcu_nocbs=2-7,10-15"
    "kvm.ignore_msrs=1"
    "kvm.report_ignored_msrs=0"
    "default_hugepagesz=1G"
    "hugepagesz=1G"
    "hugepages=24"
    ("vfio-pci.ids=" + builtins.concatStringsSep "," vfioIds)
  ];

  # Enable nested virtualization for AMD (required for Windows 11 VBS/Core Isolation)
  boot.extraModprobeConfig = "options kvm_amd nested=1";

  # Load the targeted CPUID/RDTSC compensation module by default for the VFIO
  # profile. It can still be disabled live with disable-vanguard-rdtsc-patch.
  ghost.vfio.cpuidTscCompensation.enableAtBoot = true;

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
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = false;
    };
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
      HUGEPAGES_1G="24"
      HUGEPAGES_1G_PATH="/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
      HOST_CPU_LIST="0-1,8-9"
      HOST_CPU_MASK="303"
      DEFAULT_IRQ_STATE="/run/libvirt/win11-default-irq-affinity.state"
      IRQ_STATE="/run/libvirt/win11-irq-affinity.state"
      WORKQUEUE_STATE="/run/libvirt/win11-workqueue-cpumask.state"

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

      isolate_host_noise() {
          mkdir -p /run/libvirt

          : > "$IRQ_STATE"
          for IRQ_AFFINITY in /proc/irq/*/smp_affinity_list; do
              if [ -w "$IRQ_AFFINITY" ]; then
                  ORIGINAL="$(cat "$IRQ_AFFINITY")"
                  echo "$IRQ_AFFINITY $ORIGINAL" >> "$IRQ_STATE"
                  echo "$HOST_CPU_LIST" > "$IRQ_AFFINITY" 2>/dev/null || true
              fi
          done

          if [ -w /proc/irq/default_smp_affinity ]; then
              cat /proc/irq/default_smp_affinity > "$DEFAULT_IRQ_STATE"
              echo "$HOST_CPU_MASK" > /proc/irq/default_smp_affinity || true
          fi

          if [ -w /sys/devices/virtual/workqueue/cpumask ]; then
              cat /sys/devices/virtual/workqueue/cpumask > "$WORKQUEUE_STATE"
              echo "$HOST_CPU_MASK" > /sys/devices/virtual/workqueue/cpumask || true
          fi
      }

      restore_host_noise() {
          if [ -f "$IRQ_STATE" ]; then
              while read -r IRQ_AFFINITY ORIGINAL; do
                  if [ -w "$IRQ_AFFINITY" ]; then
                      echo "$ORIGINAL" > "$IRQ_AFFINITY" 2>/dev/null || true
                  fi
              done < "$IRQ_STATE"
              rm -f "$IRQ_STATE"
          fi

          if [ -f "$DEFAULT_IRQ_STATE" ] && [ -w /proc/irq/default_smp_affinity ]; then
              cat "$DEFAULT_IRQ_STATE" > /proc/irq/default_smp_affinity || true
              rm -f "$DEFAULT_IRQ_STATE"
          fi

          if [ -f "$WORKQUEUE_STATE" ] && [ -w /sys/devices/virtual/workqueue/cpumask ]; then
              cat "$WORKQUEUE_STATE" > /sys/devices/virtual/workqueue/cpumask || true
              rm -f "$WORKQUEUE_STATE"
          fi
      }

      if [ "$GUEST_NAME" == "win11" ]; then
          # Log the event for debugging
          echo "$(date): win11 $OPERATION $SUB_OPERATION" >> /tmp/qemu-hook.log

          if [[ "$OPERATION" == "prepare" && "$SUB_OPERATION" == "begin" ]]; then
              allocate_hugepages
              isolate_host_noise
          fi
          
          if [[ "$OPERATION" == "stopped" || "$OPERATION" == "release" ]]; then
              restore_host_noise
              release_hugepages
          fi
          
          if [[ "$OPERATION" == "stopped" || "$OPERATION" == "release" ]]; then
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

    # Keep remote testing safe. Remove this file with the enable-power-sync alias
    # once the VM lifecycle is boring again.
    touch /var/lib/libvirt/hooks/no-power-sync
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

      if [ ! -f /run/libvirt/nix-ovmf/edk2-x86_64-secure-code.fd ]; then
        echo "Missing Secure Boot OVMF firmware: /run/libvirt/nix-ovmf/edk2-x86_64-secure-code.fd"
        exit 1
      fi

      mkdir -p /var/lib/libvirt/qemu/acpi
      for TABLE in FACP DSDT; do
        if [ -f "/sys/firmware/acpi/tables/$TABLE" ]; then
          cp "/sys/firmware/acpi/tables/$TABLE" "/var/lib/libvirt/qemu/acpi/$TABLE.tmp"
          ${pkgs.perl}/bin/perl -0pi \
            -e 's/QEMU/AMI_/g; s/BOCHS/AMI00/g; s/BXPC/AMIP/g; s/BOCH/AMI0/g' \
            "/var/lib/libvirt/qemu/acpi/$TABLE.tmp"
          ${pkgs.python3}/bin/python3 -c 'import sys; p=sys.argv[1]; b=bytearray(open(p, "rb").read()); b[9]=0; b[9]=(-sum(b)) & 0xff; open(p, "wb").write(b)' \
            "/var/lib/libvirt/qemu/acpi/$TABLE.tmp"
          if [ "$TABLE" = "DSDT" ]; then
            mv "/var/lib/libvirt/qemu/acpi/$TABLE.tmp" /var/lib/libvirt/qemu/acpi/DSDT.aml
          else
            mv "/var/lib/libvirt/qemu/acpi/$TABLE.tmp" "/var/lib/libvirt/qemu/acpi/$TABLE.bin"
          fi
        fi
      done
      chmod 644 /var/lib/libvirt/qemu/acpi/FACP.bin /var/lib/libvirt/qemu/acpi/DSDT.aml 2>/dev/null || true
      if [ ! -f /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing ]; then
        rm -f /var/lib/libvirt/qemu/enable-acpi-spoofing
        rm -f /var/lib/libvirt/qemu/enable-facp-spoofing
        rm -f /var/lib/libvirt/qemu/enable-dsdt-spoofing
      elif [ -f /var/lib/libvirt/qemu/enable-acpi-spoofing ]; then
        echo "Retiring old full-FACP ACPI spoofing toggle name; use enable-facp-spoofing instead."
        mv /var/lib/libvirt/qemu/enable-acpi-spoofing /var/lib/libvirt/qemu/enable-facp-spoofing
      fi

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
        if [ -z "$VALUE" ] || [ "$VALUE" = "Not Specified" ] || [ "$VALUE" = "To Be Filled By O.E.M." ]; then
          VALUE="$2"
        fi
        xml_escape "$VALUE"
      }

      detect_tsc_hz() {
        if [ -f /var/lib/libvirt/qemu/tsc-frequency-hz ]; then
          ${pkgs.coreutils}/bin/cat /var/lib/libvirt/qemu/tsc-frequency-hz
          return
        fi

        MHZ="$(${pkgs.dmidecode}/bin/dmidecode -s processor-frequency 2>/dev/null | ${pkgs.gawk}/bin/awk '{ print int($1); exit }')"
        if [ -z "$MHZ" ] || [ "$MHZ" = "0" ]; then
          MHZ="$(${pkgs.util-linux}/bin/lscpu | ${pkgs.gawk}/bin/awk -F: '/CPU max MHz/ { gsub(/^[ \t]+/, "", $2); print int($2); exit }')"
        fi
        if [ -z "$MHZ" ] || [ "$MHZ" = "0" ]; then
          MHZ="$(${pkgs.gawk}/bin/awk -F: '/cpu MHz/ { gsub(/^[ \t]+/, "", $2); print int($2); exit }' /proc/cpuinfo)"
        fi
        if [ -z "$MHZ" ] || [ "$MHZ" = "0" ]; then
          MHZ="3800"
        fi

        # Request a stable virtual TSC just outside KVM's no-scaling tolerance.
        ${pkgs.gawk}/bin/awk -v mhz="$MHZ" 'BEGIN { printf "%.0f\n", mhz * 1000000 * 0.999 }'
      }

      RAW_UUID="$(${pkgs.coreutils}/bin/cat /run/secrets/motherboard_uuid)"
      RAW_SERIAL="$(${pkgs.coreutils}/bin/cat /run/secrets/motherboard_serial)"

      export UUID="$(xml_escape "$RAW_UUID")"
      export SERIAL="$(xml_escape "$RAW_SERIAL")"
      export BIOS_VENDOR="$(dmi_value bios-vendor "American Megatrends International, LLC.")"
      export BIOS_VERSION="$(dmi_value bios-version "1.0")"
      export BIOS_DATE="$(dmi_value bios-release-date "01/01/2024")"
      export SYSTEM_MANUFACTURER="$(dmi_value system-manufacturer "Micro-Star International Co., Ltd.")"
      export SYSTEM_PRODUCT="$(dmi_value system-product-name "MS-7C37")"
      export SYSTEM_VERSION="$(dmi_value system-version "1.0")"
      export SYSTEM_SERIAL="$(dmi_value system-serial-number "$RAW_SERIAL")"
      export BASEBOARD_MANUFACTURER="$(dmi_value baseboard-manufacturer "Micro-Star International Co., Ltd.")"
      export BASEBOARD_PRODUCT="$(dmi_value baseboard-product-name "MPG X570 GAMING EDGE WIFI (MS-7C37)")"
      export BASEBOARD_VERSION="$(dmi_value baseboard-version "1.0")"
      export BASEBOARD_SERIAL="$(dmi_value baseboard-serial-number "$RAW_SERIAL")"
      export CHASSIS_MANUFACTURER="$(dmi_value chassis-manufacturer "Micro-Star International Co., Ltd.")"
      export CHASSIS_VERSION="$(dmi_value chassis-version "1.0")"
      export CHASSIS_SERIAL="$(dmi_value chassis-serial-number "$RAW_SERIAL")"
      export CHASSIS_ASSET="$(dmi_value chassis-asset-tag "Default string")"
      export CHASSIS_SKU="$(dmi_value chassis-sku-number "Default string")"
      export TSC_FREQUENCY_HZ="$(detect_tsc_hz)"
      export QEMU_SYSTEM_X86_64="${config.virtualisation.libvirtd.qemu.package}/bin/qemu-system-x86_64"

      export QEMU_COMMANDLINE=""
      if [ -f /var/lib/libvirt/qemu/enable-facp-spoofing ]; then
        if [ ! -f /var/lib/libvirt/qemu/acpi/FACP.bin ]; then
          echo "Legacy FACP spoofing is enabled, but /var/lib/libvirt/qemu/acpi/FACP.bin is missing"
          exit 1
        fi

        QEMU_COMMANDLINE="  <qemu:commandline>
    <qemu:arg value='-acpitable'/>
    <qemu:arg value='file=/var/lib/libvirt/qemu/acpi/FACP.bin'/>"

        if [ -f /var/lib/libvirt/qemu/enable-dsdt-spoofing ]; then
          if [ ! -f /var/lib/libvirt/qemu/acpi/DSDT.aml ]; then
            echo "DSDT spoofing is enabled, but /var/lib/libvirt/qemu/acpi/DSDT.aml is missing"
            exit 1
          fi

          QEMU_COMMANDLINE="$QEMU_COMMANDLINE
    <qemu:arg value='-acpitable'/>
    <qemu:arg value='file=/var/lib/libvirt/qemu/acpi/DSDT.aml'/>"
        fi

        QEMU_COMMANDLINE="$QEMU_COMMANDLINE
  </qemu:commandline>"
      fi
      export QEMU_COMMANDLINE
      
      # Substitute the $UUID and $SERIAL variables into the template and define it
      ${pkgs.envsubst}/bin/envsubst \
        '$UUID $SERIAL $BIOS_VENDOR $BIOS_VERSION $BIOS_DATE $SYSTEM_MANUFACTURER $SYSTEM_PRODUCT $SYSTEM_VERSION $SYSTEM_SERIAL $BASEBOARD_MANUFACTURER $BASEBOARD_PRODUCT $BASEBOARD_VERSION $BASEBOARD_SERIAL $CHASSIS_MANUFACTURER $CHASSIS_VERSION $CHASSIS_SERIAL $CHASSIS_ASSET $CHASSIS_SKU $TSC_FREQUENCY_HZ $QEMU_SYSTEM_X86_64 $QEMU_COMMANDLINE' \
        < ${./win11-template.xml} > /tmp/win11-resolved.xml

      if ${pkgs.gnugrep}/bin/grep -q '\$[A-Z_]' /tmp/win11-resolved.xml; then
        echo "Unresolved placeholders remain in /tmp/win11-resolved.xml"
        ${pkgs.gnugrep}/bin/grep '\$[A-Z_]' /tmp/win11-resolved.xml
        exit 1
      fi

      ${pkgs.gnugrep}/bin/grep -q "timer name='tsc'.*frequency='$TSC_FREQUENCY_HZ'" /tmp/win11-resolved.xml

      ${pkgs.libvirt}/bin/virsh define /tmp/win11-resolved.xml
      ${pkgs.libvirt}/bin/virsh autostart win11
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
    (pkgs.writeShellScriptBin "enable-win11-acpi-spoofing" ''
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
      echo "ACPI spoofing is now the safe QEMU-header mode: no full host FACP/DSDT tables are injected."
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true
    '')
    (pkgs.writeShellScriptBin "enable-win11-legacy-facp-spoofing" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is running; shut it down before redefining ACPI tables." >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/mkdir -p /var/lib/libvirt/qemu
      ${pkgs.coreutils}/bin/touch /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing
      ${pkgs.coreutils}/bin/touch /var/lib/libvirt/qemu/enable-facp-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-dsdt-spoofing
      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true
    '')
    (pkgs.writeShellScriptBin "enable-win11-legacy-dsdt-spoofing" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is running; shut it down before redefining ACPI tables." >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/mkdir -p /var/lib/libvirt/qemu
      ${pkgs.coreutils}/bin/touch /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing
      ${pkgs.coreutils}/bin/touch /var/lib/libvirt/qemu/enable-facp-spoofing
      ${pkgs.coreutils}/bin/touch /var/lib/libvirt/qemu/enable-dsdt-spoofing
      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true
    '')
    (pkgs.writeShellScriptBin "disable-win11-acpi-spoofing" ''
      set -eu

      if ${pkgs.libvirt}/bin/virsh domstate win11 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q running; then
        echo "win11 is running; shut it down before redefining ACPI tables." >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-acpi-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-facp-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/enable-dsdt-spoofing
      ${pkgs.coreutils}/bin/rm -f /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing
      ${pkgs.systemd}/bin/systemctl restart define-win11-vm.service
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true
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
        ${pkgs.binutils}/bin/strings "$XML_QEMU" | ${pkgs.gnugrep}/bin/grep -E 'failed to disable hypercall quirk|tsc-scaling-patch' || true
        if ${pkgs.binutils}/bin/strings "$XML_QEMU" | ${pkgs.gnugrep}/bin/grep -q 'qemu-acpi-oem-patch=ALASKA,A M I'; then
          echo "qemu-acpi-oem=patched"
        else
          echo "qemu-acpi-oem=missing-marker"
        fi
      fi
      PID="$(${pkgs.procps}/bin/pgrep -f 'qemu-system-x86_64.*win11' | ${pkgs.coreutils}/bin/head -n1 || true)"
      if [ -n "$PID" ]; then
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o 'tsc-frequency=[^, ]*' || true
        ${pkgs.coreutils}/bin/tr '\000' ' ' < "/proc/$PID/cmdline" | ${pkgs.gnugrep}/bin/grep -o -- '-acpitable file=[^ ]*' || true
      fi

      echo
      echo "== TSC =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep "timer name='tsc'" || true
      ${pkgs.coreutils}/bin/printf 'kvm-tsc-cpuid-compensate.enabled='
      ${pkgs.coreutils}/bin/cat /sys/module/kvm_tsc_cpuid_compensate/parameters/enabled 2>/dev/null || ${pkgs.coreutils}/bin/echo unloaded
      ${pkgs.systemd}/bin/journalctl -b --no-pager | ${pkgs.gnugrep}/bin/grep -E 'tsc-scaling-patch|tsc exit compensation active|kvm-tsc-cpuid-compensate' || true

      echo
      echo "== OVMF / Secure Boot =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'loader|nvram|secure-boot|firmware' || true

      echo
      echo "== CPU / Hypervisor Masking =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E "feature policy='disable' name='hypervisor'|hidden state='on'|vendor_id state='on'|timer name='hypervclock'|timer name='tsc'" || true

      echo
      echo "== TPM =="
      ${pkgs.coreutils}/bin/ls -l /dev/tpm0 /dev/tpmrm0 2>/dev/null || true
      ${pkgs.coreutils}/bin/cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A4 '<tpm' || true

      echo
      echo "== ACPI =="
      echo "acpi-spoofing=qemu-header-patch"
      ${pkgs.coreutils}/bin/printf 'allow-legacy-acpi-spoofing='
      if [ -f /var/lib/libvirt/qemu/allow-legacy-acpi-spoofing ]; then ${pkgs.coreutils}/bin/echo on; else ${pkgs.coreutils}/bin/echo off; fi
      ${pkgs.coreutils}/bin/printf 'legacy-facp-spoofing='
      if [ -f /var/lib/libvirt/qemu/enable-facp-spoofing ]; then ${pkgs.coreutils}/bin/echo on; else ${pkgs.coreutils}/bin/echo off; fi
      ${pkgs.coreutils}/bin/printf 'legacy-dsdt-spoofing='
      if [ -f /var/lib/libvirt/qemu/enable-dsdt-spoofing ]; then ${pkgs.coreutils}/bin/echo on; else ${pkgs.coreutils}/bin/echo off; fi
      ${pkgs.coreutils}/bin/ls -l /var/lib/libvirt/qemu/acpi 2>/dev/null || true
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -A8 'qemu:commandline' || true

      echo
      echo "== CPU affinity =="
      ${pkgs.libvirt}/bin/virsh dumpxml win11 | ${pkgs.gnugrep}/bin/grep -E 'vcpupin|emulatorpin' || true
      ${pkgs.coreutils}/bin/cat /proc/irq/default_smp_affinity 2>/dev/null || true
      ${pkgs.coreutils}/bin/cat /sys/devices/virtual/workqueue/cpumask 2>/dev/null || true

      echo
      echo "== Hugepages =="
      ${pkgs.gnugrep}/bin/grep -E 'HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize' /proc/meminfo
      ${pkgs.coreutils}/bin/cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || true
    '')
  ];
}
