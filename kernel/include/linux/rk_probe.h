/* SPDX-License-Identifier: GPL-2.0 */
/*
 * RK3288 bring-up checkpoint probes (debug only, CONFIG_RK_PROBE_POINTS).
 *
 * rk_probe_point(n) is a no-op unless n equals the "rkprobe=" kernel
 * command line value. The selected point writes the rockusb loader flag,
 * issues a CRU global soft reset and spins, so the board re-enumerates
 * as 2207:0011 only if the kernel reached that point.
 */
#ifndef _LINUX_RK_PROBE_H
#define _LINUX_RK_PROBE_H

#ifdef CONFIG_RK_PROBE_POINTS
void rk_probe_point(int n);
#else
static inline void rk_probe_point(int n) { }
#endif

#endif /* _LINUX_RK_PROBE_H */
