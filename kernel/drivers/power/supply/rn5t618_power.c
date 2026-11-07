// SPDX-License-Identifier: GPL-2.0+
/*
 * Power supply driver for the RICOH RN5T618 power management chip family
 *
 * Copyright (C) 2020 Andreas Kemnade
 */

#include <linux/kernel.h>
#include <linux/device.h>
#include <linux/bitops.h>
#include <linux/errno.h>
#include <linux/extcon.h>
#include <linux/iio/consumer.h>
#include <linux/init.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/mfd/rn5t618.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/regmap.h>
#include <linux/slab.h>

#define CHG_STATE_ADP_INPUT 0x40
#define CHG_STATE_USB_INPUT 0x80
#define CHG_STATE_MASK	0x1f
#define CHG_STATE_CHG_OFF	0
#define CHG_STATE_CHG_READY_VADP	1
#define CHG_STATE_CHG_TRICKLE	2
#define CHG_STATE_CHG_RAPID	3
#define CHG_STATE_CHG_COMPLETE	4
#define CHG_STATE_SUSPEND	5
#define CHG_STATE_VCHG_OVER_VOL	6
#define CHG_STATE_BAT_ERROR	7
#define CHG_STATE_NO_BAT	8
#define CHG_STATE_BAT_OVER_VOL	9
#define CHG_STATE_BAT_TEMP_ERR	10
#define CHG_STATE_DIE_ERR	11
#define CHG_STATE_DIE_SHUTDOWN	12
#define CHG_STATE_NO_BAT2	13
#define CHG_STATE_CHG_READY_VUSB	14

#define GCHGDET_TYPE_MASK 0x30
#define GCHGDET_TYPE_SDP 0x00
#define GCHGDET_TYPE_CDP 0x10
#define GCHGDET_TYPE_DCP 0x20

#define FG_ENABLE 1

/*
 * Formula seems accurate for battery current, but for USB current around 70mA
 * per step was seen on Kobo Clara HD but all sources show the same formula
 * also fur USB current. To avoid accidentially unwanted high currents we stick
 * to that formula
 */
#define TO_CUR_REG(x) ((x) / 100000 - 1)
#define FROM_CUR_REG(x) ((((x) & 0x1f) + 1) * 100000)
#define CHG_MIN_CUR 100000
#define CHG_MAX_CUR 1800000
#define ADP_MAX_CUR 2500000
#define USB_MAX_CUR 1400000

/* ADP input limit per BC1.2 port type (SoC USB PHY or PMIC GCHGDET) */
#define ADP_SDP_CUR 500000
#define ADP_CDP_CUR 1500000
#define ADP_DCP_CUR 2000000
#define ADP_1A_CUR 1000000
#define CHG_POLL_MS 30000
#define CHG_MIN_VBAT_UV 3500000
/* Battery temperature in 0.1 C: 40 C / 45 C steps, 2 C hysteresis */
#define CHG_TEMP_WARM 400
#define CHG_TEMP_HOT 450
#define CHG_TEMP_HYST 20
/* RC5T619 SW JEITA, stock A6 DTB values (ricoh,jt-*) */
#define CHGCTL1_JEITA_HW 0x04 /* CHGCTL1 bit 2: PMIC HW JEITA */
#define JEITA_TEMP_L 13 /* C */
#define JEITA_TEMP_H 47 /* C */
#define JEITA_TEMP_MAX 55 /* C */
#define JEITA_ICHG_H 0x12 /* CHGISET ICHG code, 13-55 C */
#define JEITA_ICHG_L 0x00 /* CHGISET ICHG code, 0-13 C: stock default, jt-ichg-l unset */
#define JEITA_VFCHG_H 4 /* BATSET2 VFCHG code, 13-47 C */
#define JEITA_VFCHG_L 4 /* BATSET2 VFCHG code, 47-55 C */

/* Raising the ADP limit above 500 mA is allowed only after userspace sets it */
static bool high_current_allowed;
module_param(high_current_allowed, bool, 0644);
MODULE_PARM_DESC(high_current_allowed,
		 "Allow raising the ADP input limit above 500 mA (default 0)");


struct rn5t618_power_info {
	struct rn5t618 *rn5t618;
	struct platform_device *pdev;
	struct power_supply *battery;
	struct power_supply *usb;
	struct power_supply *adp;
	struct iio_channel *channel_vusb;
	struct iio_channel *channel_vadp;
	int irq;
	struct extcon_dev *edev;
	struct notifier_block extcon_nb;
	struct delayed_work chg_work;
	int chg_band;		/* 2: full, 1: 1 A, 0: 500 mA (temperature) */
	int adp_cur;		/* last ADP input limit written, uA */
};

static enum power_supply_property rn5t618_usb_props[] = {
	/* input current limit is not very accurate */
	POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,
	POWER_SUPPLY_PROP_CURRENT_MAX,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_USB_TYPE,
	POWER_SUPPLY_PROP_ONLINE,
};

static enum power_supply_property rn5t618_adp_props[] = {
	/* input current limit is not very accurate */
	POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,
	POWER_SUPPLY_PROP_CURRENT_MAX,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_ONLINE,
};


static enum power_supply_property rn5t618_battery_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_TEMP,
	POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW,
	POWER_SUPPLY_PROP_TIME_TO_FULL_NOW,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_NOW,
};

static int rn5t618_battery_read_doublereg(struct rn5t618_power_info *info,
					  u8 reg, u16 *result)
{
	int ret, i;
	u8 data[2];
	u16 old, new;

	old = 0;
	/* Prevent races when registers are changing. */
	for (i = 0; i < 3; i++) {
		ret = regmap_bulk_read(info->rn5t618->regmap,
				       reg, data, sizeof(data));
		if (ret)
			return ret;

		new = data[0] << 8;
		new |= data[1];
		if (new == old)
			break;

		old = new;
	}

	*result = new;

	return 0;
}

static int rn5t618_decode_status(unsigned int status)
{
	switch (status & CHG_STATE_MASK) {
	case CHG_STATE_CHG_OFF:
	case CHG_STATE_SUSPEND:
	case CHG_STATE_VCHG_OVER_VOL:
	case CHG_STATE_DIE_SHUTDOWN:
		return POWER_SUPPLY_STATUS_DISCHARGING;

	case CHG_STATE_CHG_TRICKLE:
	case CHG_STATE_CHG_RAPID:
		return POWER_SUPPLY_STATUS_CHARGING;

	case CHG_STATE_CHG_COMPLETE:
		return POWER_SUPPLY_STATUS_FULL;

	default:
		return POWER_SUPPLY_STATUS_NOT_CHARGING;
	}
}

static int rn5t618_battery_status(struct rn5t618_power_info *info,
				  union power_supply_propval *val)
{
	unsigned int v;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGSTATE, &v);
	if (ret)
		return ret;

	val->intval = POWER_SUPPLY_STATUS_UNKNOWN;

	if (v & 0xc0) { /* USB or ADP plugged */
		val->intval = rn5t618_decode_status(v);
	} else
		val->intval = POWER_SUPPLY_STATUS_DISCHARGING;

	return ret;
}

static int rn5t618_battery_present(struct rn5t618_power_info *info,
				   union power_supply_propval *val)
{
	unsigned int v;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGSTATE, &v);
	if (ret)
		return ret;

	v &= CHG_STATE_MASK;
	if ((v == CHG_STATE_NO_BAT) || (v == CHG_STATE_NO_BAT2))
		val->intval = 0;
	else
		val->intval = 1;

	return ret;
}

static int rn5t618_battery_voltage_now(struct rn5t618_power_info *info,
				       union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_VOLTAGE_1, &res);
	if (ret)
		return ret;

	val->intval = res * 2 * 2500 / 4095 * 1000;

	return 0;
}

static int rn5t618_battery_current_now(struct rn5t618_power_info *info,
				       union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_CC_AVEREG1, &res);
	if (ret)
		return ret;

	/* current is negative when discharging */
	val->intval = sign_extend32(res, 13) * 1000;

	return 0;
}

static int rn5t618_battery_capacity(struct rn5t618_power_info *info,
				    union power_supply_propval *val)
{
	unsigned int v;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_SOC, &v);
	if (ret)
		return ret;

	val->intval = v;

	return 0;
}

static int rn5t618_battery_temp(struct rn5t618_power_info *info,
				union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_TEMP_1, &res);
	if (ret)
		return ret;

	val->intval = sign_extend32(res, 11) * 10 / 16;

	return 0;
}

static int rn5t618_battery_health(struct rn5t618_power_info *info,
				  union power_supply_propval *val)
{
	union power_supply_propval temp;
	unsigned int v;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGSTATE, &v);
	if (ret)
		return ret;

	switch (v & CHG_STATE_MASK) {
	case CHG_STATE_VCHG_OVER_VOL:
	case CHG_STATE_BAT_OVER_VOL:
		val->intval = POWER_SUPPLY_HEALTH_OVERVOLTAGE;
		break;
	case CHG_STATE_BAT_ERROR:
		val->intval = POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;
		break;
	case CHG_STATE_BAT_TEMP_ERR:
		/* The charger only says "out of range": tell hot from cold. */
		ret = rn5t618_battery_temp(info, &temp);
		if (ret)
			return ret;
		val->intval = temp.intval < 250 ? POWER_SUPPLY_HEALTH_COLD :
						  POWER_SUPPLY_HEALTH_OVERHEAT;
		break;
	case CHG_STATE_DIE_ERR:
	case CHG_STATE_DIE_SHUTDOWN:
		val->intval = POWER_SUPPLY_HEALTH_OVERHEAT;
		break;
	case CHG_STATE_NO_BAT:
	case CHG_STATE_NO_BAT2:
		val->intval = POWER_SUPPLY_HEALTH_UNKNOWN;
		break;
	default:
		val->intval = POWER_SUPPLY_HEALTH_GOOD;
	}

	return 0;
}

static int rn5t618_battery_tte(struct rn5t618_power_info *info,
			       union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_TT_EMPTY_H, &res);
	if (ret)
		return ret;

	if (res == 65535)
		return -ENODATA;

	val->intval = res * 60;

	return 0;
}

static int rn5t618_battery_ttf(struct rn5t618_power_info *info,
			       union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_TT_FULL_H, &res);
	if (ret)
		return ret;

	if (res == 65535)
		return -ENODATA;

	val->intval = res * 60;

	return 0;
}

static int rn5t618_battery_set_current_limit(struct rn5t618_power_info *info,
				const union power_supply_propval *val)
{
	if (val->intval < CHG_MIN_CUR)
		return -EINVAL;

	if (val->intval >= CHG_MAX_CUR)
		return -EINVAL;

	return regmap_update_bits(info->rn5t618->regmap,
				  RN5T618_CHGISET,
				  0x1F, TO_CUR_REG(val->intval));
}

static int rn5t618_battery_get_current_limit(struct rn5t618_power_info *info,
					     union power_supply_propval *val)
{
	unsigned int regval;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGISET,
			  &regval);
	if (ret < 0)
		return ret;

	val->intval = FROM_CUR_REG(regval);

	return 0;
}

static int rn5t618_battery_charge_full(struct rn5t618_power_info *info,
				       union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_FA_CAP_H, &res);
	if (ret)
		return ret;

	val->intval = res * 1000;

	return 0;
}

static int rn5t618_battery_charge_now(struct rn5t618_power_info *info,
				      union power_supply_propval *val)
{
	u16 res;
	int ret;

	ret = rn5t618_battery_read_doublereg(info, RN5T618_RE_CAP_H, &res);
	if (ret)
		return ret;

	val->intval = res * 1000;

	return 0;
}

static int rn5t618_battery_get_property(struct power_supply *psy,
					enum power_supply_property psp,
					union power_supply_propval *val)
{
	int ret = 0;
	struct rn5t618_power_info *info = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		ret = rn5t618_battery_status(info, val);
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		ret = rn5t618_battery_present(info, val);
		break;
	case POWER_SUPPLY_PROP_HEALTH:
		ret = rn5t618_battery_health(info, val);
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		ret = rn5t618_battery_voltage_now(info, val);
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		ret = rn5t618_battery_current_now(info, val);
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		ret = rn5t618_battery_capacity(info, val);
		break;
	case POWER_SUPPLY_PROP_TEMP:
		ret = rn5t618_battery_temp(info, val);
		break;
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW:
		ret = rn5t618_battery_tte(info, val);
		break;
	case POWER_SUPPLY_PROP_TIME_TO_FULL_NOW:
		ret = rn5t618_battery_ttf(info, val);
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		break;
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT:
		ret = rn5t618_battery_get_current_limit(info, val);
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL:
		ret = rn5t618_battery_charge_full(info, val);
		break;
	case POWER_SUPPLY_PROP_CHARGE_NOW:
		ret = rn5t618_battery_charge_now(info, val);
		break;
	default:
		return -EINVAL;
	}

	return ret;
}

static int rn5t618_battery_set_property(struct power_supply *psy,
					enum power_supply_property psp,
					const union power_supply_propval *val)
{
	struct rn5t618_power_info *info = power_supply_get_drvdata(psy);

	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT:
		return rn5t618_battery_set_current_limit(info, val);
	default:
		return -EINVAL;
	}
}

static int rn5t618_battery_property_is_writeable(struct power_supply *psy,
						enum power_supply_property psp)
{
	switch (psp) {
	case POWER_SUPPLY_PROP_CHARGE_CONTROL_LIMIT:
		return true;
	default:
		return false;
	}
}

static int rn5t618_adp_get_property(struct power_supply *psy,
				    enum power_supply_property psp,
				    union power_supply_propval *val)
{
	struct rn5t618_power_info *info = power_supply_get_drvdata(psy);
	unsigned int chgstate;
	unsigned int regval;
	bool online;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGSTATE, &chgstate);
	if (ret)
		return ret;

	online = !!(chgstate & CHG_STATE_ADP_INPUT);

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		val->intval = online;
		break;
	case POWER_SUPPLY_PROP_STATUS:
		if (!online) {
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
			break;
		}
		val->intval = rn5t618_decode_status(chgstate);
		if (val->intval != POWER_SUPPLY_STATUS_CHARGING)
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;

		break;
	case POWER_SUPPLY_PROP_CURRENT_MAX:
		if (!online) {
			val->intval = 0;
			break;
		}
		/* fall through */
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		ret = regmap_read(info->rn5t618->regmap,
				  RN5T618_REGISET1, &regval);
		if (ret < 0)
			return ret;

		val->intval = FROM_CUR_REG(regval);
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		if (!info->channel_vadp)
			return -ENODATA;

		ret = iio_read_channel_processed(info->channel_vadp, &val->intval);
		if (ret < 0)
			return ret;
		val->intval *= 1000;

		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static int rn5t618_adp_set_property(struct power_supply *psy,
				    enum power_supply_property psp,
				    const union power_supply_propval *val)
{
	struct rn5t618_power_info *info = power_supply_get_drvdata(psy);
	int ret;

	switch (psp) {
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		if (val->intval > ADP_MAX_CUR)
			return -EINVAL;

		if (val->intval < CHG_MIN_CUR)
			return -EINVAL;

		ret = regmap_write(info->rn5t618->regmap, RN5T618_REGISET1,
				   TO_CUR_REG(val->intval));
		if (ret < 0)
			return ret;

		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static int rn5t618_adp_property_is_writeable(struct power_supply *psy,
					     enum power_supply_property psp)
{
	switch (psp) {
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		return true;
	default:
		return false;
	}
}

static int rc5t619_usb_get_type(struct rn5t618_power_info *info,
				union power_supply_propval *val)
{
	unsigned int regval;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_GCHGDET, &regval);
	if (ret < 0)
		return ret;

	switch (regval & GCHGDET_TYPE_MASK) {
	case GCHGDET_TYPE_SDP:
		val->intval = POWER_SUPPLY_USB_TYPE_SDP;
		break;
	case GCHGDET_TYPE_CDP:
		val->intval = POWER_SUPPLY_USB_TYPE_CDP;
		break;
	case GCHGDET_TYPE_DCP:
		val->intval = POWER_SUPPLY_USB_TYPE_DCP;
		break;
	default:
		val->intval = POWER_SUPPLY_USB_TYPE_UNKNOWN;
	}

	return 0;
}

static int rn5t618_usb_get_property(struct power_supply *psy,
				    enum power_supply_property psp,
				    union power_supply_propval *val)
{
	struct rn5t618_power_info *info = power_supply_get_drvdata(psy);
	unsigned int chgstate;
	unsigned int regval;
	bool online;
	int ret;

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGSTATE, &chgstate);
	if (ret)
		return ret;

	online = !!(chgstate & CHG_STATE_USB_INPUT);

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		val->intval = online;
		break;
	case POWER_SUPPLY_PROP_STATUS:
		if (!online) {
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;
			break;
		}
		val->intval = rn5t618_decode_status(chgstate);
		if (val->intval != POWER_SUPPLY_STATUS_CHARGING)
			val->intval = POWER_SUPPLY_STATUS_NOT_CHARGING;

		break;
	case POWER_SUPPLY_PROP_USB_TYPE:
		if (!online || (info->rn5t618->variant != RC5T619))
			return -ENODATA;

		return rc5t619_usb_get_type(info, val);
	case POWER_SUPPLY_PROP_CURRENT_MAX:
		if (!online) {
			val->intval = 0;
			break;
		}
		/* fall through */
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		ret = regmap_read(info->rn5t618->regmap, RN5T618_CHGCTL1,
				  &regval);
		if (ret < 0)
			return ret;

		val->intval = 0;
		if (regval & 2) {
			ret = regmap_read(info->rn5t618->regmap,
					  RN5T618_REGISET2,
					  &regval);
			if (ret < 0)
				return ret;

			val->intval = FROM_CUR_REG(regval);
		}
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		if (!info->channel_vusb)
			return -ENODATA;

		ret = iio_read_channel_processed(info->channel_vusb, &val->intval);
		if (ret < 0)
			return ret;
		val->intval *= 1000;

		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static int rn5t618_usb_set_property(struct power_supply *psy,
				    enum power_supply_property psp,
				    const union power_supply_propval *val)
{
	struct rn5t618_power_info *info = power_supply_get_drvdata(psy);
	int ret;

	switch (psp) {
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		if (val->intval > USB_MAX_CUR)
			return -EINVAL;

		if (val->intval < CHG_MIN_CUR)
			return -EINVAL;

		ret = regmap_write(info->rn5t618->regmap, RN5T618_REGISET2,
				   0xE0 | TO_CUR_REG(val->intval));
		if (ret < 0)
			return ret;

		break;
	default:
		return -EINVAL;
	}

	return 0;
}

static int rn5t618_usb_property_is_writeable(struct power_supply *psy,
					     enum power_supply_property psp)
{
	switch (psp) {
	case POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT:
		return true;
	default:
		return false;
	}
}

static const struct power_supply_desc rn5t618_battery_desc = {
	.name                   = "rn5t618-battery",
	.type                   = POWER_SUPPLY_TYPE_BATTERY,
	.properties             = rn5t618_battery_props,
	.num_properties         = ARRAY_SIZE(rn5t618_battery_props),
	.get_property           = rn5t618_battery_get_property,
	.set_property           = rn5t618_battery_set_property,
	.property_is_writeable  = rn5t618_battery_property_is_writeable,
};

static const struct power_supply_desc rn5t618_adp_desc = {
	.name                   = "rn5t618-adp",
	.type                   = POWER_SUPPLY_TYPE_MAINS,
	.properties             = rn5t618_adp_props,
	.num_properties         = ARRAY_SIZE(rn5t618_adp_props),
	.get_property           = rn5t618_adp_get_property,
	.set_property           = rn5t618_adp_set_property,
	.property_is_writeable  = rn5t618_adp_property_is_writeable,
};

static enum power_supply_usb_type rn5t618_usb_types[] = {
	POWER_SUPPLY_USB_TYPE_SDP,
	POWER_SUPPLY_USB_TYPE_CDP,
	POWER_SUPPLY_USB_TYPE_DCP,
	POWER_SUPPLY_USB_TYPE_UNKNOWN,
};

static const struct power_supply_desc rn5t618_usb_desc = {
	.name                   = "rn5t618-usb",
	.type                   = POWER_SUPPLY_TYPE_USB,
	.usb_types		= rn5t618_usb_types,
	.num_usb_types		= ARRAY_SIZE(rn5t618_usb_types),
	.properties             = rn5t618_usb_props,
	.num_properties         = ARRAY_SIZE(rn5t618_usb_props),
	.get_property           = rn5t618_usb_get_property,
	.set_property           = rn5t618_usb_set_property,
	.property_is_writeable  = rn5t618_usb_property_is_writeable,
};

static irqreturn_t rn5t618_charger_irq(int irq, void *data)
{
	struct device *dev = data;
	struct rn5t618_power_info *info = dev_get_drvdata(dev);

	unsigned int ctrl, stat1, stat2, err;

	regmap_read(info->rn5t618->regmap, RN5T618_CHGERR_IRR, &err);
	regmap_read(info->rn5t618->regmap, RN5T618_CHGCTRL_IRR, &ctrl);
	regmap_read(info->rn5t618->regmap, RN5T618_CHGSTAT_IRR1, &stat1);
	regmap_read(info->rn5t618->regmap, RN5T618_CHGSTAT_IRR2, &stat2);

	regmap_write(info->rn5t618->regmap, RN5T618_CHGERR_IRR, 0);
	regmap_write(info->rn5t618->regmap, RN5T618_CHGCTRL_IRR, 0);
	regmap_write(info->rn5t618->regmap, RN5T618_CHGSTAT_IRR1, 0);
	regmap_write(info->rn5t618->regmap, RN5T618_CHGSTAT_IRR2, 0);

	dev_dbg(dev, "chgerr: %x chgctrl: %x chgstat: %x chgstat2: %x\n",
		err, ctrl, stat1, stat2);

	power_supply_changed(info->usb);
	power_supply_changed(info->adp);
	power_supply_changed(info->battery);
	mod_delayed_work(system_wq, &info->chg_work, 0);

	return IRQ_HANDLED;
}

/*
 * ADP input limit policy. The OTP limit (500 mA) is the boot default. A
 * higher limit needs high_current_allowed (set by userspace after boot),
 * a DCP (2 A) or CDP (1.5 A) port, battery >= 3.5 V and a battery
 * temperature band: < 40 C full, >= 40 C 1 A, >= 45 C 500 mA.
 */
static int rn5t618_port_cur(struct rn5t618_power_info *info)
{
	unsigned int gchgdet;
	int cur = ADP_SDP_CUR;
	int ret;

	if (info->edev) {
		if (extcon_get_state(info->edev, EXTCON_CHG_USB_CDP) > 0)
			cur = ADP_CDP_CUR;
		if (extcon_get_state(info->edev, EXTCON_CHG_USB_DCP) > 0)
			cur = ADP_DCP_CUR;
	}

	/*
	 * The PHY can report SDP for an adapter the PMIC classifies as DCP
	 * (GCHGDET). Use the higher class of the two sources.
	 */
	if (info->rn5t618->variant == RC5T619) {
		ret = regmap_read(info->rn5t618->regmap, RN5T618_GCHGDET,
				  &gchgdet);
		if (ret) {
			dev_warn(&info->pdev->dev,
				 "read GCHGDET failed: %d\n", ret);
		} else {
			switch (gchgdet & GCHGDET_TYPE_MASK) {
			case GCHGDET_TYPE_DCP:
				cur = max(cur, ADP_DCP_CUR);
				break;
			case GCHGDET_TYPE_CDP:
				cur = max(cur, ADP_CDP_CUR);
				break;
			default:
				break;
			}
		}
	}

	return cur;
}

/* Temperature band: 2 full, 1 1 A, 0 500 mA; 2 C hysteresis when stepping up */
static int rn5t618_chg_band(int temp, int prev)
{
	if (temp >= CHG_TEMP_HOT)
		return 0;
	if (temp >= CHG_TEMP_WARM)
		return (prev == 0 && temp > CHG_TEMP_HOT - CHG_TEMP_HYST) ? 0 : 1;
	if (prev != 2 && temp >= CHG_TEMP_WARM - CHG_TEMP_HYST)
		return 1;
	return 2;
}

static int rn5t618_adp_target(struct rn5t618_power_info *info)
{
	union power_supply_propval temp, volt;
	int cap = rn5t618_port_cur(info);
	int band = 0;

	if (!high_current_allowed) {
		info->chg_band = 2;
		return ADP_SDP_CUR;
	}

	if (!rn5t618_battery_temp(info, &temp))
		band = rn5t618_chg_band(temp.intval, info->chg_band);
	info->chg_band = band;

	if (rn5t618_battery_voltage_now(info, &volt) ||
	    volt.intval < CHG_MIN_VBAT_UV)
		return ADP_SDP_CUR;

	switch (band) {
	case 2:
		return cap;
	case 1:
		return min(cap, ADP_1A_CUR);
	default:
		return ADP_SDP_CUR;
	}
}

/*
 * RC5T619 software JEITA, as stock popmetal ricoh619-battery.c
 * check_jeita_status(): charge current/voltage per temperature band,
 * charging off outside 0-55 C. Runs from rn5t618_chg_work every 30 s.
 */
static int rc5t619_jeita_update(struct rn5t618_power_info *info)
{
	struct regmap *regmap = info->rn5t618->regmap;
	union power_supply_propval temp;
	unsigned int batset2, chgiset;
	unsigned int vfchg;
	unsigned int ichg;
	int t;
	int ret;

	ret = rn5t618_battery_temp(info, &temp);
	if (ret)
		return ret;
	t = temp.intval / 10;

	if (t <= 0 || t >= JEITA_TEMP_MAX)
		return regmap_update_bits(regmap, RN5T618_CHGCTL1, 0x03, 0);

	if (t < JEITA_TEMP_L) {
		vfchg = JEITA_VFCHG_H;
		ichg = JEITA_ICHG_L;
	} else if (t < JEITA_TEMP_H) {
		vfchg = JEITA_VFCHG_H;
		ichg = JEITA_ICHG_H;
	} else {
		vfchg = JEITA_VFCHG_L;
		ichg = JEITA_ICHG_H;
	}

	ret = regmap_read(regmap, RN5T618_BATSET2, &batset2);
	if (ret)
		return ret;
	if (((batset2 & 0x70) >> 4) != vfchg) {
		ret = regmap_update_bits(regmap, RN5T618_CHGCTL1, 0x03, 0);
		if (ret)
			return ret;
		ret = regmap_write(regmap, RN5T618_BATSET2,
				   (vfchg << 4) | (batset2 & 0x8f));
		if (ret)
			return ret;
	}

	ret = regmap_read(regmap, RN5T618_CHGISET, &chgiset);
	if (ret)
		return ret;
	ret = regmap_write(regmap, RN5T618_CHGISET,
			   (chgiset & 0xc0) | ichg);
	if (ret)
		return ret;

	return regmap_update_bits(regmap, RN5T618_CHGCTL1, 0x03, 0x03);
}

static void rn5t618_chg_work(struct work_struct *work)
{
	struct rn5t618_power_info *info =
		container_of(to_delayed_work(work), struct rn5t618_power_info,
			     chg_work);
	int cur = rn5t618_adp_target(info);
	int ret;

	if (info->rn5t618->variant == RC5T619) {
		ret = rc5t619_jeita_update(info);
		if (ret)
			dev_err(&info->pdev->dev, "JEITA update failed: %d\n", ret);
	}

	if (cur != info->adp_cur) {
		ret = regmap_write(info->rn5t618->regmap, RN5T618_REGISET1,
				   TO_CUR_REG(cur));
		if (ret) {
			dev_err(&info->pdev->dev, "set adp limit failed: %d\n",
				ret);
		} else {
			info->adp_cur = cur;
			dev_info(&info->pdev->dev, "adp input limit %d uA\n",
				 cur);
			power_supply_changed(info->adp);
		}
	}

	schedule_delayed_work(&info->chg_work, msecs_to_jiffies(CHG_POLL_MS));
}

static int rn5t618_extcon_notifier(struct notifier_block *nb,
				   unsigned long event, void *ptr)
{
	struct rn5t618_power_info *info =
		container_of(nb, struct rn5t618_power_info, extcon_nb);

	/* Called under the extcon spinlock: only queue the work here. */
	mod_delayed_work(system_wq, &info->chg_work, 0);

	return NOTIFY_OK;
}

static void rn5t618_chg_stop(void *data)
{
	struct rn5t618_power_info *info = data;

	cancel_delayed_work_sync(&info->chg_work);
}

static int rn5t618_extcon_init(struct rn5t618_power_info *info)
{
	struct device *dev = &info->pdev->dev;
	int ret;

	if (!of_property_read_bool(dev->parent->of_node, "extcon"))
		return 0;

	info->edev = extcon_get_edev_by_phandle(dev->parent, 0);
	if (IS_ERR(info->edev))
		return PTR_ERR(info->edev);

	info->extcon_nb.notifier_call = rn5t618_extcon_notifier;
	return devm_extcon_register_notifier_all(dev, info->edev,
						 &info->extcon_nb);
}

static int rn5t618_power_probe(struct platform_device *pdev)
{
	int ret = 0;
	unsigned int v;
	struct power_supply_config psy_cfg = {};
	struct rn5t618_power_info *info;

	info = devm_kzalloc(&pdev->dev, sizeof(*info), GFP_KERNEL);
	if (!info)
		return -ENOMEM;

	info->pdev = pdev;
	info->rn5t618 = dev_get_drvdata(pdev->dev.parent);
	info->irq = -1;

	platform_set_drvdata(pdev, info);

	INIT_DELAYED_WORK(&info->chg_work, rn5t618_chg_work);
	ret = devm_add_action_or_reset(&pdev->dev, rn5t618_chg_stop, info);
	if (ret)
		return ret;

	info->channel_vusb = devm_iio_channel_get(&pdev->dev, "vusb");
	if (IS_ERR(info->channel_vusb)) {
		if (PTR_ERR(info->channel_vusb) != -ENODEV)
			return PTR_ERR(info->channel_vusb);
		dev_info(&pdev->dev, "no vusb IIO channel, USB voltage unavailable\n");
		info->channel_vusb = NULL;
	}

	info->channel_vadp = devm_iio_channel_get(&pdev->dev, "vadp");
	if (IS_ERR(info->channel_vadp)) {
		if (PTR_ERR(info->channel_vadp) != -ENODEV)
			return PTR_ERR(info->channel_vadp);
		dev_info(&pdev->dev, "no vadp IIO channel, adapter voltage unavailable\n");
		info->channel_vadp = NULL;
	}

	ret = regmap_read(info->rn5t618->regmap, RN5T618_CONTROL, &v);
	if (ret)
		return ret;

	if (!(v & FG_ENABLE)) {
		/* E.g. the vendor kernels of various Kobo and Tolino Ebook
		 * readers disable the fuel gauge on shutdown. If a kernel
		 * without fuel gauge support is booted after that, the fuel
		 * gauge will get decalibrated.
		 */
		dev_info(&pdev->dev, "Fuel gauge not enabled, enabling now\n");
		dev_info(&pdev->dev, "Expect imprecise results\n");
		regmap_update_bits(info->rn5t618->regmap, RN5T618_CONTROL,
				   FG_ENABLE, FG_ENABLE);
	}

	if (info->rn5t618->variant == RC5T619) {
		/* Stock jt-hw-sw=0: PMIC HW JEITA off, SW JEITA in chg_work */
		ret = regmap_update_bits(info->rn5t618->regmap, RN5T618_CHGCTL1,
					 CHGCTL1_JEITA_HW, 0);
		if (ret)
			return ret;
	}

	psy_cfg.drv_data = info;
	info->battery = devm_power_supply_register(&pdev->dev,
						   &rn5t618_battery_desc,
						   &psy_cfg);
	if (IS_ERR(info->battery)) {
		ret = PTR_ERR(info->battery);
		dev_err(&pdev->dev, "failed to register battery: %d\n", ret);
		return ret;
	}

	info->adp = devm_power_supply_register(&pdev->dev,
					       &rn5t618_adp_desc,
					       &psy_cfg);
	if (IS_ERR(info->adp)) {
		ret = PTR_ERR(info->adp);
		dev_err(&pdev->dev, "failed to register adp: %d\n", ret);
		return ret;
	}

	info->usb = devm_power_supply_register(&pdev->dev,
					       &rn5t618_usb_desc,
					       &psy_cfg);
	if (IS_ERR(info->usb)) {
		ret = PTR_ERR(info->usb);
		dev_err(&pdev->dev, "failed to register usb: %d\n", ret);
		return ret;
	}

	if (info->rn5t618->irq_data)
		info->irq = regmap_irq_get_virq(info->rn5t618->irq_data,
						RN5T618_IRQ_CHG);

	if (info->irq < 0)
		info->irq = -1;
	else {
		ret = devm_request_threaded_irq(&pdev->dev, info->irq, NULL,
						rn5t618_charger_irq,
						IRQF_ONESHOT,
						"rn5t618_power",
						&pdev->dev);

		if (ret < 0)
			info->irq = -1;
	}
	ret = rn5t618_extcon_init(info);
	if (ret) {
		if (ret != -EPROBE_DEFER)
			dev_err(&pdev->dev, "extcon init failed: %d\n", ret);
		return ret;
	}

	/* Starts at the 500 mA default; raised only when allowed */
	schedule_delayed_work(&info->chg_work, 0);

	return 0;
}

static struct platform_driver rn5t618_power_driver = {
	.driver = {
		.name   = "rn5t618-power",
	},
	.probe = rn5t618_power_probe,
};

module_platform_driver(rn5t618_power_driver);
MODULE_ALIAS("platform:rn5t618-power");
MODULE_DESCRIPTION("Power supply driver for RICOH RN5T618");
MODULE_LICENSE("GPL");
