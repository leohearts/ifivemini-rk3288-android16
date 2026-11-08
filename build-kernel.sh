#!/bin/bash
# Build the 4.19 kernel for the iFive mini 4S and pack it into a Rockchip KRNL image (kernel.img).
# Usage: ./build-kernel.sh [gsi-release|dev]   (default gsi-release)
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
CFG=${1:-gsi-release}
export ARCH=arm CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnu-} KCFLAGS="${KCFLAGS:--Wno-array-compare}"
O=${O:-$HERE/out/kernel-$CFG}
mkdir -p "$O"
cp "$HERE/kernel-configs/$CFG.config" "$O/.config"
make -C "$HERE/kernel" O="$O" olddefconfig
# CC on the command line bypasses scripts/gcc-wrapper.py, which turns newer-gcc warnings into errors.
make -C "$HERE/kernel" O="$O" -j"$(nproc)" CC="${CROSS_COMPILE}gcc" zImage rk3288-ifive-mini4s.dtb
python3 "$HERE/release-build/tools/mkkrnl.py" pack "$O/arch/arm/boot/zImage" "$O/kernel.img"
echo "kernel: $O/kernel.img"; echo "dtb:    $O/arch/arm/boot/dts/rk3288-ifive-mini4s.dtb (-> resource.img via release-build/build-resource.sh)"
