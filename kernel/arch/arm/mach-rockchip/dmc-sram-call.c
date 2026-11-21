// SPDX-License-Identifier: GPL-2.0
/*
 * Built-in half of the RK3288 DMC driver (drivers/devfreq/rockchip/).
 *
 * The DDR rate change runs from on-chip SRAM with the MMU off. That needs the
 * identity map (call_with_mmu_disabled lives in .idmap.text) and arch MMU
 * helpers that are not exported to modules, and the SRAM code blob is linked
 * into vmlinux. Nothing here runs unless the DMC driver calls it.
 */

#include <linux/export.h>
#include <linux/io.h>
#include <linux/sched.h>
#include <asm/idmap.h>
#include <asm/memory.h>
#include <asm/mmu_context.h>
#include <asm/tlbflush.h>
#include <soc/rockchip/rk3288-dmc-sram.h>

extern char _binary_arch_arm_mach_rockchip_embedded_rk3288_sram_bin_start[];
extern char _binary_arch_arm_mach_rockchip_embedded_rk3288_sram_bin_end[];
extern void call_with_mmu_disabled(void (*fn)(void *), void *arg, void *sp);

/**
 * rk3288_dmc_sram_blob - the SRAM code blob linked into vmlinux
 * @size: set to the blob size in bytes
 */
const void *rk3288_dmc_sram_blob(size_t *size)
{
	*size = _binary_arch_arm_mach_rockchip_embedded_rk3288_sram_bin_end -
		_binary_arch_arm_mach_rockchip_embedded_rk3288_sram_bin_start;
	return _binary_arch_arm_mach_rockchip_embedded_rk3288_sram_bin_start;
}
EXPORT_SYMBOL_GPL(rk3288_dmc_sram_blob);

/**
 * rk3288_dmc_map_sram - map on-chip SRAM uncached and executable
 * @start: physical start address
 * @size: size in bytes
 */
void __iomem *rk3288_dmc_map_sram(phys_addr_t start, size_t size)
{
	return __arm_ioremap_exec(start, size, false);
}
EXPORT_SYMBOL_GPL(rk3288_dmc_map_sram);

/*
 * idmap_pgd was copied from init_mm early at boot. With CONFIG_VMAP_STACK the
 * caller's stack lives in vmalloc space, whose top level entries are added to
 * init_mm later and synced into an mm only by switch_mm (check_vmalloc_seq).
 * setup_mm_for_reboot() switches to idmap_pgd directly, so without this the
 * first stack access after the switch faults, and the abort handler overflows
 * the stack it cannot reach. Same copy as memcpy_pgd() in arch/arm/mm/ioremap.c.
 */
static void rk3288_dmc_sync_idmap_vmalloc(void)
{
	unsigned long end = ALIGN(VMALLOC_END, PGDIR_SIZE);

	memcpy(pgd_offset_pgd(idmap_pgd, VMALLOC_START), pgd_offset_k(VMALLOC_START),
	       sizeof(pgd_t) * (pgd_index(end) - pgd_index(VMALLOC_START)));
}

/**
 * rk3288_dmc_call_sram - call @fn at a physical address with the MMU off
 * @fn: physical address of the function (in SRAM)
 * @arg: argument passed to @fn
 * @sp: physical address of the stack top to use (in SRAM)
 *
 * Switches to the identity map, turns the MMU off, calls @fn, turns the MMU
 * back on and restores the caller's page tables.
 */
void rk3288_dmc_call_sram(void (*fn)(void *), void *arg, void *sp)
{
	struct mm_struct *saved_mm = current->active_mm;
	void (*call)(void (*fn)(void *), void *arg, void *sp) =
		(void *)(unsigned long)virt_to_phys(call_with_mmu_disabled);

	rk3288_dmc_sync_idmap_vmalloc();
	setup_mm_for_reboot();
	call(fn, arg, sp);
	cpu_switch_mm(saved_mm->pgd, saved_mm);
	local_flush_bp_all();
	local_flush_tlb_all();
}
EXPORT_SYMBOL_GPL(rk3288_dmc_call_sram);
