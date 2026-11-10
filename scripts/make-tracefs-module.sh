#!/bin/bash
# Build the Magisk module that makes /sys/kernel/tracing traversable on this tablet.
#
#   ./make-tracefs-module.sh <out.zip> [magisk.apk]
#
# What it fixes: tracefs is mounted by the GSI's own init (/system/etc/init/hw/init.rc:76,
# "mount tracefs tracefs /sys/kernel/tracing gid=3012") and the same file repairs its mode in
# "on late-fs" (init.rc:678, "chmod 0755 /sys/kernel/tracing"). On this tablet the directory stays
# drwx------ 0700, so no process outside root can even resolve a path inside it. When an app
# zygote forks a child it re-opens the inherited trace_marker descriptor and aborts when that
# fails:
#
#   JNI FatalError called: (zygote) Failed open(/sys/kernel/tracing/trace_marker, 1): Permission denied
#   SIGABRT in FileDescriptorInfo::ReopenOrDetach <- android::zygote::ForkCommon
#   (/data/tombstones/tombstone_05..10, six identical aborts, one per renderer start)
#
# Measured consequence: every Chromium- or WebView-based app (Cromite, Chrome, any WebView host)
# renders a black page - the renderer never survives to draw anything. With
# "chmod 0755 /sys/kernel/tracing" applied at runtime the renderers stay alive and pages draw.
#
# The release image carries this fix inside /vendor/etc/init/hw/init.rockchip.rc (see
# vendor-changes/, written by scripts/patch-vendor.sh) using the same post-fs-data trigger. This
# module exists for tablets already flashed with an older vendor image, where rewriting /vendor
# would mean a full reflash.
#
# Layout follows Magisk's own docs (docs/guides.md, "Magisk Module Installer"): update-binary is
# the APK's assets/module_installer.sh, updater-script is "#MAGISK".

set -euo pipefail

OUT=${1:?usage: $0 <out.zip> [magisk.apk]}
APK=${2:-/home/leohearts/Downloads/Magisk-v31.0.apk}
ID=ifive-tracefs-perms

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "$OUT")          # the zip step changes directory, so resolve it now
W=$(mktemp -d "${TMPDIR:-/tmp}/ifive-tracefs.XXXXXX")
trap 'rm -rf "$W"' EXIT
[ -f "$APK" ] || { echo "STOP: no Magisk APK at $APK"; exit 1; }

mkdir -p "$W/m/META-INF/com/google/android"

cat > "$W/m/module.prop" <<PROP
id=$ID
name=iFive mini 4S: tracefs readable by apps
version=v1
versionCode=1
author=leohearts
description=chmod 0755 /sys/kernel/tracing at post-fs-data. The GSI leaves that directory at 0700, so an app zygote cannot re-open trace_marker when it forks a child and aborts with SIGABRT; every Chromium/WebView based app then renders nothing at all. Only needed on tablets whose vendor image predates the same fix in /vendor/etc/init/hw/init.rockchip.rc.
PROP

cat > "$W/m/post-fs-data.sh" <<'SH'
#!/system/bin/sh
# See the header of scripts/make-tracefs-module.sh for the measurement behind this line.
chmod 0755 /sys/kernel/tracing
SH
chmod 755 "$W/m/post-fs-data.sh"

unzip -p "$APK" assets/module_installer.sh > "$W/m/META-INF/com/google/android/update-binary"
chmod 755 "$W/m/META-INF/com/google/android/update-binary"
printf '#MAGISK\n' > "$W/m/META-INF/com/google/android/updater-script"

rm -f "$OUT"
( cd "$W/m" && zip -q -X -r9 "$OUT" . )

echo "== $(basename "$OUT") 内容 =="
unzip -l "$OUT" | awk 'NR>3 && NF>=4 {print "   " $1 " " $4}' | grep -v '^   $'
echo "   sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo
echo "Check after a reboot (root shell):  ls -ld /sys/kernel/tracing   -> drwxr-xr-x"
echo "Install:  Magisk app -> Modules -> Install from storage, or"
echo "          magisk --install-module $(basename "$OUT")   (root shell)"
