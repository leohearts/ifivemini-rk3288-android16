#!/bin/bash
# Build the Magisk module that disables the GSI's phh su on this tablet.
#
#   ./make-no-phh-su-module.sh <out.zip> [magisk.apk]
#
# What it fixes: the TrebleDroid GSI ships /system/etc/init/su.rc
#
#     service sudaemon /system/bin/phh-su --daemon
#         class main
#
# Once that daemon runs it mounts a tmpfs over Magisk's /debug_ramdisk/magisk,
# /system/xbin/magisk and /system/xbin/magiskpolicy with phh-su copied in place of each of them,
# so every "su" call lands in phh's su (package me.phh.superuser, which this GSI does not even
# install - there is no grant UI and no su.sqlite anywhere) and init's Magisk boot-stage calls
# (/debug_ramdisk/magisk --boot-complete etc.) exec phh-su instead, which exits 2 on those options.
# The daemon then never sees boot-complete, /data/adb/magisk.db keeps bootloop=1,2,... and Magisk
# starts in safe mode with every module off.
#
# The module replaces both paths with empty files, so the service is still declared, exec fails
# immediately, and nothing else in the GSI is touched. The system image itself keeps phh-su: this
# is only applied when a tablet is set up for Magisk.
#
# Layout follows Magisk's own docs (docs/guides.md, "Magisk Module Installer"): update-binary is
# the APK's assets/module_installer.sh, updater-script is "#MAGISK".
#
# Install it from the Magisk app (Modules -> Install from storage), from a root shell with
#   magisk --install-module ifive-no-phh-su.zip
# or unpacked into /data/adb/modules/ (scripts/magisk-install-data.sh does that).

set -euo pipefail

OUT=${1:?usage: $0 <out.zip> [magisk.apk]}
APK=${2:-/home/leohearts/Downloads/Magisk-v31.0.apk}
ID=ifive-no-phh-su

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "$OUT")          # the zip step changes directory, so resolve it now
W=$(mktemp -d "${TMPDIR:-/tmp}/ifive-nophh.XXXXXX")
trap 'rm -rf "$W"' EXIT
[ -f "$APK" ] || { echo "STOP: no Magisk APK at $APK"; exit 1; }

mkdir -p "$W/m/META-INF/com/google/android" "$W/m/system/etc/init" "$W/m/system/bin"

cat > "$W/m/module.prop" <<PROP
id=$ID
name=iFive mini 4S: disable phh su
version=v1
versionCode=1
author=leohearts
description=Replaces /system/etc/init/su.rc and /system/bin/phh-su with empty files. The TrebleDroid GSI starts phh-su as "sudaemon", and that daemon mounts itself over Magisk's /debug_ramdisk/magisk and /system/xbin/magisk, which takes su away from Magisk and makes init's magisk --boot-complete call run phh-su instead. Only needed on tablets that use the Magisk boot partition image.
PROP

# the two files the module replaces - both intentionally empty
: > "$W/m/system/etc/init/su.rc"
: > "$W/m/system/bin/phh-su"

unzip -p "$APK" assets/module_installer.sh > "$W/m/META-INF/com/google/android/update-binary"
chmod 755 "$W/m/META-INF/com/google/android/update-binary"
printf '#MAGISK\n' > "$W/m/META-INF/com/google/android/updater-script"

rm -f "$OUT"
( cd "$W/m" && zip -q -X -r9 "$OUT" . )

echo "== $(basename "$OUT") 内容 =="
unzip -l "$OUT" | awk 'NR>3 && NF>=4 {print "   " $1 " " $4}' | grep -v '^   $'
echo "   sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo
echo "Install:  Magisk app -> Modules -> Install from storage, or"
echo "          magisk --install-module $(basename "$OUT")   (root shell)"
