#!/bin/bash
# Build the Magisk module replacing /vendor/lib/hw/hwcomposer.rk30board.so with the
# composition-fixed RK3288 build (source: hwc/src-a16, built by hwc/build.sh).
#
#   ./make-hwc-module.sh <out.zip> [hwcomposer.rk30board.so] [magisk.apk]
#
# What it fixes - both measured on device, full analysis in reports/HwcFix1110.md:
#   1) MatchPlanes rejected the whole frame whenever the bottom layer carried a
#      global alpha ("vop cann't support first layer with global alpha"). The
#      4.19 VOP exposes GLOBAL_ALPHA on every plane and blends against black,
#      which is what GLES composition produces anyway; MatchPlane already skips
#      individual planes that lack the property.
#   2) The plane-overflow bandwidth cap was hardcoded to 3.3 (vendor tuning for
#      1080p boards), rejecting this panel's 5-layer shade scene (~4.9). The cap
#      is now vop_band_limit(): property vendor.hwc.vop.max_scale (float, read
#      once per composer start), default 6.0 on RK3288_MID, 3.3 elsewhere.
#
# Measured after both (device, 2026-11-11/12). Note: the module installed on the
# tablet before 2026-11-12 behaved as if the cap were still 3.3 (one "so big"
# per drag frame in logcat); a clean rebuild + install made the rejections stop
# and the numbers below drop out. build.sh once defined -DRK_MID where the code
# checks #ifdef RK3288_MID; the correct -DRK3288_MID is in the DEFs today:
#   shade buffer release cadence median 16.8 ms (was 29-36 ms), >24 ms frames 9%
#   (was 75-83%); SystemUI jank over the 2x12-drag protocol 6.9-7.2% (was 84-96%);
#   background redraws under the shade 31-45 -> 2 per session. This IS the
#   smoothness fix. In the first ~5 min after a cold boot the cadence measures
#   ~21 ms (GPU clock gating / devfreq ramp), settles by itself.
#
# WARNING - loading path: take a plain reboot. Do NOT swap the .so under a
# running composer (umount of a mapped bind mount SEGVs the HAL; a composer
# restart cascades SF -> system_server on this device and has been observed to
# take the whole tablet down). That's also why this delivery is a module:
# the mount happens in early boot, before the framework exists.

set -euo pipefail

OUT=${1:?usage: $0 <out.zip> [hwcomposer.so] [magisk.apk]}
SO=${2:-$(cd "$(dirname "$0")/.." && pwd)/hwc/out/hwcomposer.rk30board.so}
APK=${3:-/home/leohearts/Downloads/Magisk-v31.0.apk}
ID=ifive-hwc-composition

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "$OUT")
W=$(mktemp -d "${TMPDIR:-/tmp}/ifive-hwc.XXXXXX")
trap 'rm -rf "$W"' EXIT
[ -f "$APK" ] || { echo "STOP: no Magisk APK at $APK"; exit 1; }
[ -f "$SO" ] || { echo "STOP: no hwcomposer .so at $SO (run hwc/build.sh first)"; exit 1; }

mkdir -p "$W/m/META-INF/com/google/android"
cp "$SO" "$W/m/hwcomposer.rk30board.so"
chmod 644 "$W/m/hwcomposer.rk30board.so"

SO_SHA=$(sha256sum "$SO" | cut -d' ' -f1)

# NOTE: magic mount does NOT apply a module's vendor/ directory on this device
# (measured 2026-11-10: magisk 31.0 logs "loading module files" for system/
# modules and silently skips one whose only content is vendor/). The bind is
# therefore done in post-fs-data.sh - same boot stage the tracefs module uses,
# after /vendor is mounted and before any framework process exists, so the
# composer HAL maps the replaced file from its very first start.
cat > "$W/m/post-fs-data.sh" <<'SH'
#!/system/bin/sh
MODDIR=${0%/*}
TARGET=/vendor/lib/hw/hwcomposer.rk30board.so
umount "$TARGET" 2>/dev/null
mount -o bind "$MODDIR/hwcomposer.rk30board.so" "$TARGET"
SH
chmod 755 "$W/m/post-fs-data.sh"

cat > "$W/m/module.prop" <<PROP
id=$ID
name=iFive mini 4S: HWC composition fixes
version=v2026-11-12
versionCode=2
author=leohearts
description=Replaces /vendor/lib/hw/hwcomposer.rk30board.so with the build that stops rejecting hardware-plane composition (bottom-layer global alpha gate; 1080p-tuned 3.3 bandwidth cap -> vendor.hwc.vop.max_scale, 6.0 default here; mix window widened upwards first so the full-screen wallpaper keeps a VOP plane instead of costing SF ~11 ms of GLES per pull-down frame). Measured on device 2026-11-12: shade release cadence median 16.8 ms (was 29-36), SystemUI jank 6.9-7.2% over the 2x12-drag protocol (was 84-96%), background redraws 31-45 -> 2 per session. See reports/HwcFix1110.md and reports/ShadeJankTrace1110.md. Check after install: logcat during a shade drag must print no "so big". sha256 $SO_SHA
PROP

unzip -p "$APK" assets/module_installer.sh > "$W/m/META-INF/com/google/android/update-binary"
chmod 755 "$W/m/META-INF/com/google/android/update-binary"
printf '#MAGISK\n' > "$W/m/META-INF/com/google/android/updater-script"

rm -f "$OUT"
( cd "$W/m" && zip -q -X -r9 "$OUT" . )

echo "== $(basename "$OUT") 内容 =="
unzip -l "$OUT" | awk 'NR>3 && NF>=4 {print "   " $1 " " $4}' | grep -v '^   $'
echo "   packaged .so sha256: $SO_SHA"
echo "   zip sha256:          $(sha256sum "$OUT" | cut -d' ' -f1)"
echo
echo "Install (root shell):  magisk --install-module $(basename "$OUT")   then REBOOT (see header warning)."
echo "Check after reboot (root shell):  stat -c %s /vendor/lib/hw/hwcomposer.rk30board.so"
echo "                                  - new build: 370484, stock: 370240"
