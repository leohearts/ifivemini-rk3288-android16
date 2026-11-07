#!/bin/bash
# bisect.sh : apply each fragment line on top of the cif5 config separately, print module_layout CRC
A=/run/media/leohearts/Data/rk3288-a11
source /tmp/rk3288-port/scripts/env-kernel.sh >/dev/null
i=0
grep -E "^(# )?CONFIG_" $A/release/build/release.fragment | while read -r line; do
  i=$((i+1)); echo "$line" > /tmp/frag.$i
  d=$A/kbuild-crc-t$i; mkdir -p $d; cp $A/kbuild-cif5/.config $d/.config.in
  ( cd $A/ksrc-release; KCONFIG_CONFIG=$d/.config.in make O=$d olddefconfig >/dev/null 2>&1; cp $d/.config.in $d/.config
    ./scripts/kconfig/merge_config.sh -m -O $d $d/.config /tmp/frag.$i >/dev/null 2>&1 )
  r=$($A/release/build/crcprobe.sh t$i $d/.config)
  echo "$line => $r"
done
