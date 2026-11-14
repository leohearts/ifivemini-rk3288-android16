CFLAGS_platsmp.o := -march=armv7-a

obj-$(CONFIG_ARCH_ROCKCHIP) += rockchip.o
obj-$(CONFIG_PM_SLEEP) += pm.o sleep.o
obj-$(CONFIG_SMP) += headsmp.o platsmp.o
# Built in even when the RK3288 DMC driver is a module (see dmc-sram-call.c).
obj-$(subst m,y,$(CONFIG_ARM_RK3288_DMC_DEVFREQ)) += call_with_mmu_disabled.o \
						    dmc-sram-call.o embedded/
