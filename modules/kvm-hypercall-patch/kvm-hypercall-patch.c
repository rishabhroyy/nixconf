#include "asm/kvm.h"
#include "asm/kvm_host.h"
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kvm_host.h>
#include <linux/ftrace.h>
#include <linux/kallsyms.h>
#include <linux/kprobes.h>

typedef void (*kvm_queue_exception_fn_t)(struct kvm_vcpu *vcpu, unsigned nr);
static kvm_queue_exception_fn_t kvm_queue_exception_resolved;

static struct kprobe kp_hypercall = {
    .symbol_name = "kvm_emulate_hypercall",
};

static struct kprobe kp_queue_exception = {
    .symbol_name = "kvm_queue_exception",
};

static int ud_hypercall(struct kvm_vcpu *vcpu, int cpl,
                       int (*complete_hypercall)(struct kvm_vcpu *))
{
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

    printk(KERN_INFO "Registering hypercall ud hook\n");

    ret = register_kprobe(&kp_queue_exception);
    if (ret < 0) {
        printk(KERN_ERR "Failed to resolve kvm_queue_exception: %d\n", ret);
        return ret;
    }
    kvm_queue_exception_resolved = (kvm_queue_exception_fn_t)kp_queue_exception.addr;
    unregister_kprobe(&kp_queue_exception);

    ret = register_kprobe(&kp_hypercall);
    if (ret < 0) {
        printk(KERN_ERR "Failed to resolve kvm_emulate_hypercall: %d\n", ret);
        return ret;
    }
    hypercall_addr = (unsigned long)kp_hypercall.addr;
    unregister_kprobe(&kp_hypercall);

    ret = ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 0, 0);
    if (ret) {
        printk(KERN_ERR "Failed to set hypercall ftrace filter: %d\n", ret);
        return ret;
    }

    ret = register_ftrace_function(&hypercall_ops);
    if (ret) {
        printk(KERN_ERR "Failed to register hypercall ftrace hook: %d\n", ret);
        ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 1, 0);
        return ret;
    }

    return 0;
}

static void __exit kvm_hypercall_patch_exit(void) {
    printk(KERN_INFO "Unregistering hypercall ud hook\n");
    unregister_ftrace_function(&hypercall_ops);
    ftrace_set_filter_ip(&hypercall_ops, hypercall_addr, 1, 0);
}

module_init(kvm_hypercall_patch_init);
module_exit(kvm_hypercall_patch_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Pantae");
MODULE_DESCRIPTION("Patch hypercall (vmmcall or vmcall) to raise UD");
MODULE_SOFTDEP("pre: kvm-amd");
