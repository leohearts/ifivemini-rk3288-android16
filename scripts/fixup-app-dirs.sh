#!/bin/bash
# Repair Android/data and Android/obb of apps installed before the move from the Linux 4.19
# kernel to 6.1, when /data was kept (flash.sh --keep-userdata).
#
#   ./fixup-app-dirs.sh [adb-serial]
#
# 4.19 had sdcardfs, which left files in Android/data/<package> owned by media_rw. 6.1 has
# only FUSE, so apps see the real owner and some cannot open their own files (Obtainium loses
# its app list, App Manager shows negative sizes). This runs FixupAppDirs from the vendor
# IfiveSettings APK, which asks the framework (StorageManagerService.fixupAppDir, done by vold)
# to set the owner, group, quota project ID and ACL of every app directory, the same call
# DownloadProvider uses. Run it once; a second run finds nothing to repair.
#
# Needs root on the tablet: `adb root`, or Magisk (`su`).

set -euo pipefail

SER=${1:-}
ADB=(adb)
[ -n "$SER" ] && ADB+=( -s "$SER" )

CMD='CLASSPATH=/vendor/priv-app/IfiveSettings/IfiveSettings.apk app_process /system/bin com.leohearts.ifivesettings.FixupAppDirs'
if [ "$("${ADB[@]}" shell id -u | tr -d '\r')" = 0 ]; then
  "${ADB[@]}" shell "$CMD"
else
  # Magisk's su is not always on PATH for the adb shell; /debug_ramdisk is where Magisk puts it.
  "${ADB[@]}" shell "S=\$(command -v su || echo /debug_ramdisk/su); \$S -c '$CMD'"
fi
