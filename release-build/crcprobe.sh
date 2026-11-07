#!/bin/bash
# crcprobe.sh <name> <config-file> : prepare an O= dir with that config and print the module_layout CRC from kernel/module.o
source /tmp/rk3288-port/scripts/env-kernel.sh >/dev/null
export C_INCLUDE_PATH=/run/media/leohearts/Data/rk3288-a11/hostshim KCFLAGS=-Wno-array-compare
A=/run/media/leohearts/Data/rk3288-a11; O=$A/kbuild-crc-$1; mkdir -p $O; cp $2 $O/.config
cd $A/ksrc-release
make O=$O olddefconfig >/dev/null 2>&1
make O=$O -j8 CC=arm-linux-gnueabi-gcc prepare >/dev/null 2>&1
make O=$O CC=arm-linux-gnueabi-gcc kernel/module.o >/dev/null 2>&1
arm-linux-gnueabi-nm $O/kernel/module.o | grep -E "__crc_module_layout" 
