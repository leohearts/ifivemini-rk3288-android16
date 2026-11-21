// SPDX-License-Identifier: GPL-2.0-only
/*
 * drivers/input/touchscreen/gslx680_firefly.c
 *
 * Silead GSLx680 touchscreen controller driver (iFive mini 4S panel).
 *
 * Copyright (c) 2012 Shanghai Basewin
 *	Guan Yuwei<guanyuwei@basewin.com>
 */

#include <linux/module.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/input.h>
#include <linux/input/mt.h>
#include <linux/interrupt.h>
#include <linux/irq.h>

#include <linux/gpio.h>
#include <linux/of_gpio.h>
#include "tp_suspend.h"

#include "gslx680_firefly.h"

#define GSLX680_I2C_NAME	"gslX680"

#define GSL_DATA_REG		0x80
#define GSL_STATUS_REG		0xe0
#define GSL_PAGE_REG		0xf0

#define PRESS_MAX		255
#define MAX_FINGERS		10
#define MAX_CONTACTS		10
#define DMA_TRANS_LEN		0x20

#define GPIO_LOW	0
#define GPIO_HIGH	1

/* Panel type from gsl_identify_tp(): 0 = not identified, else 1..3. */
static int gsl_tp_type;

struct gsl_ts_data {
	u8 x_index;
	u8 y_index;
	u8 z_index;
	u8 id_index;
	u8 touch_index;
	u8 data_reg;
	u8 status_reg;
	u8 data_size;
	u8 touch_bytes;
	u8 update_data;
	u8 touch_meta_data;
	u8 finger_size;
};

static struct gsl_ts_data devices[] = {
	{
	.x_index = 6,
	.y_index = 4,
	.z_index = 5,
	.id_index = 7,
	.data_reg = GSL_DATA_REG,
	.status_reg = GSL_STATUS_REG,
	.update_data = 0x4,
	.touch_bytes = 4,
	.touch_meta_data = 4,
	.finger_size = 70,
	},
};

struct gsl_ts {
	struct i2c_client *client;
	struct input_dev *input;
	struct gsl_ts_data *dd;
	u8 *touch_data;
	u8 device_id;
	int irq;
	int irq_pin;
	int rst_pin;
	int flip_x;
	int flip_y;
	int swap_xy;
	struct  tp_device  tp;
};

#ifdef GSL_DEBUG
#define print_info(fmt, args...)   \
	do {                              \
		printk(fmt, ##args);     \
	} while (0)
#else
#define print_info(fmt, args...)
#endif

static u8 id_state_flag[MAX_CONTACTS + 1] = {0};
static u8 id_state_old_flag[MAX_CONTACTS + 1] = {0};
static struct gsl_ts *gts;

static void gslX680_shutdown_low(void)
{
	if (gpio_is_valid(gts->rst_pin))
		gpio_set_value(gts->rst_pin, GPIO_LOW);
}

static void gslX680_shutdown_high(void)
{
	if (gpio_is_valid(gts->rst_pin))
		gpio_set_value(gts->rst_pin, GPIO_HIGH);
}

static inline u16 join_bytes(u8 a, u8 b)
{
	u16 ab = 0;

	ab = ab | a;
	ab = ab << 8 | b;
	return ab;
}

static int gsl_write_interface(struct i2c_client *client, const u8 reg, u8 *buf, u32 num)
{
	struct i2c_msg xfer_msg[1];

	buf[0] = reg;
	xfer_msg[0].addr = client->addr;
	xfer_msg[0].len = num + 1;
	xfer_msg[0].flags = client->flags & I2C_M_TEN;
	xfer_msg[0].buf = buf;

	return i2c_transfer(client->adapter, xfer_msg, 1) == 1 ? 0 : -EFAULT;
}

static int gsl_ts_write(struct i2c_client *client, u8 addr, u8 *pdata, int datalen)
{
	int ret = 0;
	u8 tmp_buf[128];
	unsigned int bytelen = 0;

	if (datalen > 125)
		return -1;

	tmp_buf[0] = addr;
	bytelen++;
	if (datalen != 0 && pdata != NULL) {
		memcpy(&tmp_buf[bytelen], pdata, datalen);
		bytelen += datalen;
	}
	ret = i2c_master_send(client, tmp_buf, bytelen);
	return ret;
}

static int gsl_ts_read(struct i2c_client *client, u8 addr, u8 *pdata, unsigned int datalen)
{
	int ret = 0;

	if (datalen > 126)
		return -1;

	ret = gsl_ts_write(client, addr, NULL, 0);
	if (ret < 0)
		return ret;

	return i2c_master_recv(client, pdata, datalen);
}

static unsigned int *gsl_tp_config(void)
{
	switch (gsl_tp_type) {
	case 1:
		return gsl_config_data_id_1;
	case 2:
		return gsl_config_data_id_2;
	case 3:
		return gsl_config_data_id_3;
	default:
		return gsl_config_data_id_check;
	}
}

static __inline__ void fw2buf(u8 *buf, const u32 *fw)
{
	u32 *u32_buf = (int *)buf;
	*u32_buf = *fw;
}

static void gsl_load_fw(struct i2c_client *client, const struct fw_data *ptr_fw,
			u32 source_len)
{
	u8 buf[DMA_TRANS_LEN * 4 + 1] = {0};
	u8 send_flag = 1;
	u8 *cur = buf + 1;
	u32 source_line = 0;

	for (source_line = 0; source_line < source_len; source_line++) {
		/* init page trans, set the page val */
		if (GSL_PAGE_REG == ptr_fw[source_line].offset) {
			fw2buf(cur, &ptr_fw[source_line].val);
			gsl_write_interface(client, GSL_PAGE_REG, buf, 4);
			send_flag = 1;
		} else {
			if (1 == send_flag % (DMA_TRANS_LEN < 0x20 ? DMA_TRANS_LEN : 0x20))
				buf[0] = (u8)ptr_fw[source_line].offset;

			fw2buf(cur, &ptr_fw[source_line].val);
			cur += 4;

			if (0 == send_flag % (DMA_TRANS_LEN < 0x20 ? DMA_TRANS_LEN : 0x20)) {
				gsl_write_interface(client, buf[0], buf, cur - buf - 1);
				cur = buf + 1;
			}
			send_flag++;
		}
	}
}

static int test_i2c(struct i2c_client *client)
{
	u8 read_buf = 0;
	u8 write_buf = 0x12;
	int ret, rc = 1;

	ret = gsl_ts_read(client, 0xf0, &read_buf, sizeof(read_buf));
	if (ret  < 0)
		rc--;

	msleep(2);
	ret = gsl_ts_write(client, 0xf0, &write_buf, sizeof(write_buf));

	msleep(2);
	ret = gsl_ts_read(client, 0xf0, &read_buf, sizeof(read_buf));
	if (ret <  0)
		rc--;

	return rc;
}

static void startup_chip(struct i2c_client *client)
{
	u8 tmp = 0x00;

	gsl_DataInit(gsl_tp_config());
	gsl_ts_write(client, 0xe0, &tmp, 1);
	msleep(10);
}

static void reset_chip(struct i2c_client *client)
{
	u8 tmp = 0x88;
	u8 buf[4] = {0x00};

	gsl_ts_write(client, 0xe0, &tmp, sizeof(tmp));
	msleep(20);
	tmp = 0x04;
	gsl_ts_write(client, 0xe4, &tmp, sizeof(tmp));
	msleep(10);
	gsl_ts_write(client, 0xbc, buf, sizeof(buf));
	msleep(10);
}

static void clr_reg(struct i2c_client *client)
{
	u8 write_buf[4]	= {0};

	write_buf[0] = 0x88;
	gsl_ts_write(client, 0xe0, &write_buf[0], 1);
	msleep(20);
	write_buf[0] = 0x03;
	gsl_ts_write(client, 0x80, &write_buf[0], 1);
	msleep(5);
	write_buf[0] = 0x04;
	gsl_ts_write(client, 0xe4, &write_buf[0], 1);
	msleep(5);
	write_buf[0] = 0x00;
	gsl_ts_write(client, 0xe0, &write_buf[0], 1);
	msleep(20);
}

/*
 * Stock panel identification: run the check firmware, then match the id
 * word at 0xb8 against the two known panel ids.
 */
static void gsl_identify_tp(struct i2c_client *client)
{
	u8 buf[4] = {0};
	u32 val, diff1, diff2;

	clr_reg(client);
	reset_chip(client);
	gsl_load_fw(client, GSL_TP_CHECK_FW, ARRAY_SIZE(GSL_TP_CHECK_FW));
	startup_chip(client);
	msleep(200);

	gsl_ts_read(client, 0xb4, buf, sizeof(buf));
	if (((buf[3] << 8) | buf[2]) <= 1) {
		dev_err(&client->dev, "gslX680: check firmware not running, panel not identified\n");
		return;
	}

	msleep(20);
	gsl_ts_read(client, 0xb8, buf, sizeof(buf));
	val = buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
	diff1 = hweight32(val ^ 0x138010) + 100 * hweight32(~val & 0x138010);
	diff2 = hweight32(val ^ 0x13c010) + 100 * hweight32(~val & 0x13c010);
	if (diff1 > diff2)
		gsl_tp_type = 2;
	else if (diff1 == 0)
		gsl_tp_type = 1;
	else
		gsl_tp_type = 3;

	dev_info(&client->dev, "gslX680: panel id 0x%08x, type %d\n", val, gsl_tp_type);
}

static void init_chip(struct i2c_client *client)
{
	int rc;

	gslX680_shutdown_low();
	msleep(20);
	gslX680_shutdown_high();
	msleep(20);
	rc = test_i2c(client);
	if (rc < 0) {
		print_info("------gslX680 test_i2c error------\n");
		return;
	}
	clr_reg(client);
	reset_chip(client);
	if (!gsl_tp_type) {
		gsl_identify_tp(client);
		reset_chip(client);
	}
	switch (gsl_tp_type) {
	case 1:
		gsl_load_fw(client, GSLX680_FW_1, ARRAY_SIZE(GSLX680_FW_1));
		break;
	case 2:
		gsl_load_fw(client, GSLX680_FW_2, ARRAY_SIZE(GSLX680_FW_2));
		break;
	case 3:
		gsl_load_fw(client, GSLX680_FW_3, ARRAY_SIZE(GSLX680_FW_3));
		break;
	}
	startup_chip(client);
	reset_chip(client);
	startup_chip(client);
}

static void check_mem_data(struct i2c_client *client)
{
	u8 read_buf[4]  = {0};

	msleep(30);
	gsl_ts_read(client, 0xb0, read_buf, sizeof(read_buf));

	if (read_buf[3] != 0x5a || read_buf[2] != 0x5a || read_buf[1] != 0x5a || read_buf[0] != 0x5a)
		init_chip(client);
}

static void report_data(struct gsl_ts *ts, u16 x, u16 y, u8 pressure, u8 id)
{
	if (ts->swap_xy == 1)
		swap(x, y);

	if (ts->flip_x == 1)
		x = SCREEN_MAX_X - x;

	if (ts->flip_y == 1)
		y = SCREEN_MAX_Y - y;

	print_info("#####id=%d,x=%d,y=%d######\n", id, x, y);

	if (x > SCREEN_MAX_X || y > SCREEN_MAX_Y)
		return;

	input_mt_slot(ts->input, id);
	input_report_abs(ts->input, ABS_MT_TRACKING_ID, id);
	input_report_abs(ts->input, ABS_MT_TOUCH_MAJOR, pressure);
	input_report_abs(ts->input, ABS_MT_POSITION_X, x);
	input_report_abs(ts->input, ABS_MT_POSITION_Y, y);
	input_report_abs(ts->input, ABS_MT_WIDTH_MAJOR, 1);
}

static void gslX680_ts_read_frame(struct gsl_ts *ts)
{
	int rc, i;
	u8 id, touches;
	u32 tmp1;
	u8 buf[4] = {0};
	struct gsl_touch_info cinfo = {{0} };

	rc = gsl_ts_read(ts->client, 0x80, ts->touch_data, ts->dd->data_size);
	if (rc < 0) {
		dev_err(&ts->client->dev, "read failed\n");
		return;
	}

	touches = ts->touch_data[ts->dd->touch_index];
	print_info("-----touches: %d -----\n", touches);
	cinfo.finger_num = touches;
	print_info("tp-gsl  finger_num = %d\n", cinfo.finger_num);
	for (i = 0; i < (touches < MAX_CONTACTS ? touches : MAX_CONTACTS); i++) {
		cinfo.x[i] = join_bytes((ts->touch_data[ts->dd->x_index  + 4 * i + 1] & 0xf),
				ts->touch_data[ts->dd->x_index + 4 * i]);
		cinfo.y[i] = join_bytes(ts->touch_data[ts->dd->y_index + 4 * i + 1],
				ts->touch_data[ts->dd->y_index + 4 * i]);
		print_info("tp-gsl  x = %d y = %d\n", cinfo.x[i], cinfo.y[i]);
	}
	cinfo.finger_num = (ts->touch_data[3] << 24) | (ts->touch_data[2] << 16)
		| (ts->touch_data[1] << 8) | (ts->touch_data[0]);
	gsl_alg_id_main(&cinfo);
	tmp1 = gsl_mask_tiaoping();
	print_info("[tp-gsl] tmp1=%x\n", tmp1);
	if (tmp1 > 0 && tmp1 < 0xffffffff) {
		buf[0] = 0xa; buf[1] = 0; buf[2] = 0; buf[3] = 0;
		gsl_ts_write(ts->client, 0xf0, buf, 4);
		buf[0] = (u8)(tmp1 & 0xff);
		buf[1] = (u8)((tmp1 >> 8) & 0xff);
		buf[2] = (u8)((tmp1 >> 16) & 0xff);
		buf[3] = (u8)((tmp1 >> 24) & 0xff);
		print_info("tmp1=%08x,buf[0]=%02x,buf[1]=%02x,buf[2]=%02x,buf[3]=%02x\n",
			   tmp1, buf[0], buf[1], buf[2], buf[3]);
		gsl_ts_write(ts->client, 0x8, buf, 4);
	}
	touches = cinfo.finger_num;

	for (i = 1; i <= MAX_CONTACTS; i++)
		id_state_flag[i] = 0;

	for (i = 0; i < (touches > MAX_FINGERS ? MAX_FINGERS : touches); i++) {
		id = cinfo.id[i];

		if (1 <= id && id <= MAX_CONTACTS) {
			report_data(ts, cinfo.x[i], cinfo.y[i], 10, id);
			id_state_flag[id] = 1;
		}
	}
	for (i = 1; i <= MAX_CONTACTS; i++) {
		if ((touches == 0) || ((id_state_old_flag[i] != 0) && (id_state_flag[i] == 0))) {
			input_mt_slot(ts->input, i);
			input_report_abs(ts->input, ABS_MT_TRACKING_ID, -1);
			input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, false);
		}
		id_state_old_flag[i] = id_state_flag[i];
	}
	input_sync(ts->input);
}

static irqreturn_t gsl_ts_irq(int irq, void *dev_id)
{
	struct gsl_ts *ts = dev_id;

	print_info("========gslX680 Interrupt=========\n");

	gslX680_ts_read_frame(ts);

	return IRQ_HANDLED;
}

static int gslX680_ts_init(struct i2c_client *client, struct gsl_ts *ts)
{
	struct input_dev *input_device;
	int rc;

	ts->dd = &devices[ts->device_id];

	if (ts->device_id == 0) {
		ts->dd->data_size = MAX_FINGERS * ts->dd->touch_bytes + ts->dd->touch_meta_data;
		ts->dd->touch_index = 0;
	}

	ts->touch_data = devm_kzalloc(&client->dev, ts->dd->data_size, GFP_KERNEL);
	if (!ts->touch_data)
		return -ENOMEM;

	input_device = devm_input_allocate_device(&client->dev);
	if (!input_device)
		return -ENOMEM;

	ts->input = input_device;
	input_device->name = GSLX680_I2C_NAME;
	input_device->id.bustype = BUS_I2C;
	input_device->dev.parent = &client->dev;
	input_set_drvdata(input_device, ts);

	__set_bit(EV_ABS, input_device->evbit);
	__set_bit(EV_KEY, input_device->evbit);
	__set_bit(EV_REP, input_device->evbit);
	__set_bit(INPUT_PROP_DIRECT, input_device->propbit);
	input_mt_init_slots(input_device, (MAX_CONTACTS + 1), 0);

	set_bit(ABS_MT_POSITION_X, input_device->absbit);
	set_bit(ABS_MT_POSITION_Y, input_device->absbit);
	set_bit(ABS_MT_TOUCH_MAJOR, input_device->absbit);
	set_bit(ABS_MT_WIDTH_MAJOR, input_device->absbit);

	input_set_abs_params(input_device, ABS_MT_POSITION_X, 0, SCREEN_MAX_X, 0, 0);
	input_set_abs_params(input_device, ABS_MT_POSITION_Y, 0, SCREEN_MAX_Y, 0, 0);

	input_set_abs_params(input_device, ABS_MT_TOUCH_MAJOR, 0, PRESS_MAX, 0, 0);
	input_set_abs_params(input_device, ABS_MT_WIDTH_MAJOR, 0, 200, 0, 0);

	rc = input_register_device(input_device);
	if (rc)
		return rc;

	return 0;
}

static void gsl_release_contacts(struct gsl_ts *ts)
{
	int i;

	for (i = 1; i <= MAX_CONTACTS; i++) {
		input_mt_slot(ts->input, i);
		input_report_abs(ts->input, ABS_MT_TRACKING_ID, -1);
		input_mt_report_slot_state(ts->input, MT_TOOL_FINGER, false);
	}
	input_sync(ts->input);
}

static int rk_ts_early_suspend(struct tp_device *tp_d)
{
	struct gsl_ts *ts = container_of(tp_d, struct gsl_ts, tp);

	disable_irq_nosync(ts->irq);
	gslX680_shutdown_low();

	msleep(10);
	gsl_release_contacts(ts);
	msleep(10);
	report_data(ts, 1, 1, 10, 1);
	input_sync(ts->input);

	return 0;
}

static int rk_ts_early_resume(struct tp_device *tp_d)
{
	struct gsl_ts *ts = container_of(tp_d, struct gsl_ts, tp);

	gslX680_shutdown_high();
	msleep(20);
	reset_chip(ts->client);
	startup_chip(ts->client);
	check_mem_data(ts->client);

	gsl_release_contacts(ts);
	enable_irq(ts->irq);

	return 0;
}

static int gsl_ts_probe(struct i2c_client *client,
			const struct i2c_device_id *id)
{
	struct gsl_ts *ts;
	int rc;
	int timer = 3;
	int ret = 0;
	char buffer = 0;
	struct device_node *np = client->dev.of_node;
	enum of_gpio_flags rst_flags;

	if (!i2c_check_functionality(client->adapter, I2C_FUNC_I2C)) {
		dev_err(&client->dev, "I2C functionality not supported\n");
		return -ENODEV;
	}

	ts = devm_kzalloc(&client->dev, sizeof(*ts), GFP_KERNEL);
	if (!ts)
		return -ENOMEM;

	ts->client = client;
	i2c_set_clientdata(client, ts);
	ts->device_id = 0;
	ts->tp.tp_resume = rk_ts_early_resume;
	ts->tp.tp_suspend = rk_ts_early_suspend;

	ts->irq_pin = of_get_named_gpio(np, "touch-gpio", 0);
	ts->rst_pin = of_get_named_gpio_flags(np, "reset-gpio", 0, &rst_flags);
	if (of_property_read_u32(np, "flip-x", &ts->flip_x) < 0)
		ts->flip_x = 0;

	if (of_property_read_u32(np, "flip-y", &ts->flip_y) < 0)
		ts->flip_y = 0;

	if (of_property_read_u32(np, "swap-xy", &ts->swap_xy) < 0)
		ts->swap_xy = 0;

	if (!gpio_is_valid(ts->irq_pin)) {
		dev_err(&client->dev, "touch-gpio invalid: %d\n", ts->irq_pin);
		return ts->irq_pin < 0 ? ts->irq_pin : -EINVAL;
	}
	ret = devm_gpio_request_one(&client->dev, ts->irq_pin, GPIOF_IN, "gslX680 irq");
	if (ret) {
		dev_err(&client->dev, "touch-gpio request failed: %d\n", ret);
		return ret;
	}

	if (gpio_is_valid(ts->rst_pin)) {
		ret = devm_gpio_request_one(&client->dev, ts->rst_pin,
					    (rst_flags & OF_GPIO_ACTIVE_LOW) ? GPIOF_OUT_INIT_HIGH : GPIOF_OUT_INIT_LOW,
					    "gslX680 reset");
		if (ret != 0) {
			dev_err(&client->dev, "reset-gpio request failed: %d\n", ret);
			return ret;
		}
		gpio_direction_output(ts->rst_pin, 0);
		gpio_set_value(ts->rst_pin, GPIO_HIGH);
		msleep(20);
	} else {
		dev_info(&client->dev, "reset pin invalid\n");
	}
	while (timer > 0) {
		ret = i2c_master_recv(client, &buffer, 1);
		if (ret >= 0)
			break;
		timer--;
		msleep(100);
	}

	if (ret < 0) {
		dev_err(&client->dev, "no response from touch controller at 0x40: %d\n", ret);
		return ret;
	}

	gts = ts;

	rc = gslX680_ts_init(client, ts);
	if (rc < 0) {
		dev_err(&client->dev, "GSLX680 init failed\n");
		return rc;
	}

	init_chip(ts->client);
	check_mem_data(ts->client);

	ts->irq = gpio_to_irq(ts->irq_pin);
	if (ts->irq < 0) {
		dev_err(&client->dev, "no irq for touch-gpio: %d\n", ts->irq);
		return ts->irq;
	}
	/*
	 * INT idles low and goes high when a frame is ready, so trigger
	 * on the rising edge like the stock kernel.  The flag cell of
	 * touch-gpio (8 = level-low in the reference DT) would keep the
	 * line asserted while idle and make the worker read stale frames.
	 */
	rc = devm_request_threaded_irq(&client->dev, ts->irq, NULL,
				       gsl_ts_irq, IRQF_TRIGGER_RISING | IRQF_ONESHOT,
				       client->name, ts);
	if (rc != 0) {
		dev_err(&client->dev, "request irq %d failed: %d\n", ts->irq, rc);
		return rc;
	}

	tp_register_fb(&ts->tp);

	return 0;
}

static void gsl_ts_remove(struct i2c_client *client)
{
	struct gsl_ts *ts = i2c_get_clientdata(client);

	tp_unregister_fb(&ts->tp);
}

static const struct i2c_device_id gsl_ts_id[] = {
	{GSLX680_I2C_NAME, 0},
	{}
};
MODULE_DEVICE_TABLE(i2c, gsl_ts_id);

static const struct of_device_id gsl_ts_dt_ids[] = {
	{ .compatible = "gslX680" },
	{ }
};
MODULE_DEVICE_TABLE(of, gsl_ts_dt_ids);

static struct i2c_driver gsl_ts_driver = {
	.driver = {
		.name = GSLX680_I2C_NAME,
		.of_match_table = gsl_ts_dt_ids,
	},
	.probe		= gsl_ts_probe,
	.remove		= gsl_ts_remove,
	.id_table	= gsl_ts_id,
};

module_i2c_driver(gsl_ts_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("GSLX680 touchscreen controller driver");
