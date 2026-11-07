// SPDX-License-Identifier: GPL-2.0
/*
 * RK3288 hardware watchdog backstop (CONFIG_RK_WDT_BACKSTOP).
 *
 * Turns a hard hang (all CPUs and the bus frozen, no panic path runs) into a
 * SoC system reset. DRAM survives a reset, so the ramoops console log written
 * before the hang remains readable by the dump path.
 *
 * Register facts (RK3288 TRM Part1, WDT and CRU/GRF chapters):
 *   WDT base 0xff800000, pclk_wdt = pclk_pd_alive (rate not measured; TOP fixed).
 *   CR   0x00: bit0 WDT_EN, bit1 RMOD (0 = system reset), bits4:2 RPL.
 *   TORR 0x04: bits3:0 TOP only (reserved bits 31:4 are RO). Timeout is
 *        (2^(16+TOP) - 1) WDT-clock cycles, TOP in 0..15.
 *   CRR  0x0c: write 0x76 to restart (kick).
 *   CRU 0xff760000, CRU_GLB_RST_CON 0x1f0: bit1 wdt_glb_srst_ctrl
 *        (0 = WDT fires glb_srstn_2, the reset value; 1 = glb_srstn_1).
 *        Bits 31:4 are RO with no write mask: rkwdt_glbrst does read-modify-write.
 *   CRU_GLB_RST_ST 0x1f8 (W1C): bit4 fst_glb_wdt_rst_st, bit5
 *        snd_glb_wdt_rst_st. Logged at arm; cleared at arm when rkwdt_test
 *        or rkwdt_glbrst is set.
 *   Pclk gate: SGRF_SOC_CON0 (0xff740000) bit6 SGRF_PCLK_WDT_GATE, write mask
 *   bit22 (arch/arm/mach-rockchip/pm.h, pm.c; 1 = gated). The clk driver
 *   comment says bit1 (mask bit17). Not settled by the public TRM; tested on
 *   device with rkwdt_sgrf=.
 *
 * Sequence: start_kernel() calls rk3288_timer7_early_init() and time_init(),
 * then rk_wdt_backstop_arm(), so the ARM arch counter is running (timer7 fix)
 * when the WDT is armed. The kick thread starts in early_initcall() (kthreadd
 * exists by then) and kicks with msleep() once per second.
 * Parameters (early_param, parsed before time_init):
 *   rkwdt=0           disable the backstop entirely
 *   rkwdt_top=N       TOP field, 0..15 (default 14: timeout 2^(16+TOP)/pclk_wdt,
 *                     7.2 s at 150 MHz, 45 s at 24 MHz; pclk not measured)
 *   rkwdt_stop=N      kick thread stops kicking after N seconds of uptime, so
 *                     the WDT resets even a live system that has lost USB
 *                     (default 0 = never stop)
 *   rkwdt_test=3      SAFE test: arm, then spin with IRQs off polling CNTVCT.
 *                     The WDT should reset at its TOP timeout. If 60 s pass or CNTVCT
 *                     freezes, fire the loader reset ourselves. Forces the
 *                     loader flag, so every outcome returns to rockusb.
 *                     (rkwdt_test=1 and 2 are removed: no fallback.)
 *   rkdeadline=N      after N s of uptime, a kthread sets verbose console output,
 *                     dumps task and workqueue state, calls rk_logdump_to_kpanic(),
 *                     writes the loader flag and panics. The panic reboots after
 *                     rkdeadline_hold seconds, so the panic output stays on fbcon.
 *                     An hrtimer at N+15 s sets the flag and fires the reset with no
 *                     dump if the kthread has not got there. Independent of the WDT;
 *                     active in every boot where set.
 *   rkdeadline_hold=N seconds the deadline panic waits before rebooting (default 20;
 *                     0 = 5; the WDT is kicked during the hold via panic_blink;
 *                     runtime-tunable under /sys/module/rk_wdt_backstop/parameters/)
 *   rkwdt_glbrst=0|1  write CRU_GLB_RST_CON bit1 (0 = glb_srstn_2, 1 = glb_srstn_1)
 *   rkwdt_sgrf=V      write V verbatim to SGRF_SOC_CON0 (default 0x00400000,
 *                     clears bit6 with mask bit22). 0x00420000 clears bit6 and
 *                     bit1; 0x00020000 clears bit1 only.
 *   rkwdt_loader=1    write PMU_SYS_REG0=0x5242C301 (SYS_LOADER_REBOOT_FLAG |
 *                     BOOT_LOADER) before arming, so a WDT reset re-enters
 *                     rockusb (default 0: no write, normal reboot on reset)
 *   hardhang=1        write-only (root): /sys/module/rk_wdt_backstop/parameters/hardhang.
 *                     Wedges every CPU (IRQs off, spinning, no kthreads), like a real
 *                     hard hang, so only the WDT, if armed, can reset the board.
 */
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/irqflags.h>
#include <linux/hrtimer.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/math64.h>
#include <linux/printk.h>
#include <linux/reboot.h>
#include <linux/rk_wdt_backstop.h>
#include <linux/sched.h>
#include <linux/sched/types.h>
#include <linux/timekeeping.h>
#include <linux/types.h>
#include <linux/wait.h>
#include <linux/rk_logdump.h>
#include <linux/moduleparam.h>
#include <linux/string.h>
#include <linux/console.h>
#include <linux/sched/debug.h>
#include <linux/smp.h>
#include <linux/workqueue.h>
#ifdef CONFIG_DRM_FBDEV_EMULATION
#include <drm/drm_fb_helper.h>
#endif

#define RK3288_WDT_BASE		0xff800000UL
#define RK3288_WDT_SIZE		0x100
#define RK3288_SGRF_BASE	0xff740000UL
#define RK3288_SGRF_SIZE	0x200

#define RK3288_CRU_BASE		0xff760000UL
#define RK3288_CRU_SIZE		0x200
#define CRU_GLB_RST_CON		0x1f0
#define CRU_GLB_RST_ST		0x1f8
#define CRU_GLB_RST_CON_WDT	BIT(1)
#define CRU_GLB_RST_ST_WDT	(BIT(4) | BIT(5))
#define CRU_GLB_SRST_FST	0x1b0
#define CRU_GLB_SRST_FST_MAGIC	0xfdb9	/* first global reset: glb_srstn_1 */

#define WDT_CR			0x00
#define WDT_TORR		0x04
#define WDT_CCVR		0x08
#define WDT_CRR			0x0c
#define WDT_CR_EN		BIT(0)
#define WDT_CR_RPL(x)		(((x) & 0x7) << 2)
#define WDT_CRR_MAGIC		0x76

#define SGRF_SOC_CON0		0x00
#define SGRF_PCLK_WDT_GATE	(1U << 6)
#define SGRF_PCLK_WDT_GATE_WRITE (1U << 22)

#define RK3288_PMU_BASE		0xff730000UL
#define RK3288_PMU_SIZE		0x100
#define PMU_SYS_REG0		0x94
#define RKWDT_LOADER_FLAG	0x5242C301	/* SYS_LOADER_REBOOT_FLAG | BOOT_LOADER */
#define RKWDT_DEFAULT_TOP	14
#define RKWDT_SAFE_SECS		60
#define RKWDT_CNTFRQ_DEFAULT	24000000U	/* DT arch timer: 24 MHz */
#define RKWDT_STALL_MAX		(1U << 26)	/* CNTVCT unchanged this many reads: frozen */
#define RKWDT_HARD_EXTRA_SECS	15	/* hrtimer hard cap: rkdeadline + 15 s */

static bool rkwdt_enabled = true;
static unsigned int rkwdt_test;
static unsigned int rkwdt_top = RKWDT_DEFAULT_TOP;
static bool rkwdt_top_set;
static unsigned int rkwdt_stop;
static bool rkwdt_glbrst_set;
static bool rkwdt_glbrst_val;
static bool rkwdt_sgrf_set;
static u32 rkwdt_sgrf_val;
static bool rkwdt_loader;
static unsigned int rkdeadline;
static unsigned int rkdeadline_hold = 20;
module_param(rkdeadline_hold, uint, 0644);

static void __iomem *wdt_base;
static bool wdt_armed;
static struct task_struct *kick_task;
static void __iomem *rkwdt_pmu_base;
static void __iomem *rkwdt_cru_base;

static int __init rkwdt_param_enable(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v))
		return 0;
	rkwdt_enabled = v != 0;
	return 0;
}
early_param("rkwdt", rkwdt_param_enable);

static int __init rkwdt_param_top(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v) || v > 15)
		return 0;
	rkwdt_top = v;
	rkwdt_top_set = true;
	return 0;
}
early_param("rkwdt_top", rkwdt_param_top);

static int __init rkwdt_param_stop(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v))
		return 0;
	rkwdt_stop = v;
	return 0;
}
early_param("rkwdt_stop", rkwdt_param_stop);

static int __init rkwdt_param_loader(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v) || v > 1)
		return 0;
	rkwdt_loader = v != 0;
	return 0;
}
early_param("rkwdt_loader", rkwdt_param_loader);

static int __init rkwdt_param_deadline(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v) || !v || v > 86400)
		return 0;
	rkdeadline = v;
	return 0;
}
early_param("rkdeadline", rkwdt_param_deadline);

static int __init rkwdt_param_test(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v))
		return 0;
	if (v != 0 && v != 3) {
		pr_emerg("RK_WDT_BACKSTOP: rkwdt_test=%u unsupported (0 or 3), ignored\n", v);
		return 0;
	}
	rkwdt_test = v;
	return 0;
}
early_param("rkwdt_test", rkwdt_param_test);

static int __init rkwdt_param_glbrst(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v) || v > 1)
		return 0;
	rkwdt_glbrst_set = true;
	rkwdt_glbrst_val = v;
	return 0;
}
early_param("rkwdt_glbrst", rkwdt_param_glbrst);

static int __init rkwdt_param_sgrf(char *s)
{
	unsigned int v;

	if (!s || kstrtouint(s, 0, &v))
		return 0;
	rkwdt_sgrf_set = true;
	rkwdt_sgrf_val = v;
	return 0;
}
early_param("rkwdt_sgrf", rkwdt_param_sgrf);

/* Busy-wait without udelay(): loops_per_jiffy is not calibrated this early. */
static u32 rkwdt_ccvr_changes(void)
{
	u32 first = readl(wdt_base + WDT_CCVR);
	u32 i;

	for (i = 0; i < 10000000; i++) {
		if (readl(wdt_base + WDT_CCVR) != first)
			return i + 1;
	}
	return 0;
}

static bool rkwdt_map_loader_regs(void)
{
	if (!rkwdt_pmu_base)
		rkwdt_pmu_base = ioremap(RK3288_PMU_BASE, RK3288_PMU_SIZE);
	if (!rkwdt_cru_base)
		rkwdt_cru_base = ioremap(RK3288_CRU_BASE, RK3288_CRU_SIZE);
	return rkwdt_pmu_base && rkwdt_cru_base;
}

/*
 * Set the rockusb loader flag, then fire the first global reset
 * (CRU_GLB_SRST_FST). Never returns. Needs rkwdt_map_loader_regs().
 * No sleeping call: safe with IRQs off and from hrtimer context.
 */
static void __noreturn rkwdt_reset_loader(void)
{
	writel(RKWDT_LOADER_FLAG, rkwdt_pmu_base + PMU_SYS_REG0);
	wmb();
	writel(CRU_GLB_SRST_FST_MAGIC, rkwdt_cru_base + CRU_GLB_SRST_FST);
	wmb();
	while (1)
		cpu_relax();
}

static int rkwdt_restart_notify(struct notifier_block *nb, unsigned long mode, void *cmd)
{
	if (!cmd || (strcmp(cmd, "loader") && strcmp(cmd, "bootloader")))
		return NOTIFY_DONE;
	if (!rkwdt_map_loader_regs())
		return NOTIFY_DONE;
	rkwdt_reset_loader();
}

static struct notifier_block rkwdt_restart_nb = {
	.notifier_call = rkwdt_restart_notify,
	.priority = 192,
};

static u64 rkwdt_cntvct(void)
{
	u32 lo, hi;

	asm volatile("mrrc p15, 1, %0, %1, c14" : "=r" (lo), "=r" (hi));
	return ((u64)hi << 32) | lo;
}

/*
 * rkwdt_test=3: IRQs off, poll CNTVCT. The WDT should reset within its
 * 8-16 s timeout. If it does not, or the counter freezes, fire the loader
 * reset after RKWDT_SAFE_SECS so the board returns to rockusb.
 */
static void __noreturn rkwdt_safe_spin(void)
{
	u32 cntfrq, stall = 0;
	u64 ticks, t0, last, now;
	bool frozen = false;

	asm volatile("mrc p15, 0, %0, c14, c0, 0" : "=r" (cntfrq));
	if (cntfrq < 1000000U || cntfrq > 100000000U)
		cntfrq = RKWDT_CNTFRQ_DEFAULT;
	ticks = (u64)cntfrq * RKWDT_SAFE_SECS;
	pr_emerg("RK_WDT_BACKSTOP test=3: CNTFRQ=%u, IRQs off, WDT expected to reset first; fallback after %us\n",
		 cntfrq, RKWDT_SAFE_SECS);

	local_irq_disable();
	t0 = last = rkwdt_cntvct();
	while (1) {
		now = rkwdt_cntvct();
		if (now - t0 >= ticks)
			break;
		if (now != last) {
			last = now;
			stall = 0;
		} else if (++stall > RKWDT_STALL_MAX) {
			frozen = true;
			break;
		}
		cpu_relax();
	}
	pr_emerg("RK_WDT_BACKSTOP test=3: %s, no WDT reset\n",
		 frozen ? "CNTVCT frozen" : "60 s elapsed");
	rkwdt_reset_loader();
}

static void __init rkwdt_cru_setup(void)
{
	void __iomem *cru;
	u32 before, after;

	cru = ioremap(RK3288_CRU_BASE, RK3288_CRU_SIZE);
	if (!cru) {
		pr_emerg("RK_WDT_BACKSTOP: CRU ioremap failed\n");
		return;
	}

	before = readl(cru + CRU_GLB_RST_CON);
	pr_emerg("RK_WDT_BACKSTOP: CRU_GLB_RST_CON=0x%08x CRU_GLB_RST_ST=0x%08x (before)\n",
		 before, readl(cru + CRU_GLB_RST_ST));

	/* Clear the WDT reset-cause flags so the next boot shows only this run. */
	if (rkwdt_test || rkwdt_glbrst_set) {
		writel(CRU_GLB_RST_ST_WDT, cru + CRU_GLB_RST_ST);
		wmb();
	}

	/* No write mask on this register: read-modify-write bit1 only. */
	if (rkwdt_glbrst_set) {
		writel((before & ~CRU_GLB_RST_CON_WDT) |
		       (rkwdt_glbrst_val ? CRU_GLB_RST_CON_WDT : 0),
		       cru + CRU_GLB_RST_CON);
		wmb();
	}

	after = readl(cru + CRU_GLB_RST_CON);
	pr_emerg("RK_WDT_BACKSTOP: CRU_GLB_RST_CON=0x%08x (wdt_glb_srst_ctrl=%d) CRU_GLB_RST_ST=0x%08x (after)\n",
		 after, !!(after & CRU_GLB_RST_CON_WDT), readl(cru + CRU_GLB_RST_ST));
	iounmap(cru);
}

void __init rk_wdt_backstop_arm(void)
{
	void __iomem *sgrf;
	u32 sgrf_val, con0, moved;

	if (!rkwdt_enabled) {
		pr_emerg("RK_WDT_BACKSTOP: disabled (rkwdt=0)\n");
		return;
	}

	wdt_base = ioremap(RK3288_WDT_BASE, RK3288_WDT_SIZE);
	sgrf = ioremap(RK3288_SGRF_BASE, RK3288_SGRF_SIZE);
	if (!wdt_base || !sgrf) {
		pr_emerg("RK_WDT_BACKSTOP: ioremap failed\n");
		return;
	}

	rkwdt_cru_setup();

	/* Open the pclk_wdt gate first: APB access to a gated block hangs. */
	sgrf_val = rkwdt_sgrf_set ? rkwdt_sgrf_val : SGRF_PCLK_WDT_GATE_WRITE;
	writel(sgrf_val, sgrf + SGRF_SOC_CON0);
	wmb();
	con0 = readl(sgrf + SGRF_SOC_CON0);
	pr_emerg("RK_WDT_BACKSTOP: SGRF_SOC_CON0 wrote 0x%08x read 0x%08x bit6=%d bit1=%d\n",
		 sgrf_val, con0, !!(con0 & SGRF_PCLK_WDT_GATE), !!(con0 & BIT(1)));
	iounmap(sgrf);

	/* Gate still set: an APB access to WDT would hang. Leave WDT alone. */
	if (con0 & (SGRF_PCLK_WDT_GATE | BIT(1))) {
		pr_emerg("RK_WDT_BACKSTOP: SGRF gate still set (con0=0x%08x), WDT not touched\n",
			 con0);
		if (rkwdt_test == 3) {
			if (rkwdt_map_loader_regs())
				rkwdt_reset_loader();
			pr_emerg("RK_WDT_BACKSTOP: test=3 loader regs unmapped, no reset\n");
		}
		return;
	}

	/* Loader flag: a WDT reset then re-enters rockusb. test=3 always sets it. */
	if (rkwdt_loader || rkwdt_test == 3) {
		if (!rkwdt_map_loader_regs()) {
			pr_emerg("RK_WDT_BACKSTOP: PMU/CRU ioremap failed, no loader flag\n");
		} else {
			writel(RKWDT_LOADER_FLAG, rkwdt_pmu_base + PMU_SYS_REG0);
			wmb();
			pr_emerg("RK_WDT_BACKSTOP: loader flag PMU_SYS_REG0 wrote 0x%08x read 0x%08x\n",
				 RKWDT_LOADER_FLAG, readl(rkwdt_pmu_base + PMU_SYS_REG0));
		}
	}

	writel(rkwdt_top & 0xf, wdt_base + WDT_TORR);
	writel(WDT_CRR_MAGIC, wdt_base + WDT_CRR);
	/* RMOD=0: direct system reset on timeout. RPL=2 (default). */
	writel(WDT_CR_EN | WDT_CR_RPL(2), wdt_base + WDT_CR);
	wmb();

	moved = rkwdt_ccvr_changes();
	wdt_armed = true;

	pr_emerg("RK_WDT_BACKSTOP: armed CR=0x%x TORR=0x%x ccvr_counts_after=%u stop_after=%us\n",
		 readl(wdt_base + WDT_CR), readl(wdt_base + WDT_TORR), moved, rkwdt_stop);
	pr_emerg("RK_WDT_BACKSTOP: TOP=%u (%s), timeout 2^%u / pclk_wdt cycles (pclk not measured)\n",
		 rkwdt_top, rkwdt_top_set ? "param" : "default", 16 + rkwdt_top);
	if (!moved)
		pr_emerg("RK_WDT_BACKSTOP: WARNING counter did not decrement (pclk still gated?)\n");

	if (rkwdt_test == 3) {
		if (!rkwdt_pmu_base || !rkwdt_cru_base) {
			pr_emerg("RK_WDT_BACKSTOP: test=3 NOT spinning: loader regs unmapped\n");
			return;
		}
		rkwdt_safe_spin();
	}
}

static int rkwdt_kick_fn(void *unused)
{
	while (!kthread_should_stop()) {
		if (rkwdt_stop && ktime_get_seconds() >= rkwdt_stop) {
			pr_emerg("RK_WDT_BACKSTOP: uptime %llds >= rkwdt_stop=%u, no more kicks\n",
				 (long long)ktime_get_seconds(), rkwdt_stop);
			return 0;
		}
		writel(WDT_CRR_MAGIC, wdt_base + WDT_CRR);
		msleep(1000);
	}
	return 0;
}

static struct hrtimer rkwdt_hard_timer;

static enum hrtimer_restart rkwdt_hard_fn(struct hrtimer *t)
{
	rkwdt_reset_loader();
}

static unsigned int rkwdt_hold_secs(void)
{
	return rkdeadline_hold ? rkdeadline_hold : 5;
}

/* panic_blink: called every ~200 ms by the panic countdown; keeps the WDT from cutting the hold. */
static long rkwdt_panic_blink(int state)
{
	if (wdt_armed)
		writel(WDT_CRR_MAGIC, wdt_base + WDT_CRR);
	return 0;
}

static void rkwdt_extend_hard_cap(unsigned int secs)
{
	hrtimer_start(&rkwdt_hard_timer, ns_to_ktime((u64)secs * NSEC_PER_SEC), HRTIMER_MODE_REL);
	pr_emerg("RK_WDT_BACKSTOP: hard cap extended to +%us from now\n", secs);
}

static int rkwdt_reset_loader_set(const char *val, const struct kernel_param *kp)
{
	int v, ret = kstrtoint(val, 0, &v);

	if (ret)
		return ret;
	if (v != 1)
		return -EINVAL;
	if (!rkwdt_map_loader_regs())
		return -ENODEV;
	pr_emerg("RK_WDT_BACKSTOP: reset_loader requested, rebooting to loader\n");
	rkwdt_reset_loader();
}

static const struct kernel_param_ops rkwdt_reset_loader_ops = {
	.set = rkwdt_reset_loader_set,
};
module_param_cb(reset_loader, &rkwdt_reset_loader_ops, NULL, 0200);

static void rkwdt_hardhang_ipi(void *unused)
{
	local_irq_disable();
	while (1)
		cpu_relax();
}

static int rkwdt_hardhang_set(const char *val, const struct kernel_param *kp)
{
	int v, ret = kstrtoint(val, 0, &v);

	if (ret)
		return ret;
	if (v != 1)
		return -EINVAL;
	pr_emerg("RK_WDT_BACKSTOP: hardhang requested, wedging all CPUs (IRQs off, no kthreads)\n");
	smp_call_function(rkwdt_hardhang_ipi, NULL, 0);
	local_irq_disable();
	while (1)
		cpu_relax();
}

static const struct kernel_param_ops rkwdt_hardhang_ops = {
	.set = rkwdt_hardhang_set,
};
module_param_cb(hardhang, &rkwdt_hardhang_ops, NULL, 0200);

/*
 * Hard cap for rkdeadline: an hrtimer at N + RKWDT_HARD_EXTRA_SECS sets the
 * loader flag and fires the CRU reset from hard-IRQ context. No sleeping call,
 * so a stuck LogDump write cannot block the reset.
 */
static void __init rkwdt_arm_hard_cap(void)
{
	s64 remain = (s64)(rkdeadline + RKWDT_HARD_EXTRA_SECS) * NSEC_PER_SEC
		     - (s64)ktime_to_ns(ktime_get_boottime());

	hrtimer_init(&rkwdt_hard_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);
	rkwdt_hard_timer.function = rkwdt_hard_fn;
	hrtimer_start(&rkwdt_hard_timer, ns_to_ktime((u64)(remain > 0 ? remain : 1)),
		      HRTIMER_MODE_REL);
	pr_emerg("RK_WDT_BACKSTOP: hard cap armed (rkdeadline+%ds, no dump, %lld ns left)\n",
		 RKWDT_HARD_EXTRA_SECS, (long long)remain);
}

static int rkwdt_deadline_fn(void *unused)
{
	u64 at_ns = (u64)rkdeadline * NSEC_PER_SEC;

	while (ktime_to_ns(ktime_get_boottime()) < at_ns)
		msleep(20);
	console_verbose();
	pr_emerg("RK_WDT_BACKSTOP: rkdeadline=%us reached at uptime %llus, dumping state\n",
		 rkdeadline, (unsigned long long)div_u64(ktime_to_ns(ktime_get_boottime()), NSEC_PER_SEC));
	rkwdt_extend_hard_cap(rkwdt_hold_secs() + RKWDT_HARD_EXTRA_SECS);
#ifdef CONFIG_DRM_FBDEV_EMULATION
	pr_emerg("RK_WDT_BACKSTOP: fbcon restore %s\n",
		 drm_fb_helper_force_kernel_mode() ? "ok" : "FAILED");
#endif
	show_state_filter(TASK_UNINTERRUPTIBLE);
	show_workqueue_state();
	rk_logdump_to_kpanic("rkdeadline");
	pr_emerg("RK_WDT_BACKSTOP: dump returned, panicking (loader flag set, reboot after %us)\n",
		 rkwdt_hold_secs());
	writel(RKWDT_LOADER_FLAG, rkwdt_pmu_base + PMU_SYS_REG0);
	wmb();
	panic_timeout = rkwdt_hold_secs();
	panic_blink = rkwdt_panic_blink;
	panic("rkdeadline=%u", rkdeadline);
}

static int __init rk_wdt_backstop_kick_init(void)
{
	struct sched_param param = { .sched_priority = 1 };
	struct sched_param dl_param = { .sched_priority = 2 };
	struct task_struct *dl_task;

	register_restart_handler(&rkwdt_restart_nb);

	if (rkdeadline) {
		if (!rkwdt_map_loader_regs()) {
			pr_emerg("RK_WDT_BACKSTOP: rkdeadline=%us NOT armed: PMU/CRU ioremap failed\n",
				 rkdeadline);
		} else {
			rkwdt_arm_hard_cap();
			dl_task = kthread_run(rkwdt_deadline_fn, NULL, "rk-deadline");
			if (IS_ERR(dl_task)) {
				pr_emerg("RK_WDT_BACKSTOP: rkdeadline kthread_run failed: %ld\n",
					 PTR_ERR(dl_task));
			} else {
				sched_setscheduler_nocheck(dl_task, SCHED_FIFO, &dl_param);
				pr_emerg("RK_WDT_BACKSTOP: rkdeadline=%us armed (loader flag + CRU_GLB_SRST_FST)\n",
					 rkdeadline);
			}
		}
	}

	if (!wdt_armed)
		return 0;

	kick_task = kthread_create(rkwdt_kick_fn, NULL, "rk-wdt-kick");
	if (IS_ERR(kick_task)) {
		pr_emerg("RK_WDT_BACKSTOP: kthread_create failed: %ld\n",
			 PTR_ERR(kick_task));
		kick_task = NULL;
		return 0;
	}
	sched_setscheduler_nocheck(kick_task, SCHED_FIFO, &param);
	wake_up_process(kick_task);
	pr_emerg("RK_WDT_BACKSTOP: kick thread started (1 s period, SCHED_FIFO, stop_after=%us)\n",
		 rkwdt_stop);
	return 0;
}
early_initcall(rk_wdt_backstop_kick_init);
