/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_RK_WDT_BACKSTOP_H
#define _LINUX_RK_WDT_BACKSTOP_H

#ifdef CONFIG_RK_WDT_BACKSTOP
void rk_wdt_backstop_arm(void);
#else
static inline void rk_wdt_backstop_arm(void) { }
#endif

#endif /* _LINUX_RK_WDT_BACKSTOP_H */
