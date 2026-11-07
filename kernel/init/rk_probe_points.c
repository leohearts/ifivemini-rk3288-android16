// SPDX-License-Identifier: GPL-2.0
/*
 * RK3288 bring-up checkpoint probes (debug only, CONFIG_RK_PROBE_POINTS).
 *
 * Selected by "rkprobe=N" on the kernel command line (default 0 = disabled).
 * "rkprobe_unbind=1" releases the dwc2 drivers on the OTG and host1 ports
 * before the reset. "rkprobe_grfrestore=1" then restores the USB PHY/UOC
 * GRF controls to the values the PHY driver leaves after its probe.
 * See include/linux/rk_probe.h.
 */
#include <linux/device.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/printk.h>
#include <linux/rk_probe.h>
#include <linux/rk_logdump.h>
#include <linux/processor.h>
#include <asm/barrier.h>
#include <linux/jiffies.h>
#include <asm/arch_timer.h>

#define RK3288_PMU_BASE		0xff730000
#define RK3288_PMU_SYS_REG0	0x94		/* 0xff730094 */
#define RK3288_CRU_BASE		0xff760000
#define RK3288_CRU_GLB_SRST_FST	0x1b0		/* 0xff7601b0 */
#define RK3288_GRF_BASE		0xff770000

/* PHY/UOC GRF controls, HIWORD_UPDATE format (mask in bits 31:16). */
#define RK3288_UOC0_CON0	0x320
#define RK3288_UOC0_CON2	0x328
#define RK3288_UOC0_CON3	0x32c
#define RK3288_UOC0_CON4	0x330
#define RK3288_UOC1_CON0	0x334
#define RK3288_UOC2_CON0	0x348
#define UOC_CON0_SIDDQ		BIT(13)

#define RK_BOOT_LOADER		0x5242c301	/* REBOOT_FLAG | BOOT_BL_DOWNLOAD */
#define RK_CRU_SRST_MAGIC	0xfdb9

static int rk_probe_sel;
static int rk_probe_unbind;
static int rk_probe_grfrestore;
static int rk_probe_cnt;
static int rk_probe_hold;
static int rk_probe_dump;

static int __init rk_probe_parse(char *str)
{
	return kstrtoint(str, 0, &rk_probe_sel) ? -EINVAL : 0;
}
early_param("rkprobe", rk_probe_parse);

static int __init rk_probe_unbind_parse(char *str)
{
	return kstrtoint(str, 0, &rk_probe_unbind) ? -EINVAL : 0;
}
early_param("rkprobe_unbind", rk_probe_unbind_parse);

static int __init rk_probe_grfrestore_parse(char *str)
{
	return kstrtoint(str, 0, &rk_probe_grfrestore) ? -EINVAL : 0;
}
early_param("rkprobe_grfrestore", rk_probe_grfrestore_parse);

static int __init rk_probe_hold_parse(char *str)
{
	return kstrtoint(str, 0, &rk_probe_hold) ? -EINVAL : 0;
}
early_param("rkprobe_hold", rk_probe_hold_parse);

static int __init rk_probe_dump_parse(char *str)
{
	return kstrtoint(str, 0, &rk_probe_dump) ? -EINVAL : 0;
}
early_param("rkprobe_dump", rk_probe_dump_parse);

static int __init rk_probe_cnt_parse(char *str)
{
	return kstrtoint(str, 0, &rk_probe_cnt) ? -EINVAL : 0;
}
early_param("rkcnt", rk_probe_cnt_parse);

static void rk_probe_release_port(const char *name)
{
	struct device *dev;

	dev = bus_find_device_by_name(&platform_bus_type, NULL, name);
	if (!dev)
		return;

	device_release_driver(dev);
	put_device(dev);
}

static void rk_probe_grf_restore(void __iomem *grf)
{
	/* UOC0 (OTG, ff580000): PHY driver probe defaults, SIDDQ set. */
	writel(0xffff2089, grf + RK3288_UOC0_CON0);
	writel(0xffff0d08, grf + RK3288_UOC0_CON2);
	writel(0xffff0001, grf + RK3288_UOC0_CON3);
	/* Clear BVALID IRQ enable and pending (phy_init). */
	writel(0x000c0000, grf + RK3288_UOC0_CON4);
	/* UOC1 (EHCI) and UOC2 (host1, ff540000): SIDDQ set, as after probe. */
	writel(0x20002000, grf + RK3288_UOC1_CON0);
	writel(0x20002000, grf + RK3288_UOC2_CON0);
}

static void rk_probe_reset(void)
{
	void __iomem *pmu, *cru;

	pmu = ioremap(RK3288_PMU_BASE, PAGE_SIZE);
	cru = ioremap(RK3288_CRU_BASE, PAGE_SIZE);
	if (!pmu || !cru) {
		if (pmu)
			iounmap(pmu);
		if (cru)
			iounmap(cru);
		return;
	}

	writel(RK_BOOT_LOADER, pmu + RK3288_PMU_SYS_REG0);
	wmb();
	writel(RK_CRU_SRST_MAGIC, cru + RK3288_CRU_GLB_SRST_FST);

	/* Reset is asynchronous; do not let the kernel continue. */
	while (1)
		cpu_relax();
}

/*
 * rkcnt=1: checkpoint 2 counter test. Pure CPU loops, no timers used for the
 * wait. Loop cost is an estimate (~2 cycles/iteration at ~1.8 GHz, i.e. about
 * 0.2 s per 200M-iteration round), not a measurement; calibrate from device runs.
 */
#define RK_CNT_LOOP		200000000UL
#define RK_CNT_LONG_ROUNDS	64	/* ~13-15 s estimate */

static void rk_probe_spin(unsigned long n)
{
	unsigned long i;

	for (i = 0; i < n; i++)
		asm volatile("" ::: "memory");
}

static void rk_probe_cnt_test(void)
{
	u64 c0, c1;
	unsigned long j0, j1;
	int r;

	j0 = jiffies;
	c0 = arch_counter_get_cntvct();
	rk_probe_spin(RK_CNT_LOOP);
	c1 = arch_counter_get_cntvct();
	j1 = jiffies;

	pr_emerg("RK_CNT: cntvct %llx -> %llx jiffies %lu -> %lu\n",
		 (unsigned long long)c0, (unsigned long long)c1, j0, j1);

	if (c1 > c0) {
		for (r = 0; r < RK_CNT_LONG_ROUNDS; r++)
			rk_probe_spin(RK_CNT_LOOP);
		pr_emerg("RK_CNT: counter running, extra spin done, resetting\n");
	} else {
		pr_emerg("RK_CNT: counter stalled, resetting now\n");
	}

	rk_probe_reset();
}

static void rk_probe_hold_wait(int sec)
{
	u64 t0;

	if (sec <= 0)
		return;
	local_irq_disable();
	t0 = arch_counter_get_cntvct();
	while (arch_counter_get_cntvct() - t0 < (u64)sec * 24000000ULL)
		cpu_relax();
}

void rk_probe_point(int n)
{
	if (n == 2 && rk_probe_cnt)
		rk_probe_cnt_test();

	if (!rk_probe_sel || n != rk_probe_sel)
		return;

	if (rk_probe_unbind) {
		rk_probe_release_port("ff580000.usb");
		rk_probe_release_port("ff540000.usb");
	}

	if (rk_probe_grfrestore) {
		void __iomem *grf = ioremap(RK3288_GRF_BASE, PAGE_SIZE);

		if (grf) {
			rk_probe_grf_restore(grf);
			iounmap(grf);
		}
	}

	pr_emerg("RK_PROBE_POINT: %d reached\n", n);
	if (rk_probe_dump)
		rk_logdump_to_kpanic("rkprobe");
	if (rk_probe_dump == 1)
		rk_probe_hold_wait(4 * rk_logdump_stage());
	else if (rk_probe_dump == 2)
		rk_probe_hold_wait(4 * min(rk_logdump_disks(), 8));
	else
		rk_probe_hold_wait(rk_probe_hold);
	rk_probe_reset();
}
