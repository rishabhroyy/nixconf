#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kvm_host.h>
#include <linux/ftrace.h>
#include <linux/kallsyms.h>
#include <linux/kprobes.h>

/* Dynamically resolved to avoid namespace enforcement for kvm_queue_exception.
 * In Linux 6.13+ the symbol is in a namespaced module (kvm-amd/kvm-intel),
 * so we resolve it at runtime via kprobe instead of a direct symbol reference. */
typedef void (*kvm_queue_exception_fn_t)(struct kvm_vcpu *vcpu, unsigned nr);
static kvm_queue_exception_fn_t kvm_queue_exception_resolved;

static struct kprobe kp_hypercall = {
    .symbol_name = "kvm_emulate_hypercall",
};

static struct kprobe kp_queue_exc = {
    .symbol_name = "kvm_queue_exception",
};

static int ud_hypercall(struct kvm_vcpu *vcpu, int cpl,
                       int (*complete_hypercall)(struct kvm_vcpu *))
{
    if (kvm_queue_exception_resolved)
        kvm_queue_exception_resolved(vcpu, UD_VECTOR);
    return 1;
}

static unsigned long hypercall_addr;

static void notrace hypercall_hook(unsigned long ip, unsigned long parent_ip,
                             struct ftrace_ops *ops, struct ftrace_regs *fregs)
{
    struct pt_regs *regs = ftrace_get_regs(fregs);

    regs->ip = (unsigned long)ud_hypercall;
}

static struct ftrace_ops hypercall_ops = {
    .func = hypercall_hook,
    .flags = FTRACE_OPS_FL_SAVE_REGS |
             FTRACE_OPS_FL_IPMODIFY,
};

static int __init kvm_hypercall_patch_init(void) {
    int ret;

    printk(KERN_INFO "kvm-hypercall-patch: Registering hypercall ud hook\n");

    /* Resolve kvm_queue_exception dynamically to avoid namespace enforcement */
    ret = register_kprobe(&kp_queue_exc);
    if (ret < 0) {
        printk(KERN_ERR "kvm-hypercall-patch: Failed to resolve kvm_queue_exception: %d\n", ret);
        return ret;
    }
    kvm_queue_exception_resolved = (kvm_queue_exception_fn_t)kp_queue_exc.addr;
    unregister_kprobe(&kp_queue_exc);

    /* Resolve kvm_emulate_hypercall for ftrace hooking */
    ret = register_kprobe(&kp_hypercall);
    if (ret < 0) {
        printk(KERN_ERR "kvm-hypercall-patch: Failed to resolve kvm_emulate_hypercall: %d\n", ret);
        return ret;
    }
    hypercall_addr = (unsigned long)kp_hypercall.addr;
    unregister_kprobe(&kp_hypercall);

    ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 0, 0);
    register_ftrace_function(&hypercall_ops);

    return 0;
}

static void __exit kvm_hypercall_patch_exit(void) {
    printk(KERN_INFO "kvm-hypercall-patch: Unregistering hypercall ud hook\n");
    unregister_ftrace_function(&hypercall_ops);
    ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 1, 0);
}

module_init(kvm_hypercall_patch_init);
module_exit(kvm_hypercall_patch_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Pantae");
MODULE_DESCRIPTION("Patch hypercall (vmmcall or vmcall) to raise UD");
