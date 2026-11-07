#!/bin/bash
# Build images/resource.img (Rockchip RSCE: device tree + boot logos) from resource-release-gsi.dts.
# resource-release-gsi.dts is the release device tree: the kernel's rk3288-ifive-mini4s.dtb plus the
# release-only edits listed in its header comment (bootargs without watchdog/deadline, fbcon, reboot-mode
# enabled, CW2015 fuel gauge for off-mode charging, uboot-charge removed, touch I2C at 400 kHz).
# If you change the kernel DTS, regenerate this file from the new DTB (dtc -I dtb -O dts) and re-apply those edits.
# Logos are taken from the previous resource-release-gsi.img (same files since the stock Android 6 firmware).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/resource-release-gsi.img}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
"$HERE/tools/resource_tool" --unpack --image="$HERE/resource-release-gsi.img" "$W/old" >/dev/null 2>&1
"$HERE/tools/dtc" -I dts -O dtb -o "$W/rk-kernel.dtb" "$HERE/resource-release-gsi.dts" 2>/dev/null
cp "$W/old/logo.bmp" "$W/old/logo_kernel.bmp" "$W/"
( cd "$W" && "$HERE/tools/resource_tool" --pack --image="$W/resource.img" rk-kernel.dtb logo.bmp logo_kernel.bmp >/dev/null 2>&1 )
truncate -s 16777216 "$W/resource.img"
[ "$(xxd -p -l 4 "$W/resource.img")" = 52534345 ] || { echo "no RSCE magic"; exit 3; }
cp "$W/resource.img" "$OUT"; echo "resource: $OUT"
