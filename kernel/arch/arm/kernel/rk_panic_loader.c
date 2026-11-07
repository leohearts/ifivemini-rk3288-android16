// SPDX-License-Identifier: GPL-2.0
/*
 * RK_PANIC_TO_LOADER: turn a panic (or an explicit "reboot loader") into a
 * rockusb/loader return.
 *
 * The PMU_SYS_REG0 loader flag (0x5242C301, the same value setup.c and
 * head.S use) is written from the panic notifier chain, and from the reboot
 * notifier chain when userspace asks for `reboot loader` / `bootloader`.
 * The restart path then resets the SoC; the boot ROM sees the flag and
 * re-enters rockusb instead of booting this kernel again.
 *
 * The MMIO window is mapped once at init; the notifiers only do a writel().
 */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <asm/arch_timer.h>
#include <asm/processor.h>
#include <linux/notifier.h>
#include <linux/reboot.h>
#include <linux/string.h>

#define RK_PMU_SYS_REG0_PHYS	0xff730094
#define RK_LOADER_FLAG		0x5242c301

static void __iomem *rk_pmu_sys_reg0;

#define RK_PANIC_HOLD_S		12
#define RK_REBOOT_HOLD_S	24
#define RK_HOLD_HZ		24000000ULL	/* arch counter (CNTFRQ) */

/*
 * Busy-wait on the arch counter; mdelay() was unreliable here. Local IRQs
 * are masked only for the wait and restored afterwards, so later reboot
 * notifiers and driver .shutdown callbacks run in their normal state.
 */
static void rk_hold_counter(unsigned int sec)
{
	unsigned long flags;
	u64 t0;

	local_irq_save(flags);
	t0 = arch_counter_get_cntvct();
	while (arch_counter_get_cntvct() - t0 < (u64)sec * RK_HOLD_HZ)
		cpu_relax();
	local_irq_restore(flags);
}

static void rk_set_loader_flag(unsigned int hold_s)
{
	if (rk_pmu_sys_reg0)
		writel(RK_LOADER_FLAG, rk_pmu_sys_reg0);
	rk_hold_counter(hold_s);
}

static int rk_panic_loader_notify(struct notifier_block *nb,
				  unsigned long event, void *data)
{
	rk_set_loader_flag(RK_PANIC_HOLD_S);
	return NOTIFY_DONE;
}

static struct notifier_block rk_panic_loader_nb = {
	.notifier_call	= rk_panic_loader_notify,
	.priority	= INT_MAX,
};

static int rk_reboot_loader_notify(struct notifier_block *nb,
				   unsigned long event, void *data)
{
	const char *cmd = data;

	if (event == SYS_RESTART && cmd &&
	    (!strcmp(cmd, "loader") || !strcmp(cmd, "bootloader")))
		rk_set_loader_flag(RK_REBOOT_HOLD_S);
	return NOTIFY_DONE;
}

static struct notifier_block rk_reboot_loader_nb = {
	.notifier_call	= rk_reboot_loader_notify,
	.priority	= INT_MAX,
};

static int __init rk_panic_loader_init(void)
{
	rk_pmu_sys_reg0 = ioremap(RK_PMU_SYS_REG0_PHYS, 4);
	if (!rk_pmu_sys_reg0) {
		pr_err("rk_panic_loader: ioremap(0x%x) failed\n",
		       RK_PMU_SYS_REG0_PHYS);
		return -ENOMEM;
	}
	atomic_notifier_chain_register(&panic_notifier_list,
				       &rk_panic_loader_nb);
	register_reboot_notifier(&rk_reboot_loader_nb);
	pr_info("rk_panic_loader: panic and 'reboot loader' arm loader flag\n");
	return 0;
}
arch_initcall(rk_panic_loader_init);
