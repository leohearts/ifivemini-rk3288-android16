// SPDX-License-Identifier: GPL-2.0
/*
 * PROBE B (CONFIG_RK_PROBE_LATE, debug bisection only).
 *
 * Runs at late_initcall_sync, i.e. after every driver initcall. Sets the PMU
 * loader flag and issues a CRU first global soft reset. If the board
 * re-enumerates as rockusb 2207:0011, the kernel survived driver init.
 */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/printk.h>
#include <linux/processor.h>
#include <asm/barrier.h>

#define RK3288_PMU_BASE		0xff730000
#define RK3288_PMU_SIZE		SZ_4K
#define RK3288_PMU_SYS_REG0	0x94		/* 0xff730094 */
#define RK3288_CRU_BASE		0xff760000
#define RK3288_CRU_SIZE		SZ_4K
#define RK3288_CRU_GLB_SRST_FST	0x1b0		/* 0xff7601b0 */

#define RK_BOOT_LOADER		0x5242c301	/* REBOOT_FLAG | BOOT_BL_DOWNLOAD */
#define RK_CRU_SRST_MAGIC	0xfdb9

static int __init rk_probe_late(void)
{
	void __iomem *pmu, *cru;

	pr_emerg("RK_PROBE_LATE: reached\n");

	pmu = ioremap(RK3288_PMU_BASE, RK3288_PMU_SIZE);
	cru = ioremap(RK3288_CRU_BASE, RK3288_CRU_SIZE);
	if (!pmu || !cru)
		return 0;

	writel(RK_BOOT_LOADER, pmu + RK3288_PMU_SYS_REG0);
	wmb();
	writel(RK_CRU_SRST_MAGIC, cru + RK3288_CRU_GLB_SRST_FST);

	/* Reset is asynchronous; do not let the kernel continue. */
	while (1)
		cpu_relax();
}
late_initcall_sync(rk_probe_late);
