// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Device Tree support for Rockchip SoCs
 *
 * Copyright (c) 2013 MundoReader S.L.
 * Author: Heiko Stuebner <heiko@sntech.de>
 */

#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/of_clk.h>
#include <linux/of_platform.h>
#include <linux/irqchip.h>
#include <linux/clocksource.h>
#include <linux/mfd/syscon.h>
#include <linux/regmap.h>
#include <asm/mach/arch.h>
#include <asm/mach/map.h>
#include <asm/hardware/cache-l2x0.h>
#include "core.h"
#include "pm.h"
#include <linux/rk_probe.h>

#ifdef CONFIG_RK_PROBE_POINTS
/*
 * Bring-up probes: devicemaps_init() clears the fixmap, so from there until
 * ioremap() works the probes use these static PMU/CRU mappings.
 */
static struct map_desc rk3288_probe_io_desc[] __initdata = {
	{
		.virtual = RK_PROBE_PMU_VIRT,
		.pfn = __phys_to_pfn(0xff730000),
		.length = SZ_4K,
		.type = MT_DEVICE,
	}, {
		.virtual = RK_PROBE_CRU_VIRT,
		.pfn = __phys_to_pfn(0xff760000),
		.length = SZ_4K,
		.type = MT_DEVICE,
	},
};

static void __init rockchip_map_io(void)
{
	iotable_init(rk3288_probe_io_desc, ARRAY_SIZE(rk3288_probe_io_desc));
	rk_probe_static_mapped = true;
	rk_probe_early(70);
	debug_ll_io_init();
}
#endif

#define RK3288_TIMER6_7_PHYS 0xff810000

static void __init rockchip_timer_init(void)
{
	if (of_machine_is_compatible("rockchip,rk3288")) {
		void __iomem *reg_base;

		/*
		 * Most/all uboot versions for rk3288 don't enable timer7
		 * which is needed for the architected timer to work.
		 * So make sure it is running during early boot.
		 */
		reg_base = ioremap(RK3288_TIMER6_7_PHYS, SZ_16K);
		if (reg_base) {
			writel(0, reg_base + 0x30);
			writel(0xffffffff, reg_base + 0x20);
			writel(0xffffffff, reg_base + 0x24);
			writel(1, reg_base + 0x30);
			dsb();
			iounmap(reg_base);
		} else {
			pr_err("rockchip: could not map timer7 registers\n");
		}
	}

	of_clk_init(NULL);
	timer_probe();
}

static void __init rockchip_dt_init(void)
{
	rockchip_suspend_init();
}

static const char * const rockchip_board_dt_compat[] = {
	"rockchip,rk2928",
	"rockchip,rk3066a",
	"rockchip,rk3066b",
	"rockchip,rk3188",
	"rockchip,rk3228",
	"rockchip,rk3288",
	"rockchip,rv1103",
	"rockchip,rv1106",
	"rockchip,rv1108",
	NULL,
};

DT_MACHINE_START(ROCKCHIP_DT, "Rockchip (Device Tree)")
	.l2c_aux_val	= 0,
	.l2c_aux_mask	= ~0,
#ifdef CONFIG_RK_PROBE_POINTS
	.map_io		= rockchip_map_io,
#endif
	.init_time	= rockchip_timer_init,
	.dt_compat	= rockchip_board_dt_compat,
	.init_machine	= rockchip_dt_init,
MACHINE_END
