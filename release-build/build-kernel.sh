# Release kernel build. Config is kbuild-release/.config = cif5 .config + release.fragment (see README).
set -e; set -o pipefail
source /tmp/rk3288-port/scripts/env-kernel.sh >/dev/null
export C_INCLUDE_PATH=/run/media/leohearts/Data/rk3288-a11/hostshim KCFLAGS=-Wno-array-compare
A=/run/media/leohearts/Data/rk3288-a11
cd $A/ksrc-release
O=$A/kbuild-release
make O=$O -j$(nproc) CC=arm-linux-gnueabi-gcc zImage rk3288-ifive-mini4s.dtb 2>&1 | tail -15
echo EXIT=${PIPESTATUS[0]}
