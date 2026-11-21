// SPDX-License-Identifier: GPL-2.0-only
/*
 * RICOH RC5T619 PWRON key driver
 *
 * Reports KEY_POWER from the PMIC PWRON pin. Attached as an MFD cell of the
 * rn5t618 core; the PMIC SYSTEM interrupt is the parent's regmap_irq line.
 *
 * Register bit layout (PWRIREN/PWRIRQ/PWRIRSEL/PWRMON) follows the RN5T568
 * datasheet: [INFERENCE] RC5T619 uses the same map, not datasheet-verified.
 */

#include <linux/device.h>
#include <linux/input.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/mfd/rn5t618.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

struct rc5t619_pwrkey {
	struct device *dev;
	struct regmap *regmap;
	struct input_dev *input;
};

static irqreturn_t rc5t619_pwrkey_irq(int irq, void *_pwrkey)
{
	struct rc5t619_pwrkey *pwrkey = _pwrkey;
	unsigned int mon;
	int error;

	/*
	 * Clear IR_PWRON before sampling PWRMON: an edge arriving after the
	 * read re-raises the SYSTEM interrupt. The ack is a read-modify-write
	 * that writes IR_PWRON back as 0 (clear-by-writing-0, as rn5t618_wdt.c).
	 */
	error = regmap_update_bits(pwrkey->regmap, RN5T618_PWRIRQ,
				   RN5T618_PWRIRQ_IR_PWRON, 0);
	if (error) {
		dev_err(pwrkey->dev, "failed to clear PWRIRQ: %d\n", error);
		return IRQ_HANDLED;
	}

	error = regmap_read(pwrkey->regmap, RN5T618_PWRMON, &mon);
	if (error) {
		dev_err(pwrkey->dev, "failed to read PWRMON: %d\n", error);
		return IRQ_HANDLED;
	}

	input_report_key(pwrkey->input, KEY_POWER,
			 mon & RN5T618_PWRMON_MON_PWRON);
	input_sync(pwrkey->input);

	return IRQ_HANDLED;
}

static int rc5t619_pwrkey_probe(struct platform_device *pdev)
{
	struct rn5t618 *rn5t618 = dev_get_drvdata(pdev->dev.parent);
	struct rc5t619_pwrkey *pwrkey;
	int irq, error;

	if (!rn5t618->irq_data)
		return -ENODEV;

	irq = regmap_irq_get_virq(rn5t618->irq_data, RN5T618_IRQ_SYS);
	if (irq < 0)
		return irq;

	pwrkey = devm_kzalloc(&pdev->dev, sizeof(*pwrkey), GFP_KERNEL);
	if (!pwrkey)
		return -ENOMEM;

	pwrkey->dev = &pdev->dev;
	pwrkey->regmap = rn5t618->regmap;

	pwrkey->input = devm_input_allocate_device(&pdev->dev);
	if (!pwrkey->input)
		return -ENOMEM;

	/* Name matches the stock Android input device. */
	pwrkey->input->name = "ricoh619_pwrkey";
	pwrkey->input->dev.parent = &pdev->dev;
	input_set_capability(pwrkey->input, EV_KEY, KEY_POWER);

	/* Both-edge interrupt type (SEL_PWRON=1 is the reset default). */
	error = regmap_update_bits(pwrkey->regmap, RN5T618_PWRIRSEL,
				   RN5T618_PWRIRSEL_SEL_PWRON,
				   RN5T618_PWRIRSEL_SEL_PWRON);
	if (error)
		return error;

	/* Boot-time latched PWRIRQ (0x44) must not raise the first IRQ. */
	error = regmap_write(pwrkey->regmap, RN5T618_PWRIRQ, 0x00);
	if (error)
		return error;

	error = devm_request_threaded_irq(&pdev->dev, irq, NULL,
					  rc5t619_pwrkey_irq, IRQF_ONESHOT,
					  "rc5t619-pwrkey", pwrkey);
	if (error) {
		dev_err(&pdev->dev, "failed to request IRQ %d: %d\n", irq, error);
		return error;
	}

	error = regmap_update_bits(pwrkey->regmap, RN5T618_PWRIREN,
				   RN5T618_PWRIREN_EN_PWRON,
				   RN5T618_PWRIREN_EN_PWRON);
	if (error)
		return error;

	error = input_register_device(pwrkey->input);
	if (error) {
		dev_err(&pdev->dev, "failed to register input: %d\n", error);
		return error;
	}

	return 0;
}

static struct platform_driver rc5t619_pwrkey_driver = {
	.probe = rc5t619_pwrkey_probe,
	.driver = {
		.name = "rc5t619-pwrkey",
	},
};
module_platform_driver(rc5t619_pwrkey_driver);

MODULE_ALIAS("platform:rc5t619-pwrkey");
MODULE_DESCRIPTION("RICOH RC5T619 PWRON key driver");
MODULE_LICENSE("GPL");
