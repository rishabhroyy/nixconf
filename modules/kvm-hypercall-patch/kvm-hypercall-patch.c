#include "asm/kvm.h"
#include "asm/kvm_host.h"
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kvm_host.h>
#include <linux/ftrace.h>
#include <linux/kallsyms.h>
#include <linux/kprobes.h>

static struct kprobe kp_hypercall = {
    .symbol_name = "kvm_emulate_hypercall",
};

static int ud_hypercall(struct kvm_vcpu *vcpu, int cpl,
                       int (*complete_hypercall)(struct kvm_vcpu *))
{
    kvm_queue_exception(vcpu, UD_VECTOR);
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


static int __init init(void) {
    printk(KERN_INFO "Registering hypercall ud hook\n");

    register_kprobe(&kp_hypercall);
    hypercall_addr = (unsigned long)kp_hypercall.addr;
    unregister_kprobe(&kp_hypercall);

    ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 0, 0);
    register_ftrace_function(&hypercall_ops);

    return 0;
}

static void __exit exit(void) {
    printk(KERN_INFO "Unregistering hypercall ud hook\n");
    unregister_ftrace_function(&hypercall_ops);
    ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 1, 0);
}

module_init(init);
module_exit(exit);

MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("KVM_AMD");
MODULE_IMPORT_NS("KVM_INTEL");
MODULE_AUTHOR("Pantae");
MODULE_DESCRIPTION("Patch hypercall (vmmcall or vmcall) to raise UD");
