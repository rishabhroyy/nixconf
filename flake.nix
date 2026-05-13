{
  description = "Rishabh NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix, ... }@inputs:
  let
    # Overlay to patch QEMU with the vmcall/hypercall quirk fix and the
    # low-risk Windows VFIO identity tweaks used by the win11 domain.
    qemuPatchedOverlay = final: prev:
    let
      ovmfWin11 = (prev.OVMF.override {
        secureBoot = true;
        tpmSupport = true;
      }).overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace MdeModulePkg/MdeModulePkg.dec \
            --replace-fail 'gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemId|"INTEL "|VOID*|0x30001034' \
                           'gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemId|"ALASKA"|VOID*|0x30001034' \
            --replace-fail 'gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemTableId|0x20202020324B4445|UINT64|0x30001035' \
                           'gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiDefaultOemTableId|0x20202049204D2041|UINT64|0x30001035'
        '';
        postInstall = (old.postInstall or "") + ''
          mkdir -p "$fd/nix-support"
          cat > "$fd/nix-support/win11-ovmf-patches" <<'EOF'
ovmf-acpi-default-oem-id=ALASKA
ovmf-acpi-default-oem-table-id=A M I
EOF
        '';
      });
      applyWin11QemuPatches = pkg: pkg.overrideAttrs (old: {
        patches = (old.patches or []) ++ [ ./patches/qemu-disable-hypercall-quirk.patch ];
        postPatch = (old.postPatch or "") + ''
          substituteInPlace target/i386/kvm/kvm.c \
            --replace-fail '    return 0;
}

static void set_v8086_seg' '    if (kvm_vm_ioctl(s, KVM_ENABLE_CAP, &(struct kvm_enable_cap) {
        .cap = KVM_CAP_DISABLE_QUIRKS2,
        .flags = 0,
        .args = { KVM_X86_QUIRK_FIX_HYPERCALL_INSN },
    })) {
        warn_report("kvm: failed to disable hypercall quirk");
    }

    return 0;
}

static void set_v8086_seg'
          substituteInPlace include/hw/acpi/aml-build.h \
            --replace-fail '#define ACPI_BUILD_APPNAME6 "BOCHS "' '#define ACPI_BUILD_APPNAME6 "ALASKA"' \
            --replace-fail '#define ACPI_BUILD_APPNAME8 "BXPC    "' '#define ACPI_BUILD_APPNAME8 "A M I   "'

          QEMU0002_FILES="$(grep -R -l 'QEMU0002' hw include || true)"
          if [ -z "$QEMU0002_FILES" ]; then
            echo "QEMU0002 ACPI HID not found in QEMU source" >&2
            exit 1
          fi
          for file in $QEMU0002_FILES; do
            substituteInPlace "$file" --replace-fail 'QEMU0002' 'MSI0002'
          done

          substituteInPlace hw/pci-bridge/gen_pcie_root_port.c \
            --replace-fail 'k->vendor_id = PCI_VENDOR_ID_REDHAT;' 'k->vendor_id = PCI_VENDOR_ID_AMD;' \
            --replace-fail 'k->device_id = PCI_DEVICE_ID_REDHAT_PCIE_RP;' 'k->device_id = 0x1483;'
          substituteInPlace hw/pci-bridge/pcie_pci_bridge.c \
            --replace-fail 'k->vendor_id = PCI_VENDOR_ID_REDHAT;' 'k->vendor_id = PCI_VENDOR_ID_AMD;' \
            --replace-fail 'k->device_id = PCI_DEVICE_ID_REDHAT_PCIE_BRIDGE;' 'k->device_id = 0x1483;'
          substituteInPlace hw/usb/hcd-xhci-pci.c \
            --replace-fail 'k->vendor_id    = PCI_VENDOR_ID_REDHAT;' 'k->vendor_id    = PCI_VENDOR_ID_AMD;' \
            --replace-fail 'k->device_id    = PCI_DEVICE_ID_REDHAT_XHCI;' 'k->device_id    = 0x149c;
    k->subsystem_vendor_id = 0x1462;
    k->subsystem_id = 0x7c37;'
          SMBIOS_DIMM_SIZE_FILES="$(grep -R -l 'smbios_memory_device_size = 16 \* GiB' hw/i386 || true)"
          if [ -z "$SMBIOS_DIMM_SIZE_FILES" ]; then
            echo "No i386 SMBIOS 16 GiB memory device compatibility setting found" >&2
            exit 1
          fi
          for file in $SMBIOS_DIMM_SIZE_FILES; do
            substituteInPlace "$file" \
              --replace-fail 'smbios_memory_device_size = 16 * GiB' 'smbios_memory_device_size = 8 * GiB'
          done

          substituteInPlace hw/smbios/smbios.c \
            --replace-fail '    char loc_str[128];' '    char loc_str[128];
    char serial_str[128];
    char asset_str[128];' \
            --replace-fail '    t->memory_type = 0x07; /* RAM */
    t->type_detail = cpu_to_le16(0x02); /* Other */' '    t->memory_type = 0x1A; /* DDR4 */
    t->type_detail = cpu_to_le16(0x0080); /* Synchronous */' \
            --replace-fail '    SMBIOS_TABLE_SET_STR(17, serial_number_str, type17.serial);
    SMBIOS_TABLE_SET_STR(17, asset_tag_number_str, type17.asset);' '    if (type17.serial) {
        snprintf(serial_str, sizeof(serial_str), "%s%u", type17.serial, instance);
        SMBIOS_TABLE_SET_STR(17, serial_number_str, serial_str);
    } else {
        SMBIOS_TABLE_SET_STR(17, serial_number_str, type17.serial);
    }
    if (type17.asset) {
        snprintf(asset_str, sizeof(asset_str), "%s%u", type17.asset, instance);
        SMBIOS_TABLE_SET_STR(17, asset_tag_number_str, asset_str);
    } else {
        SMBIOS_TABLE_SET_STR(17, asset_tag_number_str, type17.asset);
    }'
        '';
        postInstall = (old.postInstall or "") + ''
          mkdir -p "$out/nix-support"
          cat > "$out/nix-support/win11-qemu-patches" <<'EOF'
qemu-vmcall-patch=present
qemu-forced-tsc-frequency-log=absent
qemu-acpi-oem=patched
qemu-fwcfg-acpi-hid=MSI0002
qemu-pcie-bridge-ids=1022:1483
qemu-xhci-id=1022:149c
qemu-smbios-memory-split=8GiB
qemu-smbios-memory-type=DDR4
qemu-smbios-memory-serials=per-dimm
EOF
        '';
      });
    in {
      qemu_win11 = applyWin11QemuPatches prev.qemu_kvm;
      ovmf_win11 = ovmfWin11;
    };
  in
  {
    nixosConfigurations = {
      rishabh-nix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          { nixpkgs.overlays = [ qemuPatchedOverlay ]; }
          sops-nix.nixosModules.sops
          ./hosts/rishabh-nix/configuration.nix
        ];
      };
    };
  };
}
