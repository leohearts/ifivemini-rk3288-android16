// SPDX-License-Identifier: GPL-2.0
/*
 * misc.c
 * 
 * This is a collection of several routines from gzip-1.0.3 
 * adapted for Linux.
 *
 * malloc by Hannu Savolainen 1993 and Matthias Urlichs 1994
 *
 * Modified for ARM Linux by Russell King
 *
 * Nicolas Pitre <nico@visuaide.com>  1999/04/14 :
 *  For this code to run directly from Flash, all constant variables must
 *  be marked with 'const' and all other variables initialized at run-time 
 *  only.  This way all non constant variables will end up in the bss segment,
 *  which should point to addresses in RAM and cleared to 0 on start.
 *  This allows for a much quicker boot time.
 */

unsigned int __machine_arch_type;

#include <linux/compiler.h>	/* for inline */
#include <linux/types.h>
#include <linux/linkage.h>
#include "misc.h"
#ifdef CONFIG_ARCH_EP93XX
#include "misc-ep93xx.h"
#endif

static void putstr(const char *ptr);

#include CONFIG_UNCOMPRESS_INCLUDE

#ifdef CONFIG_DEBUG_ICEDCC

#if defined(CONFIG_CPU_V6) || defined(CONFIG_CPU_V6K) || defined(CONFIG_CPU_V7)

static void icedcc_putc(int ch)
{
	int status, i = 0x4000000;

	do {
		if (--i < 0)
			return;

		asm volatile ("mrc p14, 0, %0, c0, c1, 0" : "=r" (status));
	} while (status & (1 << 29));

	asm("mcr p14, 0, %0, c0, c5, 0" : : "r" (ch));
}


#elif defined(CONFIG_CPU_XSCALE)

static void icedcc_putc(int ch)
{
	int status, i = 0x4000000;

	do {
		if (--i < 0)
			return;

		asm volatile ("mrc p14, 0, %0, c14, c0, 0" : "=r" (status));
	} while (status & (1 << 28));

	asm("mcr p14, 0, %0, c8, c0, 0" : : "r" (ch));
}

#else

static void icedcc_putc(int ch)
{
	int status, i = 0x4000000;

	do {
		if (--i < 0)
			return;

		asm volatile ("mrc p14, 0, %0, c0, c0, 0" : "=r" (status));
	} while (status & 2);

	asm("mcr p14, 0, %0, c1, c0, 0" : : "r" (ch));
}

#endif

#define putc(ch)	icedcc_putc(ch)
#endif

static void putstr(const char *ptr)
{
	char c;

	while ((c = *ptr++) != '\0') {
		if (c == '\n')
			putc('\r');
		putc(c);
	}

	flush();
}

/*
 * gzip declarations
 */
extern char input_data[];
extern char input_data_end[];

unsigned char *output_data;

unsigned long free_mem_ptr;
unsigned long free_mem_end_ptr;

#ifndef arch_error
#define arch_error(x)
#endif

void error(char *x)
{
	arch_error(x);

	putstr("\n\n");
	putstr(x);
	putstr("\n\n -- System halted");

	while(1);	/* Halt */
}

asmlinkage void __div0(void)
{
	error("Attempting division by 0!");
}

extern int do_decompress(u8 *input, int len, u8 *output, void (*error)(char *x));


#ifdef CONFIG_RK3288_DECOMP_WDT
/*
 * RK3288 bring-up safety net, run before the kernel is unpacked (MMU off or
 * 1:1, so physical addresses). Writes the rockusb loader flag and starts the
 * SoC watchdog with the values rk_wdt_backstop uses (SGRF pclk gate opened
 * first, TOP 14, RPL 2, system reset), so a hang anywhere before
 * rk_wdt_backstop_arm() takes over resets the board into Loader mode.
 * RK3288_DECOMP_PROBE resets into Loader right here instead.
 */
#define RK_PMU_SYS_REG0		((volatile u32 *)0xff730094)
#define RK_SGRF_SOC_CON0	((volatile u32 *)0xff740000)
#define RK_CRU_GLB_SRST_FST	((volatile u32 *)0xff7601b0)
#define RK_WDT_CR		((volatile u32 *)0xff800000)
#define RK_WDT_TORR		((volatile u32 *)0xff800004)
#define RK_WDT_CRR		((volatile u32 *)0xff80000c)

static void rk3288_decomp_wdt(void)
{
	*RK_PMU_SYS_REG0 = 0x5242c301;
#ifdef CONFIG_RK3288_DECOMP_PROBE
	*RK_CRU_GLB_SRST_FST = 0xfdb9;
	for (;;)
		;
#endif
	*RK_SGRF_SOC_CON0 = 0x00420000;
	/* An APB access to a gated WDT hangs: only touch it once ungated. */
	if (*RK_SGRF_SOC_CON0 & ((1 << 6) | (1 << 1)))
		return;
	*RK_WDT_TORR = 14;
	*RK_WDT_CRR = 0x76;
	*RK_WDT_CR = 1 | (2 << 2);
}
#endif

void
decompress_kernel(unsigned long output_start, unsigned long free_mem_ptr_p,
		unsigned long free_mem_ptr_end_p,
		int arch_id)
{
	int ret;

	output_data		= (unsigned char *)output_start;
	free_mem_ptr		= free_mem_ptr_p;
	free_mem_end_ptr	= free_mem_ptr_end_p;
	__machine_arch_type	= arch_id;

#ifdef CONFIG_ARCH_EP93XX
	ep93xx_decomp_setup();
#endif
#ifdef CONFIG_RK3288_DECOMP_WDT
	rk3288_decomp_wdt();
#endif
	arch_decomp_setup();

	putstr("Uncompressing Linux...");
	ret = do_decompress(input_data, input_data_end - input_data,
			    output_data, error);
	if (ret)
		error("decompressor returned an error");
	else
		putstr(" done, booting the kernel.\n");
}

void fortify_panic(const char *name)
{
	error("detected buffer overflow");
}
