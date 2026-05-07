{
  description = "PROJECT GHOST-HOST NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sops-nix, ... }@inputs:
  let
    # Overlay to patch QEMU with the vmcall/hypercall quirk fix.
    # This prevents anti-cheats (Genshin, Vanguard) from detecting the VMCALL
    # instruction rewriting quirk and triggering a BSOD.
    # Applies qemu-vmcall-patch/changes.patch via the standard NixOS patches mechanism.
    qemuPatchedOverlay = final: prev:
    let
      applyGhostQemuPatches = pkg: pkg.overrideAttrs (old: {
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
          substituteInPlace target/i386/kvm/kvm.c \
            --replace-fail '    return 0;
}

static bool tsc_is_stable_and_known' '    if (env->tsc_khz) {
        info_report("tsc-scaling-patch: guest TSC frequency set to %" PRId64 " kHz; qemu-acpi-oem-patch=ALASKA,A M I",
                    env->tsc_khz);
    }

    return 0;
}

static bool tsc_is_stable_and_known'
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
        '';
        postInstall = (old.postInstall or "") + ''
          mkdir -p "$out/nix-support"
          cat > "$out/nix-support/ghost-qemu-patches" <<'EOF'
qemu-vmcall-patch=present
qemu-tsc-frequency-log=present
qemu-acpi-oem=patched
qemu-fwcfg-acpi-hid=MSI0002
qemu-pcie-bridge-ids=1022:1483
EOF
        '';
      });
    in {
      qemu_ghost = applyGhostQemuPatches prev.qemu_kvm;
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
