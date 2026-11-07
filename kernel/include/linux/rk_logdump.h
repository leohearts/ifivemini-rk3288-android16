/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_RK_LOGDUMP_H
#define _LINUX_RK_LOGDUMP_H

#ifdef CONFIG_RK_LOGDUMP
/*
 * Write the printk ring buffer plus a short reason string to the "kpanic"
 * partition (RKLOGDP1 format). Safe from process context only. Does nothing
 * if the partition is missing or is not exactly 4 MiB.
 */
void rk_logdump_to_kpanic(const char *reason);
int rk_logdump_stage(void);
int rk_logdump_disks(void);
#else
static inline void rk_logdump_to_kpanic(const char *reason) { }
static inline int rk_logdump_stage(void) { return 0; }
static inline int rk_logdump_disks(void) { return 0; }
#endif

#endif /* _LINUX_RK_LOGDUMP_H */
