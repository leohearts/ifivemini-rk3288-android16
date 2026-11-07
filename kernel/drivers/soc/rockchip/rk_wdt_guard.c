// SPDX-License-Identifier: GPL-2.0
/*
 * Rockchip RK3288 watchdog petter.
 *
 * The decompressor stub (arch/arm/boot/compressed/head.S, guarded by
 * CONFIG_RK_WDT_GUARD) ungate its pclk and arm the always-on PMU watchdog
 * (top=15, so the timeout is 2^(16+top) / rate = 2^31 / rate, where rate is
 * pclk_wdt = pclk_pd_alive divided by CLKSEL_CON(33)[12:8]; neither the
 * divider nor pclk_pd_alive has been measured on this board, so no absolute
 * timeout figure is assumed)
 * and sets the PMU loader reboot flag so a reset lands in rockusb
 * download mode. Nothing else in the kernel touches that watchdog, so
 * without a petter a *healthy* kernel would be reset after one timeout
 * (2^31 / rate) exactly
 * like a hung one, which makes "kernel alive" and "kernel hung"
 * indistinguishable from the host side.
 *
 * This thread pets the counter once immediately (the watchdog was armed
 * at t=0 by the decompressor, long before late_initcall runs) and then
 * every 30s, but only RK3288_WDT_PET_COUNT times after that first reload
 * (8 x 30s = 240s), then stops and lets the watchdog fire. Infinite
 * petting would create a worse corner: if the kernel got past
 * late_initcall but userspace never brings up the USB gadget, the board
 * would be neither reachable (no adb, no rockusb) nor ever reset, so it
 * would need a human to power-cycle it. Bounded petting keeps every boot
 * a few-minutes-bounded experiment: either userspace comes up inside
 * ~240s, or the board resets into rockusb on its own.
 *
 * Deliberately minimal: no DT lookup, no clk framework, no watchdog
 * device registration - the watchdog is already running, we only reload
 * it.
 */
#include <linux/io.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/err.h>
#include <asm/memory.h>

/*
 * RK_WDT_GUARD_EMU (see arch/arm/mach-rockchip/Kconfig): QEMU's "-M virt"
 * machine maps no RK3288 PMU/alive block, so the emulation build points the
 * same offsets at plain lowmem instead, exactly like the decompressor stub.
 */
#ifdef CONFIG_RK_WDT_GUARD_EMU
#define RK3288_WDT_BASE		0x4ff80000UL
#else
#define RK3288_WDT_BASE		0xff800000UL
#endif
#define RK3288_WDT_CRR		0x0c
#define RK3288_WDT_CRR_MAGIC	0x76
/*
 * Radix for the reload period. Must stay well below the shortest plausible
 * timeout. The timeout is 2^(16+top) / rate, with top=15 as written by the
 * decompressor stub, so 2^31 / rate, where rate is pclk_wdt = pclk_pd_alive
 * divided by CLKSEL_CON(33)[12:8]. Neither the divider nor pclk_pd_alive has
 * been measured on this board, so no absolute timeout figure is assumed
 * here; a slower rate only makes the timeout longer, never shorter.
 */
#define RK3288_WDT_PET_SECS	30
#define RK3288_WDT_PET_COUNT	8

#ifdef CONFIG_RK_WDT_GUARD

static void __iomem *rk_wdt_base;

static int rk_wdt_guard_thread(void *data)
{
	int i;

	/*
	 * Pet once before sleeping: the watchdog was armed by the
	 * decompressor stub at t=0 with one timeout (2^(16+top) / rate =
	 * 2^31 / pclk_wdt, where pclk_wdt is pclk_pd_alive divided by
	 * CLKSEL_CON(33)[12:8] - never measured on this board, so the
	 * absolute length is unknown), while this thread
	 * only starts at late_initcall, which can in principle run long
	 * after that. Sleeping first would let the dog fire right before
	 * the first reload on a perfectly healthy kernel.
	 */
	iowrite32(RK3288_WDT_CRR_MAGIC, rk_wdt_base + RK3288_WDT_CRR);

	for (i = 0; i < RK3288_WDT_PET_COUNT; i++) {
		/*
		 * Sleep in TASK_IDLE, not TASK_UNINTERRUPTIBLE. ssleep() goes
		 * through schedule_timeout_uninterruptible(), which parks the
		 * thread in D state for the whole 30s; the hung task detector
		 * then dumps a 12-line backtrace every 10s, so the ~240s of
		 * petting alone puts 20+ backtraces on the console - and the
		 * whole point of this kernel is what it prints on screen.
		 * TASK_IDLE is TASK_UNINTERRUPTIBLE|TASK_NOLOAD, which the
		 * hung task detector explicitly skips while still ignoring
		 * signals, so the 8 x 30s cadence (and therefore the "bites
		 * about one timeout later" property) is preserved exactly.
		 *
		 * msleep_interruptible() must NOT be used here: a signal
		 * makes it return early, the nine reloads collapse into a few
		 * tens of seconds and the "bites after ~330s" property is
		 * silently lost - and nothing in QEMU signals the kthread, so
		 * the emulation build would not catch that.
		 */
		schedule_timeout_idle(RK3288_WDT_PET_SECS * HZ);
		if (kthread_should_stop())
			return 0;
		iowrite32(RK3288_WDT_CRR_MAGIC, rk_wdt_base + RK3288_WDT_CRR);
	}

	pr_info("rk_wdt_guard: petting finished, letting the watchdog fire one timeout later\n");

	return 0;
}

static int __init rk_wdt_guard_init(void)
{
	struct task_struct *task;

#ifdef CONFIG_RK_WDT_GUARD_EMU
	/*
	 * Emulation only: the "watchdog" is ordinary lowmem, already covered
	 * by the linear map.  ioremap() of a pfn_valid() range would just
	 * trigger the WARN_ON() in __arm_ioremap_pfn_caller().
	 */
	rk_wdt_base = (void __iomem *)__va(RK3288_WDT_BASE);
#else
	rk_wdt_base = ioremap(RK3288_WDT_BASE, 0x100);
#endif
	if (!rk_wdt_base) {
		pr_err("rk_wdt_guard: cannot map %#lx, watchdog stays un-fed\n",
		       RK3288_WDT_BASE);
		return -ENOMEM;
	}

	task = kthread_run(rk_wdt_guard_thread, NULL, "rk-wdt-pet");
	if (IS_ERR(task)) {
		pr_err("rk_wdt_guard: cannot start thread: %ld\n",
		       PTR_ERR(task));
#ifndef CONFIG_RK_WDT_GUARD_EMU
		iounmap(rk_wdt_base);
#endif
		rk_wdt_base = NULL;
		return PTR_ERR(task);
	}

	pr_info("rk_wdt_guard: petting RK3288 WDT every 30s\n");

	return 0;
}
late_initcall(rk_wdt_guard_init);

#endif /* CONFIG_RK_WDT_GUARD */
