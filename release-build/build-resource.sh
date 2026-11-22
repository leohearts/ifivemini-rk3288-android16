#!/bin/bash
# Build images/resource.img (Rockchip RSCE: device tree + boot logos) from the kernel's
# rk3288-ifive-mini4s.dtb (./build-kernel.sh). The kernel DTS is the release device tree.
# Logos are taken from the previous resource-release-gsi.img (same files since the stock Android 6 firmware).
# Usage: build-resource.sh [out.img] [dtb]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/resource-release-gsi.img}
DTB=${2:-$HERE/../out/kernel-gsi-6.1/arch/arm/boot/dts/rk3288-ifive-mini4s.dtb}
[ -f "$DTB" ] || { echo "STOP: no $DTB (run ./build-kernel.sh)"; exit 3; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$HERE/tools/resource_tool" --unpack --image="$HERE/resource-release-gsi.img" "$W/old" >/dev/null 2>&1
cp "$DTB" "$W/rk-kernel.dtb"
cp "$W/old/logo.bmp" "$W/old/logo_kernel.bmp" "$W/"
( cd "$W" && "$HERE/tools/resource_tool" --pack --image="$W/resource.img" rk-kernel.dtb logo.bmp logo_kernel.bmp >/dev/null 2>&1 )
truncate -s 16777216 "$W/resource.img"
[ "$(xxd -p -l 4 "$W/resource.img")" = 52534345 ] || { echo "no RSCE magic"; exit 3; }
cp "$W/resource.img" "$OUT"; echo "resource: $OUT"
