#include "asm/kvm_host.h"
#include <asm/msr.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/kvm_host.h>
#include <linux/module.h>

typedef void (*kvm_vcpu_write_tsc_offset_fn_t)(struct kvm_vcpu *vcpu, u64 offset);
typedef u64 (*kvm_scale_tsc_fn_t)(u64 tsc, u64 ratio);

struct cpuid_probe_data {
	struct kvm_vcpu *vcpu;
	u64 start_tsc;
};

static bool enabled;
static ulong target_cycles = 250;
static ulong max_cycles = 200000;

module_param(enabled, bool, 0644);
MODULE_PARM_DESC(enabled, "Enable CPUID VM-exit TSC compensation.");
module_param(target_cycles, ulong, 0644);
MODULE_PARM_DESC(target_cycles, "Guest-visible CPUID latency target, in guest TSC cycles.");
module_param(max_cycles, ulong, 0644);
MODULE_PARM_DESC(max_cycles, "Ignore compensation above this guest TSC cycle delta.");

static kvm_vcpu_write_tsc_offset_fn_t kvm_vcpu_write_tsc_offset_resolved;
static kvm_scale_tsc_fn_t kvm_scale_tsc_resolved;

static unsigned long resolve_symbol_any(const char *const *names)
{
	struct kprobe kp = {};
	unsigned long addr;
	int ret;

	for (; *names; names++) {
		kp.symbol_name = *names;
		ret = register_kprobe(&kp);
		if (ret < 0)
			continue;

		addr = (unsigned long)kp.addr;
		unregister_kprobe(&kp);
		return addr;
	}

	return 0;
}

static int cpuid_entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cpuid_probe_data *data;

	data = (struct cpuid_probe_data *)ri->data;
	data->vcpu = (struct kvm_vcpu *)regs->di;
	data->start_tsc = rdtsc_ordered();

	return 0;
}

static int cpuid_ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct cpuid_probe_data *data = (struct cpuid_probe_data *)ri->data;
	struct kvm_vcpu *vcpu = data->vcpu;
	u64 raw_delta;
	u64 guest_delta;
	u64 compensation;

	if (!enabled || !vcpu || !data->start_tsc || vcpu->arch.guest_tsc_protected)
		return 0;

	raw_delta = rdtsc_ordered() - data->start_tsc;
	if (!raw_delta)
		return 0;

	if (kvm_scale_tsc_resolved)
		guest_delta = kvm_scale_tsc_resolved(raw_delta, vcpu->arch.l1_tsc_scaling_ratio);
	else
		guest_delta = raw_delta;

	if (guest_delta <= target_cycles || guest_delta > max_cycles)
		return 0;

	compensation = guest_delta - target_cycles;
	kvm_vcpu_write_tsc_offset_resolved(vcpu, vcpu->arch.l1_tsc_offset - compensation);

	return 0;
}

static struct kretprobe cpuid_retprobe = {
	.kp.symbol_name = "kvm_emulate_cpuid",
	.entry_handler = cpuid_entry_handler,
	.handler = cpuid_ret_handler,
	.data_size = sizeof(struct cpuid_probe_data),
	.maxactive = 128,
};

static int __init kvm_tsc_cpuid_compensate_init(void)
{
	static const char *const write_tsc_offset_names[] = {
		"kvm_vcpu_write_tsc_offset",
		"kvm_vcpu_write_tsc_offset.part.0",
		NULL,
	};
	static const char *const scale_tsc_names[] = {
		"kvm_scale_tsc",
		NULL,
	};
	unsigned long addr;
	int ret;

	addr = resolve_symbol_any(write_tsc_offset_names);
	if (!addr) {
		pr_err("kvm-tsc-cpuid-compensate: failed to resolve kvm_vcpu_write_tsc_offset\n");
		return -ENOENT;
	}
	kvm_vcpu_write_tsc_offset_resolved = (kvm_vcpu_write_tsc_offset_fn_t)addr;

	addr = resolve_symbol_any(scale_tsc_names);
	if (addr)
		kvm_scale_tsc_resolved = (kvm_scale_tsc_fn_t)addr;
	else
		pr_warn("kvm-tsc-cpuid-compensate: failed to resolve kvm_scale_tsc, using raw host TSC deltas\n");

	ret = register_kretprobe(&cpuid_retprobe);
	if (ret < 0) {
		pr_err("kvm-tsc-cpuid-compensate: failed to hook kvm_emulate_cpuid: %d\n", ret);
		return ret;
	}

	pr_info("kvm-tsc-cpuid-compensate: loaded enabled=%d target_cycles=%lu max_cycles=%lu\n",
		enabled, target_cycles, max_cycles);
	return 0;
}

static void __exit kvm_tsc_cpuid_compensate_exit(void)
{
	unregister_kretprobe(&cpuid_retprobe);
	pr_info("kvm-tsc-cpuid-compensate: unloaded\n");
}

module_init(kvm_tsc_cpuid_compensate_init);
module_exit(kvm_tsc_cpuid_compensate_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Codex");
MODULE_DESCRIPTION("Compensate guest TSC for KVM CPUID VM-exit latency");
MODULE_SOFTDEP("pre: kvm kvm-amd");
