/*
 * Copyright (C) 2014 Google, Inc.
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <linux/clk.h>
#include <linux/completion.h>
#include <linux/cpu.h>
#include <linux/cpufreq.h>
#include <linux/delay.h>
#include <linux/devfreq.h>
#include <linux/devfreq_cooling.h>
#include <linux/io.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/pm_opp.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>
#include <linux/rwsem.h>
#include <linux/suspend.h>
#include <linux/syscore_ops.h>
#include <linux/workqueue.h>

#include <soc/rockchip/dmc-sync.h>

#define RK3288_DMC_NUM_CH	2

#define GRF_SOC_CON4		0x0254
#define GRF_SOC_STATUS11	0x02ac
#define GRF_SOC_STATUS12	0x02b0
#define GRF_SOC_STATUS13	0x02b4
#define GRF_SOC_STATUS14	0x02b8

#define PMU_SYS_REG2		0x009c

#define SVC_BUS_DDRCONF		0x0008
#define SVC_BUS_DDRTIMING	0x000c

#define DDR_SEL_DDR3		0x20000000
#define DDR_SEL_MOBILEDDR	0x20002000

#define DMC_NUM_RETRIES		3

#define DMC_MIN_CPU_KHZ		1200000

struct dmc_usage {
	u32 write;
	u32 read;
	u32 active;
	u32 time;
};

extern int rk3288_dmcclk_set_rate(unsigned long rate);
extern unsigned long rk3288_dmcclk_get_rate(void);

struct rk3288_dmcfreq {
	struct device *clk_dev;
	struct work_struct work;
	struct devfreq *devfreq;
	struct regulator *vdd_logic;
	struct dmc_usage ch_usage[RK3288_DMC_NUM_CH];

	struct regmap *grf;
	struct regmap *pmu;
	struct regmap *svc_bus;

	unsigned long rate, target_rate;
	unsigned long volt, target_volt;
	int err;

	/* DDR rate and vdd_logic voltage the bootloader left behind */
	unsigned long boot_rate;
	unsigned long boot_volt;

	/*
	 * Set while dmc-sync reports DMC_DISABLE (more than one display to
	 * synchronise with, or system suspend). Rate changes are refused then.
	 */
	bool sync_disabled;

	struct mutex cpufreq_mutex;
	struct thermal_cooling_device *cdev;
};

/*
 * We can only have one since devfreq has to be added for the parent device (the
 * clk device) which has the operating points defined. We assume only one or
 * zero devices will be probed for this driver.
 */
static struct rk3288_dmcfreq dmcfreq;

static int rk3288_dmcfreq_target(struct device *dev, unsigned long *freq,
				 u32 flags)
{
	struct dev_pm_opp *opp;

	opp = devfreq_recommended_opp(dev, freq, flags);
	if (IS_ERR(opp))
		return PTR_ERR(opp);

	dmcfreq.target_rate = dev_pm_opp_get_freq(opp);
	dmcfreq.target_volt = dev_pm_opp_get_voltage(opp);
	dev_pm_opp_put(opp);

	/*
	 * vdd_logic is shared with the rest of the logic domain, which runs on
	 * the voltage the bootloader picked. Never go below it, and restore it
	 * exactly when going back to the boot rate.
	 */
	if (dmcfreq.target_rate == dmcfreq.boot_rate)
		dmcfreq.target_volt = dmcfreq.boot_volt;
	else
		dmcfreq.target_volt = max(dmcfreq.target_volt,
					  dmcfreq.boot_volt);

	if (dmcfreq.rate == dmcfreq.target_rate) {
		*freq = dmcfreq.rate;
		return 0;
	}

	if (READ_ONCE(dmcfreq.sync_disabled)) {
		dev_warn(dev, "DDR rate change refused: dmc-sync disabled\n");
		*freq = dmcfreq.rate;
		return -EBUSY;
	}

	queue_work(system_highpri_wq, &dmcfreq.work);
	flush_work(&dmcfreq.work);
	*freq = dmcfreq.rate;

	return dmcfreq.err;
}

static void rk3288_dmc_start_hardware_counter(void)
{
	int i;

	for (i = 1; i < 4; i++) {
		regmap_write(dmcfreq.svc_bus, 0x400*i+SVC_BUS_DDRCONF, 0x08);
		regmap_write(dmcfreq.svc_bus, 0x400*i+SVC_BUS_DDRTIMING, 0x01);
		/* TODO: What are these registers? */
		regmap_write(dmcfreq.svc_bus, 0x400*i+0x138, 0x06);
		regmap_write(dmcfreq.svc_bus, 0x400*i+0x14c, 0x10);
		regmap_write(dmcfreq.svc_bus, 0x400*i+0x160, 0x08);
		regmap_write(dmcfreq.svc_bus, 0x400*i+0x174, 0x10);
	}

	/* Enables hardware usage counters */
	regmap_write(dmcfreq.grf, GRF_SOC_CON4, 0xc000c000);
	/* TODO: What is this register? */
	for (i = 1; i < 4; i++)
		regmap_write(dmcfreq.svc_bus, 0x400*i+0x28, 0x1);
}

static void rk3288_dmc_stop_hardware_counter(void)
{
	/* Disables hardware usage counters */
	regmap_write(dmcfreq.grf, GRF_SOC_CON4, 0xc0000000);
}

static int rk3288_dmc_get_busier_ch(void)
{
	u64 tmp, max = 0;
	int i, busier_ch = 0;

	rk3288_dmc_stop_hardware_counter();
	/* Find out which channel is busier */
	for (i = 0; i < RK3288_DMC_NUM_CH; i++) {
		regmap_read(dmcfreq.grf, GRF_SOC_STATUS11+i*16,
			    &dmcfreq.ch_usage[i].write);
		regmap_read(dmcfreq.grf, GRF_SOC_STATUS12+i*16,
			    &dmcfreq.ch_usage[i].read);
		regmap_read(dmcfreq.grf, GRF_SOC_STATUS13+i*16,
			    &dmcfreq.ch_usage[i].active);
		regmap_read(dmcfreq.grf, GRF_SOC_STATUS14+i*16,
			    &dmcfreq.ch_usage[i].time);
		tmp = (u64)dmcfreq.ch_usage[i].write + dmcfreq.ch_usage[i].read;
		if (tmp > max) {
			busier_ch = i;
			max = tmp;
		}
	}
	rk3288_dmc_start_hardware_counter();

	return busier_ch;
}

static int rk3288_dmcfreq_get_dev_status(struct device *dev,
					 struct devfreq_dev_status *stat)
{
	int busier_ch;

	busier_ch = rk3288_dmc_get_busier_ch();
	stat->current_frequency = dmcfreq.rate;
	stat->busy_time = (dmcfreq.ch_usage[busier_ch].write +
		dmcfreq.ch_usage[busier_ch].read) * 4;
	stat->total_time = dmcfreq.ch_usage[busier_ch].time;

	return 0;
}

static int rk3288_dmcfreq_get_cur_freq(struct device *dev, unsigned long *freq)
{
	*freq = dmcfreq.rate;
	return 0;
}

static void rk3288_dmcfreq_exit(struct device *dev)
{
	devfreq_unregister_opp_notifier(dmcfreq.clk_dev, dmcfreq.devfreq);
}

static struct devfreq_dev_profile rk3288_devfreq_dmc_profile = {
	.polling_ms	= 100,
	.target		= rk3288_dmcfreq_target,
	.get_dev_status	= rk3288_dmcfreq_get_dev_status,
	.get_cur_freq	= rk3288_dmcfreq_get_cur_freq,
	.exit		= rk3288_dmcfreq_exit,
};

static int rk3288_dmcfreq_set_voltage(unsigned long uV)
{
	int ret;

	ret = regulator_set_voltage(dmcfreq.vdd_logic, uV, uV);
	if (!ret)
		dmcfreq.volt = uV;

	return ret;
}

static int rk3288_dmcfreq_cpufreq_notifier(struct notifier_block *nb,
					   unsigned long event, void *data)
{
	struct cpufreq_policy *policy = data;

	if (event != CPUFREQ_ADJUST)
		return NOTIFY_DONE;

	/* If we get the mutex we're not mid-transition; nothing to do */
	if (mutex_trylock(&dmcfreq.cpufreq_mutex)) {
		mutex_unlock(&dmcfreq.cpufreq_mutex);
		return NOTIFY_DONE;
	}

	/*
	 * Try to go to max freq if we're in a transition.  NOTE: when we
	 * registered our notifier we passed a negative priority which means
	 * we're lower than what cpu_cooling does (it leaves the default
	 * priority of 0).  That means we run _after_ it and we end up being
	 * able to override its throttling (we'll run _above_ the thermal
	 * limits).  This should be OK because we'll quickly scale back down
	 * and the thermal framework will compensate.
	 */
	cpufreq_verify_within_limits(policy, policy->cpuinfo.max_freq,
				     policy->cpuinfo.max_freq);

	return NOTIFY_OK;
}

static struct notifier_block rk3288_dmcfreq_cpufreq_notifier_block = {
	.notifier_call = rk3288_dmcfreq_cpufreq_notifier,
	.priority = -100,
};

static void rk3288_dmcfreq_work(struct work_struct *work)
{
	struct device *dev = dmcfreq.clk_dev;
	unsigned long prev_rate = dmcfreq.rate;
	unsigned long target_rate = dmcfreq.target_rate;
	unsigned long volt = dmcfreq.volt;
	unsigned long target_volt = dmcfreq.target_volt;
	unsigned int cpufreq_cur;
	int i;
	int err = 0;

	/*
	 * We need to prevent cpu hotplug from happening while a dmc freq rate
	 * change is happening. The rate change needs to synchronize all of the
	 * cpus. This has to be done here since the lock for preventing cpu
	 * hotplug needs to be grabbed before the clk prepare lock.
	 *
	 * Do this before taking the policy rwsem to avoid deadlocks between the
	 * mutex that is locked/unlocked in both get/put_online_cpus.
	 */
	get_online_cpus();

	/* Go to max cpufreq since set_rate needs to complete during vblank. */
	mutex_lock(&dmcfreq.cpufreq_mutex);
	cpufreq_update_policy(0);

	/*
	 * We expect our cpufreq notifier to be called last (because we mark
	 * it as _low_ priority.  Thus we get to override everyone else.
	 * ...but if we detect someone sneaks in and snipes us then bail.
	 *
	 * NOTE: we really don't expect this so it's just a paranoid check
	 * really.  ...an, in fact, it's also not a perfect check.  It's only
	 * checking the instantaneous CPU frequency and if they have the ability
	 * to override us then could always do it later, so really if the
	 * warning below is showing up we need to figure out what to do.
	 */
	cpufreq_cur = cpufreq_quick_get(0);
	if (cpufreq_cur < DMC_MIN_CPU_KHZ) {
		dev_warn(dev, "CPU too slow for DMC (%u kHz)\n", cpufreq_cur);
		err = -EBUSY;
		goto out;
	}

	if (target_rate > prev_rate) {
		err = rk3288_dmcfreq_set_voltage(target_volt);
		if (err) {
			dev_err(dev, "Unable to set voltage %lu\n", target_volt);
			goto out;
		}
	}

	for (i = 0; i < DMC_NUM_RETRIES; i++) {
		err = rk3288_dmcclk_set_rate(target_rate);
		if (!err || err != -ETIMEDOUT)
			break;
	}

	if (err) {
		dev_err(dev,
			"Unable to set freq %lu. Current freq %lu. Error %d\n",
			target_rate, dmcfreq.rate, err);
		rk3288_dmcfreq_set_voltage(volt);
		goto out;
	}

	dmcfreq.rate = target_rate;

	if (target_rate < prev_rate) {
		err = rk3288_dmcfreq_set_voltage(target_volt);
		if (err)
			dev_err(dev, "Unable to set voltage %lu\n", target_volt);
	}

out:
	mutex_unlock(&dmcfreq.cpufreq_mutex);
	cpufreq_update_policy(0);

	put_online_cpus();
	dmcfreq.err = err;
}

static void rk3288_dmc_register_cooling_dev(void)
{
	if (of_find_property(dmcfreq.clk_dev->of_node, "#cooling-cells",
			     NULL)) {
		dmcfreq.cdev = of_devfreq_cooling_register(dmcfreq.clk_dev->of_node,
							   dmcfreq.devfreq);
		if (IS_ERR(dmcfreq.cdev)) {
			pr_err("dmc w/out cooling device: %ld\n",
			       PTR_ERR(dmcfreq.cdev));
			dmcfreq.cdev = NULL;
		}
	}
}

/*
 * dmc-sync sends DMC_DISABLE when a rate change can no longer be synchronised
 * to a single display (more than one VOP scanning out) and on system suspend,
 * and DMC_ENABLE when that is over. ChromeOS forces the maximum rate on
 * DMC_DISABLE; this port keeps whatever rate is current and refuses rate
 * changes until DMC_ENABLE, so the DDR rate only ever changes on request.
 */
static int rk3288_dmc_enable_notify(struct notifier_block *nb,
				    unsigned long action, void *data)
{
	if (action == DMC_ENABLE) {
		dev_info(dmcfreq.clk_dev, "resuming DVFS\n");
		WRITE_ONCE(dmcfreq.sync_disabled, false);
		rk3288_dmc_start_hardware_counter();
		devfreq_resume_device(dmcfreq.devfreq);
		rk3288_dmc_register_cooling_dev();

		return NOTIFY_OK;
	} else if (action == DMC_DISABLE) {
		dev_info(dmcfreq.clk_dev, "suspending DVFS at %lu Hz\n",
			 dmcfreq.rate);
		WRITE_ONCE(dmcfreq.sync_disabled, true);

		if (dmcfreq.cdev) {
			devfreq_cooling_unregister(dmcfreq.cdev);
			dmcfreq.cdev = NULL;
		}

		devfreq_suspend_device(dmcfreq.devfreq);
		rk3288_dmc_stop_hardware_counter();
		return NOTIFY_OK;
	}

	return NOTIFY_BAD;
}

static struct notifier_block dmc_enable_nb = {
	.notifier_call = rk3288_dmc_enable_notify,
};

static __maybe_unused int rk3288_dmcfreq_suspend(struct device *dev)
{
	rockchip_dmc_disable();

	return 0;
}

static __maybe_unused int rk3288_dmcfreq_resume(struct device *dev)
{
	rockchip_dmc_enable();

	return 0;
}

static SIMPLE_DEV_PM_OPS(rk3288_dmcfreq_pm, rk3288_dmcfreq_suspend,
			 rk3288_dmcfreq_resume);

static void rk3288_dmcfreq_shutdown(void)
{
	devfreq_suspend_device(dmcfreq.devfreq);
}

static struct syscore_ops rk3288_dmcfreq_syscore_ops = {
	.shutdown = rk3288_dmcfreq_shutdown,
};

static int rk3288_dmcfreq_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np;
	int volt;
	int ret;
	u32 tmp;

	mutex_init(&dmcfreq.cpufreq_mutex);
	dmcfreq.clk_dev = dev->parent;
	np = dmcfreq.clk_dev->of_node;
	dmcfreq.grf = syscon_regmap_lookup_by_phandle(np, "rockchip,grf");
	if (IS_ERR(dmcfreq.grf))
		return PTR_ERR(dmcfreq.grf);
	dmcfreq.pmu = syscon_regmap_lookup_by_phandle(np, "rockchip,pmu");
	if (IS_ERR(dmcfreq.pmu))
		return PTR_ERR(dmcfreq.pmu);
	dmcfreq.svc_bus = syscon_regmap_lookup_by_phandle(np,
						"rockchip,service_bus");
	if (IS_ERR(dmcfreq.svc_bus))
		return PTR_ERR(dmcfreq.svc_bus);

	dmcfreq.boot_rate = rk3288_dmcclk_get_rate();
	if (!dmcfreq.boot_rate)
		return -ENODEV;
	dmcfreq.rate = dmcfreq.boot_rate;

	dmcfreq.vdd_logic = regulator_get(dmcfreq.clk_dev, "logic");
	if (IS_ERR(dmcfreq.vdd_logic)) {
		dev_err(dev, "Cannot get the regulator \"vdd_logic\"\n");
		return PTR_ERR(dmcfreq.vdd_logic);
	}

	volt = regulator_get_voltage(dmcfreq.vdd_logic);
	if (volt <= 0) {
		dev_err(dev, "Cannot read vdd_logic voltage: %d\n", volt);
		ret = volt ? volt : -EINVAL;
		goto err_regulator;
	}
	dmcfreq.boot_volt = volt;
	dmcfreq.volt = volt;

	/*
	 * We add a devfreq driver to our parent since it has a device tree node
	 * with operating points.
	 */
	if (dev_pm_opp_of_add_table(dmcfreq.clk_dev)) {
		dev_err(dev, "Invalid operating-points in device tree.\n");
		ret = -EINVAL;
		goto err_regulator;
	}

	/* Check if we are using LPDDR */
	regmap_read(dmcfreq.pmu, PMU_SYS_REG2, &tmp);
	tmp = (tmp >> 13) & 7;
	regmap_write(dmcfreq.grf, GRF_SOC_CON4,
		     (tmp == 3) ? DDR_SEL_DDR3 : DDR_SEL_MOBILEDDR);
	rk3288_dmc_start_hardware_counter();

	rk3288_devfreq_dmc_profile.initial_freq = dmcfreq.rate;

	INIT_WORK(&dmcfreq.work, rk3288_dmcfreq_work);
	/*
	 * The "userspace" governor never picks a rate by itself: until
	 * userspace writes set_freq it keeps devfreq->previous_freq, which is
	 * the boot rate, so no DDR rate change can happen during boot.
	 */
	dmcfreq.devfreq = devfreq_add_device(dmcfreq.clk_dev,
					     &rk3288_devfreq_dmc_profile,
					     "userspace", NULL);
	if (IS_ERR(dmcfreq.devfreq)) {
		ret = PTR_ERR(dmcfreq.devfreq);
		goto err_opp;
	}

	devfreq_register_opp_notifier(dmcfreq.clk_dev, dmcfreq.devfreq);
	rockchip_dmc_en_lock();
	if (!rockchip_dmc_enabled()) {
		dmcfreq.sync_disabled = true;
		devfreq_suspend_device(dmcfreq.devfreq);
		rk3288_dmc_stop_hardware_counter();
		dev_info(dev, "DVFS disabled at probe\n");
	}
	rockchip_dmc_register_enable_notifier(&dmc_enable_nb);
	rockchip_dmc_en_unlock();

	register_syscore_ops(&rk3288_dmcfreq_syscore_ops);

	rk3288_dmc_register_cooling_dev();

	cpufreq_register_notifier(&rk3288_dmcfreq_cpufreq_notifier_block,
				  CPUFREQ_POLICY_NOTIFIER);

	dev_info(dev, "DDR %lu Hz, vdd_logic %lu uV, governor userspace\n",
		 dmcfreq.rate, dmcfreq.boot_volt);

	return 0;

err_opp:
	dev_pm_opp_of_remove_table(dmcfreq.clk_dev);
err_regulator:
	regulator_put(dmcfreq.vdd_logic);
	return ret;
}

static struct platform_driver rk3288_dmcfreq_driver = {
	.probe	= rk3288_dmcfreq_probe,
	.driver = {
		.name	= "rk3288-dmc-freq",
		.pm	= &rk3288_dmcfreq_pm,
		/* dmc-sync and cpufreq notifiers stay registered */
		.suppress_bind_attrs = true,
	},
};
/*
 * Registered once, never unregistered (no module_exit): the dmc-sync and
 * cpufreq notifiers and the devfreq device must outlive any rate change.
 */
static int __init rk3288_dmcfreq_init(void)
{
	return platform_driver_register(&rk3288_dmcfreq_driver);
}
module_init(rk3288_dmcfreq_init);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("Rockchip dmcfreq driver with devfreq framework");
MODULE_AUTHOR("Derek Basehore <dbasehore@chromium.org>");
