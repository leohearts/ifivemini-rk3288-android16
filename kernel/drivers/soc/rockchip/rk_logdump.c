// SPDX-License-Identifier: GPL-2.0
/*
 * Dump the kernel log to the "kpanic" partition so the host can read it
 * back with rkdeveloptool rl.
 *
 * Layout written to the partition (all integers little endian):
 *   0x000  "RKLOGDP1"           magic
 *   0x008  u32 version          = 2
 *   0x00c  u32 reason_off       = 512
 *   0x010  u32 reason_len       bytes of reason, excluding NUL
 *   0x014  u32 log_buf_len      size of the printk ring buffer
 *   0x018  u32 payload_len      raw log bytes that follow the header
 *   0x01c  u32 payload_off      = 1024
 *   0x020  u64 local_clock()    ns at dump time
 *   0x028  u32 sect_off         offset of the first section (512-aligned)
 *   0x02c  u32 sect_len         bytes of all sections, padding included
 *   0x030  u32 seq              periodic dump counter, 1.. (0 = one-shot dump)
 *   0x034  u32 reserved         0
 *   0x038  u64 uptime_ns        boottime (ktime_get_boottime) at dump time
 *   0x200  reason string, NUL terminated, zero padded to 512 bytes
 *   0x400  raw printk_log ring buffer (payload_len bytes)
 *   sect_off: sections, each a 512-byte sub-header followed by its data
 *             rounded up to 512 bytes:
 *     "RKRAMOP1"  raw ramoops reserved region (this boot's view: the
 *                 console zone is appended to by the new boot)
 *     "RKPREVC1"  previous boot's console text (pstore console zone
 *                 old_log, i.e. the snapshot taken when ramoops probed)
 *   Sub-header (little endian):
 *     0x00 magic[8]  0x08 u32 version = 1  0x0c u32 reserved
 *     0x10 u64 phys (RKRAMOP1 only; 0 for RKPREVC1)
 *     0x18 u32 data_len   bytes stored after this header (may be < total)
 *     0x1c u32 total_len  original size; data_len < total_len = truncated
 * data_len = 0 with total_len = 0 means the source is absent.
 */
#include <asm/unaligned.h>
#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/genhd.h>
#include <linux/io.h>
#include <linux/kconfig.h>
#include <linux/kthread.h>
#include <linux/init.h>
#include <linux/mutex.h>
#include <linux/printk.h>
#include <linux/reboot.h>
#include <linux/rk_logdump.h>
#include <linux/sched/clock.h>
#include <linux/string.h>
#include <linux/time.h>
#include <linux/timekeeping.h>

#if IS_BUILTIN(CONFIG_PSTORE_RAM)
#include <linux/pstore_ram.h>

static bool rkld_pstore_region(phys_addr_t *phys, size_t *size)
{
	return pstore_ram_region(phys, size);
}

static const char *rkld_prev_console(size_t *len)
{
	return pstore_ram_prev_console(len);
}
#else
/* ramoops built as a module (or absent): no raw/previous-console sections. */
static bool rkld_pstore_region(phys_addr_t *phys, size_t *size)
{
	return false;
}

static const char *rkld_prev_console(size_t *len)
{
	*len = 0;
	return NULL;
}
#endif

#define RKLD_PART_NAME		"kpanic"
#define RKLD_PART_BYTES		(4 * 1024 * 1024)
#define RKLD_HDR_SIZE		512
#define RKLD_REASON_OFF		512
#define RKLD_REASON_AREA	512
#define RKLD_PRE_SIZE		(RKLD_HDR_SIZE + RKLD_REASON_AREA)
#define RKLD_SECT_HDR		512
#define RKLD_RAM_MAX		(1024 * 1024)
#define RKLD_PREV_MAX		(1024 * 1024)
#define RKLD_SECTS_MAX		(2 * RKLD_SECT_HDR + RKLD_RAM_MAX + RKLD_PREV_MAX)
/* Leaves room for the 512-byte alignment of sect_off. */
#define RKLD_PAYLOAD_MAX	(RKLD_PART_BYTES - RKLD_PRE_SIZE - RKLD_SECTS_MAX - RKLD_HDR_SIZE)
#define RKLD_CHUNK_PAGES	64
#define RKLD_MAX_SEGS		6	/* pre, log, sect_ram, ram, sect_prev, prev */
#define RKLD_FIND_WAIT_MS	15000	/* poll for kpanic this long before giving up */
#define RKLD_RETRY_MS		500	/* kpanic poll interval of the periodic dump */

/* One contiguous source range placed at image offset @off. */
struct rkld_seg {
	const u8 *src;
	size_t off;
	size_t len;
};

/* rklogdump_test=<N> on the kernel command line; 0 = off. */
static int rklogdump_test;
/* rklogdump_period=<sec>: rewrite kpanic every N s, 0 = off. */
static unsigned int rklogdump_period = CONFIG_RK_LOGDUMP_PERIOD_DEFAULT;
/* rklogdump_restart=1: test only. After a dump with no previous console
 * data (first boot of a QEMU session), reboot once so the next boot has a
 * previous console to dump. */
static int rklogdump_restart;
/* rklogmark=<str>: test only. Printed at init so the next boot's previous
 * console section can be checked for it. */
static char rklogmark[64];

static DEFINE_MUTEX(rkld_lock);
/* Set when the last rk_logdump_to_kpanic() wrote the partition. */
static bool rkld_last_ok;
/* rkldsig=1: test only. After a rklogdump_test/rkdeadline dump, reset after
 * S*6 s with IRQs off, S = rkld_stage (1 part not found, 2 size refusal,
 * 3 bio error, 4 ok, 5 other). Lets the next boot's kpanic read tell the result. */
static int rkldsig;
/* Result of the last dump attempt; see rkldsig above. */
static int rkld_stage = 5;

static dev_t rkld_find_kpanic(void)
{
	struct class_dev_iter iter;
	struct device *dev;
	dev_t devt = 0;

	class_dev_iter_init(&iter, &block_class, NULL, NULL);
	while ((dev = class_dev_iter_next(&iter))) {
		struct hd_struct *part = dev_to_part(dev);

		if (!part->info)
			continue;
		if (strcmp(part->info->volname, RKLD_PART_NAME))
			continue;
		devt = dev->devt;
		break;
	}
	class_dev_iter_exit(&iter);
	return devt;
}

/* True if a block device (whole disk or partition) has this name. */
static bool rkld_disk_named(const char *name)
{
	struct class_dev_iter iter;
	struct device *dev;
	bool found = false;

	class_dev_iter_init(&iter, &block_class, NULL, NULL);
	while ((dev = class_dev_iter_next(&iter))) {
		if (!strcmp(dev_name(dev), name)) {
			found = true;
			break;
		}
	}
	class_dev_iter_exit(&iter);
	return found;
}

/* Whole disks registered in block_class (partitions have partno != 0). */
static int rkld_count_disks(void)
{
	struct class_dev_iter iter;
	struct device *dev;
	int n = 0;

	class_dev_iter_init(&iter, &block_class, NULL, NULL);
	while ((dev = class_dev_iter_next(&iter))) {
		if (dev_to_part(dev)->partno == 0)
			n++;
	}
	class_dev_iter_exit(&iter);
	return n;
}

/* Fill dst with image bytes [pos, pos+n); bytes not covered by a segment are 0. */
static void rkld_image_read(u8 *dst, size_t pos, size_t n,
			    const struct rkld_seg *seg, int nseg)
{
	int i;

	memset(dst, 0, n);
	for (i = 0; i < nseg; i++) {
		size_t s = seg[i].off, e = seg[i].off + seg[i].len;
		size_t a = max(pos, s), b = min(pos + n, e);

		if (a < b)
			memcpy(dst + (a - pos), seg[i].src + (a - s), b - a);
	}
}

static int rkld_write_part(dev_t devt, const struct rkld_seg *seg, int nseg,
			   size_t image_len)
{
	struct block_device *bdev;
	struct page *pages[RKLD_CHUNK_PAGES] = { };
	size_t total, pos = 0;
	int i, ret = 0;

	bdev = blkdev_get_by_dev(devt, FMODE_READ | FMODE_WRITE, NULL);
	if (IS_ERR(bdev))
		return PTR_ERR(bdev);

	if (part_nr_sects_read(bdev->bd_part) * 512ULL != RKLD_PART_BYTES) {
		pr_err("rk_logdump: %s is not 4 MiB, refusing\n", RKLD_PART_NAME);
		rkld_stage = 2;
		ret = -EINVAL;
		goto out_put;
	}

	for (i = 0; i < RKLD_CHUNK_PAGES; i++) {
		pages[i] = alloc_page(GFP_KERNEL);
		if (!pages[i]) {
			ret = -ENOMEM;
			goto out_free;
		}
	}

	total = roundup(image_len, PAGE_SIZE);
	if (total > RKLD_PART_BYTES)
		total = RKLD_PART_BYTES;

	while (pos < total) {
		size_t chunk = min_t(size_t, total - pos,
				     RKLD_CHUNK_PAGES * PAGE_SIZE);
		size_t npages = chunk / PAGE_SIZE;
		struct bio *bio;
		size_t p;

		for (p = 0; p < npages; p++) {
			void *va = kmap(pages[p]);

			rkld_image_read(va, pos + p * PAGE_SIZE, PAGE_SIZE,
					seg, nseg);
			kunmap(pages[p]);
		}

		bio = bio_alloc(GFP_KERNEL, npages);
		if (!bio) {
			ret = -ENOMEM;
			goto out_free;
		}
		bio_set_dev(bio, bdev);
		bio->bi_iter.bi_sector = pos >> 9;	/* partition relative */
		bio->bi_opf = REQ_OP_WRITE | REQ_SYNC | REQ_FUA;
		if (!pos)
			bio->bi_opf |= REQ_PREFLUSH;
		for (p = 0; p < npages; p++)
			bio_add_page(bio, pages[p], PAGE_SIZE, 0);

		ret = submit_bio_wait(bio);
		bio_put(bio);
		if (ret) {
			rkld_stage = 3;
			goto out_free;
		}
		pos += chunk;
	}
	if (!ret) {
		ret = blkdev_issue_flush(bdev, GFP_KERNEL, NULL);
		if (ret)
			rkld_stage = 3;
	}

out_free:
	for (i = 0; i < RKLD_CHUNK_PAGES; i++)
		if (pages[i])
			__free_page(pages[i]);
out_put:
	blkdev_put(bdev, FMODE_READ | FMODE_WRITE);
	return ret;
}

/*
 * Map [phys, phys+size) of RAM with vmap(), as pstore does. memremap() is
 * not used: on highmem RAM it returns a mapping that faults on access.
 * Returns the mapping base (vunmap()) or NULL; *va is the data start.
 */
static void *rkld_map_ram(phys_addr_t phys, size_t size, void **va)
{
	phys_addr_t base = phys & PAGE_MASK;
	unsigned long npages = DIV_ROUND_UP(phys + size - base, PAGE_SIZE);
	struct page **pages;
	void *map = NULL;
	unsigned long i;

	pages = kmalloc_array(npages, sizeof(*pages), GFP_KERNEL);
	if (!pages)
		return NULL;
	for (i = 0; i < npages; i++) {
		unsigned long pfn = (base >> PAGE_SHIFT) + i;

		if (!pfn_valid(pfn))
			goto out;
		pages[i] = pfn_to_page(pfn);
	}
	map = vmap(pages, npages, VM_MAP, PAGE_KERNEL);
	if (map)
		*va = (u8 *)map + (phys - base);
out:
	kfree(pages);
	return map;
}

/* Fill one 512-byte section sub-header. */
static void rkld_sect_hdr(u8 *h, const char *magic, u64 phys,
			  size_t data_len, size_t total_len)
{
	memset(h, 0, RKLD_SECT_HDR);
	memcpy(h, magic, 8);
	put_unaligned_le32(1, h + 8);
	put_unaligned_le64(phys, h + 0x10);
	put_unaligned_le32(data_len, h + 0x18);
	put_unaligned_le32(total_len, h + 0x1c);
}

/*
 * rkldsig: encode rkld_stage as a reset delay. Hold S*6 s with IRQs off, then
 * use the same reset as rk_probe_points (loader flag, then CRU_GLB_SRST_FST).
 */
static void rkld_signal_reset(void)
{
	void __iomem *pmu = ioremap(0xff730000, PAGE_SIZE);
	void __iomem *cru = ioremap(0xff760000, PAGE_SIZE);
	unsigned int ms = rkld_stage * 6000;

	pr_emerg("rk_logdump: rkldsig stage %d, holding %u ms then reset\n",
		 rkld_stage, ms);
	local_irq_disable();
	mdelay(ms);
	if (pmu)
		writel(0x5242C301, pmu + 0x94);
	if (cru)
		writel(0xFDB9, cru + 0x1b0);
	for (;;)
		cpu_relax();
}

int rk_logdump_stage(void)
{
	return rkld_stage;
}

int rk_logdump_disks(void)
{
	return rkld_count_disks();
}

/*
 * Write one image to kpanic: header, reason, printk ring and, if @sections,
 * the ramoops and previous-console sections. Caller holds rkld_lock.
 * Returns 0 or the write error.
 */
static int rkld_dump(dev_t devt, const char *reason, u32 seq, bool sections)
{
	static u8 pre[RKLD_PRE_SIZE];
	static u8 sect_ram[RKLD_SECT_HDR], sect_prev[RKLD_SECT_HDR];
	struct rkld_seg seg[RKLD_MAX_SEGS];
	const char *log, *prev = NULL;
	phys_addr_t ram_phys = 0;
	size_t loglen, payload_len, rlen, ram_total = 0, ram_len = 0;
	size_t prev_total = 0, prev_len = 0;
	size_t sect_off, ram_hdr = 0, prev_hdr = 0, sect_end, image_len;
	void *ram_va = NULL, *ram_map = NULL;
	int nseg = 0;
	int ret = 0;

	log = log_buf_addr_get();
	loglen = log_buf_len_get();
	payload_len = min_t(size_t, loglen, RKLD_PAYLOAD_MAX);
	sect_off = roundup(RKLD_PRE_SIZE + payload_len, RKLD_SECT_HDR);
	sect_end = sect_off;

	/* Sections: raw ramoops region, then previous boot's console. */
	if (sections) {
		if (rkld_pstore_region(&ram_phys, &ram_total)) {
			ram_len = min_t(size_t, ram_total, RKLD_RAM_MAX);
			ram_map = rkld_map_ram(ram_phys, ram_len, &ram_va);
			if (!ram_map) {
				pr_warn("rk_logdump: map of ramoops %pa failed\n",
					&ram_phys);
				ram_len = 0;
			}
		} else {
			ram_total = 0;
		}

		prev = rkld_prev_console(&prev_total);
		if (prev)
			prev_len = min_t(size_t, prev_total, RKLD_PREV_MAX);
		else
			prev_total = 0;

		ram_hdr = sect_off;
		prev_hdr = ram_hdr + RKLD_SECT_HDR + roundup(ram_len, RKLD_SECT_HDR);
		sect_end = prev_hdr + RKLD_SECT_HDR + roundup(prev_len, RKLD_SECT_HDR);
		if (sect_end > RKLD_PART_BYTES) {
			pr_err("rk_logdump: image %zu bytes exceeds %s\n",
			       sect_end, RKLD_PART_NAME);
			ret = -EFBIG;
			goto out_unmap;
		}

		rkld_sect_hdr(sect_ram, "RKRAMOP1", ram_phys, ram_len, ram_total);
		rkld_sect_hdr(sect_prev, "RKPREVC1", 0, prev_len, prev_total);
	}

	memset(pre, 0, sizeof(pre));
	memcpy(pre, "RKLOGDP1", 8);
	put_unaligned_le32(2, pre + 8);
	put_unaligned_le32(RKLD_REASON_OFF, pre + 12);
	rlen = reason ? min_t(size_t, strlen(reason), RKLD_REASON_AREA - 1) : 0;
	if (rlen)
		memcpy(pre + RKLD_REASON_OFF, reason, rlen);
	put_unaligned_le32(rlen, pre + 16);
	put_unaligned_le32(loglen, pre + 20);
	put_unaligned_le32(payload_len, pre + 24);
	put_unaligned_le32(RKLD_PRE_SIZE, pre + 28);
	put_unaligned_le64(local_clock(), pre + 32);
	put_unaligned_le32(sect_off, pre + 0x28);
	put_unaligned_le32(sect_end - sect_off, pre + 0x2c);
	put_unaligned_le32(seq, pre + 0x30);
	put_unaligned_le64(ktime_to_ns(ktime_get_boottime()), pre + 0x38);

	seg[nseg++] = (struct rkld_seg){ pre, 0, RKLD_PRE_SIZE };
	seg[nseg++] = (struct rkld_seg){ (const u8 *)log, RKLD_PRE_SIZE,
					 payload_len };
	if (sections) {
		seg[nseg++] = (struct rkld_seg){ sect_ram, ram_hdr, RKLD_SECT_HDR };
		if (ram_len)
			seg[nseg++] = (struct rkld_seg){ ram_va, ram_hdr + RKLD_SECT_HDR,
							 ram_len };
		seg[nseg++] = (struct rkld_seg){ sect_prev, prev_hdr, RKLD_SECT_HDR };
		if (prev_len)
			seg[nseg++] = (struct rkld_seg){ (const u8 *)prev,
							 prev_hdr + RKLD_SECT_HDR,
							 prev_len };
	}

	image_len = sect_end;
	ret = rkld_write_part(devt, seg, nseg, image_len);
	if (ret) {
		if (sections)
			pr_err("rk_logdump: write to %s failed: %d\n",
			       RKLD_PART_NAME, ret);
		else
			pr_err_ratelimited("rk_logdump: periodic write to %s failed: %d\n",
					   RKLD_PART_NAME, ret);
	} else {
		rkld_last_ok = true;
		rkld_stage = 4;
		if (sections)
			pr_info("rk_logdump: wrote log %zu, ramoops %zu/%zu @%pa, previous console %zu/%zu to %s\n",
				payload_len, ram_len, ram_total, &ram_phys,
				prev_len, prev_total, RKLD_PART_NAME);
	}

out_unmap:
	if (ram_map)
		vunmap(ram_map);
	return ret;
}

void rk_logdump_to_kpanic(const char *reason)
{
	dev_t devt;
	int waited;

	mutex_lock(&rkld_lock);
	rkld_last_ok = false;

	devt = rkld_find_kpanic();
	for (waited = 0; !devt && waited < RKLD_FIND_WAIT_MS; waited += 100) {
		msleep(100);
		devt = rkld_find_kpanic();
	}
	if (!devt) {
		pr_err("rk_logdump: partition %s not found after %d ms (eMMC not probed?)\n",
		       RKLD_PART_NAME, RKLD_FIND_WAIT_MS);
		rkld_stage = rkld_disk_named("mmcblk0") ? 1 : 6;
	} else {
		rkld_stage = 5;
		rkld_dump(devt, reason, 0, true);
	}

	if (rkldsig && reason && (!strcmp(reason, "rklogdump_test") || !strcmp(reason, "rkdeadline")))
		rkld_signal_reset();
	mutex_unlock(&rkld_lock);
}

/*
 * rklogdump_period=<sec>: every period, rewrite the kpanic header and the
 * printk ring (no sections, so only pre + payload bytes are written) with a
 * new seq. Polls for kpanic every RKLD_RETRY_MS until it appears, so it runs
 * from boot without userspace and never writes outside the partition.
 */
static int rkld_period_thread(void *unused)
{
	u32 seq = 0;
	bool missing = true;

	while (!kthread_should_stop()) {
		unsigned int wait_ms = RKLD_RETRY_MS;
		dev_t devt;
		int ret;

		mutex_lock(&rkld_lock);
		devt = rkld_find_kpanic();
		if (!devt) {
			if (!missing)
				pr_err("rk_logdump: periodic: %s not found\n",
				       RKLD_PART_NAME);
			missing = true;
		} else {
			missing = false;
			if (!seq)
				pr_info("rk_logdump: periodic dump every %u s to %s\n",
					rklogdump_period, RKLD_PART_NAME);
			ret = rkld_dump(devt, "periodic", ++seq, false);
			if (ret)
				pr_err("rk_logdump: periodic seq %u write failed: %d (stage %d)\n",
				       seq, ret, rkld_stage);
			wait_ms = rklogdump_period * 1000;
		}
		mutex_unlock(&rkld_lock);
		msleep(wait_ms);
	}
	return 0;
}

static int rkld_test_thread(void *unused)
{
	size_t prev_total;

	while (!kthread_should_stop() && ktime_get_seconds() < rklogdump_test)
		msleep(100);
	if (kthread_should_stop())
		return 0;

	rk_logdump_to_kpanic("rklogdump_test");

	/* Read after the dump: the first boot of a session has no previous console. */
	rkld_prev_console(&prev_total);
	if (rklogdump_restart && rkld_last_ok && !prev_total) {
		pr_info("rk_logdump: test restart (no previous console)\n");
		kernel_restart(NULL);
	}
	return 0;
}

static int __init rklogdump_test_setup(char *str)
{
	if (kstrtoint(str, 0, &rklogdump_test))
		pr_warn("rk_logdump: ignoring bad rklogdump_test=%s\n", str);
	return 1;
}
__setup("rklogdump_test=", rklogdump_test_setup);

static int __init rklogdump_restart_setup(char *str)
{
	if (kstrtoint(str, 0, &rklogdump_restart))
		pr_warn("rk_logdump: ignoring bad rklogdump_restart=%s\n", str);
	return 1;
}
__setup("rklogdump_restart=", rklogdump_restart_setup);

static int __init rklogmark_setup(char *str)
{
	strlcpy(rklogmark, str, sizeof(rklogmark));
	return 1;
}
__setup("rklogmark=", rklogmark_setup);

static int __init rkldsig_setup(char *str)
{
	if (kstrtoint(str, 0, &rkldsig))
		pr_warn("rk_logdump: ignoring bad rkldsig=%s\n", str);
	return 1;
}
__setup("rkldsig=", rkldsig_setup);

/*
 * Returning 1 consumes the option either way, so a malformed value is
 * dropped (period keeps its default) instead of reaching init as an argument.
 */
static int __init rklogdump_period_setup(char *str)
{
	unsigned int v;

	if (kstrtouint(str, 0, &v) || v > 3600) {
		pr_warn("rk_logdump: ignoring bad rklogdump_period=%s (0..3600)\n", str);
		return 1;
	}
	rklogdump_period = v;
	return 1;
}
__setup("rklogdump_period=", rklogdump_period_setup);

/*
 * Reboot notifiers run in process context from kernel_restart_prepare() /
 * kernel_power_off(), before device_shutdown(), so eMMC is still usable and
 * the sleeping dump path is allowed. Dump once even if called again.
 */
static int rkld_reboot_notify(struct notifier_block *nb, unsigned long event,
			      void *data)
{
	static atomic_t done = ATOMIC_INIT(0);

	if (atomic_xchg(&done, 1))
		return NOTIFY_DONE;
	rk_logdump_to_kpanic(event == SYS_RESTART ? "restart" : "poweroff");
	return NOTIFY_DONE;
}

static struct notifier_block rkld_reboot_nb = {
	.notifier_call	= rkld_reboot_notify,
};

static int __init rk_logdump_init(void)
{
	if (rklogmark[0])
		pr_info("rk_logdump: marker %s\n", rklogmark);
	if (rklogdump_test > 0)
		kthread_run(rkld_test_thread, NULL, "rklogdump_test");
	if (rklogdump_period)
		kthread_run(rkld_period_thread, NULL, "rklogdump_period");
	register_reboot_notifier(&rkld_reboot_nb);
	return 0;
}
late_initcall(rk_logdump_init);
