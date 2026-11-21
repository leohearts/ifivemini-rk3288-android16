# SPDX-License-Identifier: GPL-2.0
# Makefile for embedded code blobs for Rockchip SoCs
#
# These code blobs are emedded into vmlinux and copied into SRAM
# at times when SDRAM is not available.  Each blob is self contained.
#
# Some blobs may be linked to expect to run at a very specific address.
# A good example is resume code blobs that always expect to run in a
# very specific bit of SRAM that keeps power during sleep.  This code
# is also running with the cache off so it can predict the address it
# will be at.
#
# Other blobs may be linked with -fpic (by adding CFLAGS_file.o := -fpic).
# These can be located anywhere.  I believe gcc will support this by
# assuming that the .text and .data sections are relative to each other.
#
# That brings up the point that all blobs here:
# - Are generally very small
# - Generally have code and data jammed together in one blob.
# - Generally have "parameters" at the beginning that are filled in by
#   the kernel.

# The resume blob is copied to PMU SRAM by ../pm.c for deep sleep. The DMC
# SRAM blob is linked into vmlinux even when the DMC driver is a module, so
# that the module can load it.
obj-$(CONFIG_PM_SLEEP) += rk3288_resume.bin.o
obj-$(subst m,y,$(CONFIG_ARM_RK3288_DMC_DEVFREQ)) += rk3288_sram.bin.o

targets := rk3288_resume.o rk3288_ddr_resume.o \
	rk3288_resume.elf rk3288_resume.lds \
	rk3288_resume.bin rk3288_resume.bin.o

targets += rk3288-dmc-sram.o \
	rk3288_sram.elf rk3288_sram.lds \
	rk3288_sram.bin rk3288_sram.bin.o

# Reset objcopy flags, ARM puts "-O binary" here.
OBJCOPYFLAGS :=

# The blobs run from SRAM, partly with the MMU off: no tracing hooks, no stack
# protector, position independent, and no compiler-inserted memset() calls.
ccflags-remove-y += $(CC_FLAGS_FTRACE)
ccflags-y += -fno-stack-protector -fPIC \
	     $(call cc-option,-ftrivial-auto-var-init=uninitialized)

# Prevents link failures: __sanitizer_cov_trace_pc() is not linked in.
KCOV_INSTRUMENT := n

# This is the ELF for the embedded binary
LDFLAGS_rk3288_resume.elf := -Bstatic -nostdlib -T
$(obj)/rk3288_resume.elf: $(obj)/rk3288_resume.lds \
			  $(obj)/rk3288_resume.o \
			  $(obj)/rk3288_ddr_resume.o \
			  FORCE
	$(call if_changed,ld)

LDFLAGS_rk3288_sram.elf := -Bstatic -nostdlib --check-sections -T
$(obj)/rk3288_sram.elf: $(obj)/rk3288_sram.lds $(obj)/rk3288-dmc-sram.o \
			  FORCE
	$(call if_changed,ld)

# Create binary data for the kernel
OBJCOPYFLAGS_rk3288_resume.bin := -O binary
$(obj)/rk3288_resume.bin: $(obj)/rk3288_resume.elf FORCE
	$(call if_changed,objcopy)

OBJCOPYFLAGS_rk3288_sram.bin := -O binary
$(obj)/rk3288_sram.bin: $(obj)/rk3288_sram.elf FORCE
	$(call if_changed,objcopy)

# Import the data into the kernel
OBJCOPYFLAGS_rk3288_resume.bin.o += -B $(ARCH) -I binary -O elf32-littlearm
$(obj)/rk3288_resume.bin.o: $(obj)/rk3288_resume.bin FORCE
	$(call if_changed,objcopy)

OBJCOPYFLAGS_rk3288_sram.bin.o += -B $(ARCH) -I binary -O elf32-littlearm
$(obj)/rk3288_sram.bin.o: $(obj)/rk3288_sram.bin FORCE
	$(call if_changed,objcopy)
