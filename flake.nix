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

# Find kvm_arch_init's body and insert before its closing "return 0;\n}"
func_start = content.find("int kvm_arch_init(")
if func_start == -1:
    print("ERROR: kvm_arch_init not found", file=sys.stderr)
    sys.exit(1)

# Find the end of kvm_arch_init by tracking brace depth from the opening {
brace_start = content.find("{", func_start)
depth = 0
func_end = -1
for i in range(brace_start, len(content)):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            func_end = i
            break

if func_end == -1:
    print("ERROR: Could not find end of kvm_arch_init", file=sys.stderr)
    sys.exit(1)

# Now find "    return 0;" within the function bounds only
func_body = content[func_start:func_end]
ret_idx = func_body.rfind("    return 0;")
if ret_idx == -1:
    print("ERROR: Could not find 'return 0;' in kvm_arch_init", file=sys.stderr)
    sys.exit(1)

insert_pos = func_start + ret_idx

content = content[:insert_pos] + inject + content[insert_pos:]

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
