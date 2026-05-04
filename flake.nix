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
    qemuPatchedOverlay = final: prev:
    let
      applyHypercallFix = pkg: pkg.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # Disable KVM_X86_QUIRK_FIX_HYPERCALL_INSN so QEMU stops rewriting
          # VMCALL<->VMMCALL instructions, which anti-cheats detect and BSOD on.
          python3 - <<'PYEOF'
import sys

path = "target/i386/kvm/kvm.c"
with open(path) as f:
    content = f.read()

# The code to inject before the final return in kvm_arch_init
inject = """
    /* vmcall-patch: disable hypercall quirk to prevent anti-cheat BSOD */
#ifndef KVM_CAP_DISABLE_QUIRKS2
#define KVM_CAP_DISABLE_QUIRKS2 213
#endif
#ifndef KVM_X86_QUIRK_FIX_HYPERCALL_INSN
#define KVM_X86_QUIRK_FIX_HYPERCALL_INSN (1 << 4)
#endif
    if (kvm_vm_enable_cap(s, KVM_CAP_DISABLE_QUIRKS2, 0,
                          KVM_X86_QUIRK_FIX_HYPERCALL_INSN)) {
        warn_report("kvm: failed to disable hypercall quirk");
    }

"""

# Find kvm_arch_init and its final "return 0;" before closing brace
func_start = content.find("int kvm_arch_init(")
if func_start == -1:
    print("ERROR: kvm_arch_init not found", file=sys.stderr)
    sys.exit(1)

# Find the last "    return 0;" within the function
search_from = func_start
last_return = -1
pos = search_from
while True:
    idx = content.find("    return 0;\n}", pos)
    if idx == -1:
        break
    last_return = idx
    pos = idx + 1

if last_return == -1:
    print("ERROR: Could not find insertion point in kvm_arch_init", file=sys.stderr)
    sys.exit(1)

content = content[:last_return] + inject + content[last_return:]

with open(path, "w") as f:
    f.write(content)

print("vmcall-patch: applied hypercall quirk fix to", path)
PYEOF
        '';
      });
    in {
      qemu_kvm = applyHypercallFix prev.qemu_kvm;
      qemu = applyHypercallFix prev.qemu;
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
