#!/bin/bash
# Build the 4.19 kernel for the iFive mini 4S and pack it into a Rockchip KRNL image (kernel.img).
# Usage: ./build-kernel.sh [gsi-6.1|gsi-release|dev]   (default gsi-6.1)
# Needs: an arm cross gcc (Fedora: gcc-arm-linux-gnu + binutils-arm-linux-gnu -> CROSS_COMPILE=arm-linux-gnu-;
#        Debian: gcc-arm-linux-gnueabi -> CROSS_COMPILE=arm-linux-gnueabi-), bc, bison, flex, lz4, libssl-dev, python3.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# Check dependencies
command -v lz4 >/dev/null 2>&1 || { echo "STOP: lz4 command not found. Please install lz4 (e.g. dnf install lz4 / apt install lz4)"; exit 1; }
# Automatically restore broken symlinks if project was downloaded as zip
if [ -f "$HERE/scripts/restore-symlinks.py" ]; then
    python3 "$HERE/scripts/restore-symlinks.py"
fi
CFG=${1:-gsi-6.1}
export ARCH=arm CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnu-} KCFLAGS="${KCFLAGS:--Wno-array-compare}"
O=${O:-$HERE/out/kernel-$CFG}
mkdir -p "$O"
cp "$HERE/kernel-configs/$CFG.config" "$O/.config"
make -C "$HERE/kernel" O="$O" olddefconfig
# CC on the command line bypasses scripts/gcc-wrapper.py, which turns newer-gcc warnings into errors.
make -C "$HERE/kernel" O="$O" -j"$(nproc)" CC="${CROSS_COMPILE}gcc" zImage rk3288-ifive-mini4s.dtb
# Wi-Fi: Rockchip rkwifi bcmdhd is a module (CONFIG_AP6XXX=m).  It loads the firmware from /vendor when it
# is inserted, and /vendor is not mounted yet when the SDIO card is probed at boot, so it cannot be built in.
# The vendor Wi-Fi HAL inserts /vendor/lib/modules/bcmdhd.ko, which has to come from the same build as the
# kernel (vermagic and symbol CRCs); scripts/patch-vendor.sh writes the copy staged here into the vendor image.
# Only a full "make modules" writes Module.symvers; vmlinux.symvers has the CRCs of everything bcmdhd imports.
BCMDHD=drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd
make -C "$HERE/kernel" O="$O" -j"$(nproc)" CC="${CROSS_COMPILE}gcc" modules_prepare
cp "$O/vmlinux.symvers" "$O/Module.symvers"
make -C "$HERE/kernel" O="$O" -j"$(nproc)" CC="${CROSS_COMPILE}gcc" M="$BCMDHD" modules
mkdir -p "$HERE/vendor-changes/lib/modules"
"${CROSS_COMPILE}strip" --strip-debug -o "$HERE/vendor-changes/lib/modules/bcmdhd.ko" "$O/$BCMDHD/bcmdhd.ko"
python3 "$HERE/release-build/tools/mkkrnl.py" pack "$O/arch/arm/boot/zImage" "$O/kernel.img"
echo "kernel: $O/kernel.img"; echo "dtb:    $O/arch/arm/boot/dts/rk3288-ifive-mini4s.dtb (-> resource.img via release-build/build-resource.sh)"
echo "wifi:   $HERE/vendor-changes/lib/modules/bcmdhd.ko (-> /vendor/lib/modules via scripts/patch-vendor.sh)"
