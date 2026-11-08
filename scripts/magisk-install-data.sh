#!/bin/bash
# Finish a Magisk ramdisk install on this tablet: fill /data/adb/magisk, then install the
# module that disables the GSI's phh su.
#
#   ./magisk-install-data.sh <magisk.apk> [adb-serial]
#
# Run this once after flashing images/ramdisk.img's Magisk replacement
# (scripts/make-magisk-boot.sh) and booting it. Without it the tablet boots with magiskd
# running but Magisk half-installed: the app shows "Ramdisk = Yes, Not installed".
#
# Two separate problems, both fixed here, both from inside /data - no partition is written:
#
# 1. /data/adb/magisk does not exist. The daemon needs it: in Magisk 31.0
#    (native/src/core/bootstages.rs) setup_magisk_env() returns false when
#    /data/adb/magisk/busybox is missing, and the boot log says
#    "* Magisk environment incomplete, abort". Normally the Magisk app creates this directory as
#    part of its own install, but the app installs it by unpacking and re-patching the boot
#    image, and this tablet's boot partition is a Rockchip KRNL container that magiskboot cannot
#    unpack. So step 2 below performs only the environment part of Magisk's own flashable-zip
#    installer (scripts/flash_script.sh): lib/<abi>/libX.so renamed to X, plus magisk32, plus
#    assets/, minus bootctl/main.jar/module_installer.sh/uninstaller.sh, chmod -R 755.
#
# 2. The TrebleDroid GSI ships its own su: /system/etc/init/su.rc declares
#       service sudaemon /system/bin/phh-su --daemon
#   and that daemon mounts a tmpfs over Magisk's /debug_ramdisk/magisk, /system/xbin/magisk and
#   /system/xbin/magiskpolicy with phh-su in place of each. su calls then go to phh's su (which
#   has no UI installed here: the package me.phh.superuser is absent, so no prompt and no
#   su.sqlite), and init's boot-stage calls "magisk --boot-complete" / "--service" /
#   "--zygote-restart" run phh-su instead - it exits 2 on those options, the daemon never learns
#   that boot finished, the bootloop counter in /data/adb/magisk.db is never reset, and Magisk
#   ends up in safe mode with modules off. Step 4 installs the module built by
#   make-no-phh-su-module.sh, which replaces those two paths with empty files. The system image
#   itself still contains phh-su; this only applies to a tablet set up for Magisk.
#
# The tablet must be reachable with root adb (this build is userdebug: `adb root`).

set -euo pipefail

APK=${1:?usage: $0 <magisk.apk> [adb-serial]}
SER=${2:-}
ADB=(adb)
[ -n "$SER" ] && ADB+=( -s "$SER" )

ABI=armeabi-v7a          # the ramdisk init and this device's userspace are both 32-bit ARM
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/ifive-magisk-install.XXXXXX")
trap 'rm -rf "$W"' EXIT

[ -f "$APK" ] || { echo "STOP: no APK at $APK"; exit 1; }
[ -x "$HERE/make-no-phh-su-module.sh" ] || { echo "STOP: missing $HERE/make-no-phh-su-module.sh"; exit 1; }
"${ADB[@]}" shell id -u 2>/dev/null | grep -qx 0 || { echo "STOP: adb shell is not root (run: adb root)"; exit 1; }

echo "== 1. build the file set out of $(basename "$APK")"
python3 - "$APK" "$W/env" "$ABI" <<'PY'
import os, shutil, sys, zipfile
apk, dst, abi = sys.argv[1], sys.argv[2], sys.argv[3]
# flash_script.sh removes these from the installed set: they are only used by the Magisk app
DROP = {"bootctl", "main.jar", "module_installer.sh", "uninstaller.sh"}
z = zipfile.ZipFile(apk)
os.makedirs(dst)
def put(name, src):
    path = os.path.join(dst, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with z.open(src) as f, open(path, "wb") as o:
        shutil.copyfileobj(f, o)
    os.chmod(path, 0o755)
for n in z.namelist():
    if n.startswith(f"lib/{abi}/lib") and n.endswith(".so"):
        name = os.path.basename(n)[3:-3]          # libX.so -> X
        if name not in DROP:
            put(name, n)
put("magisk32", f"lib/{abi}/libmagisk.so")        # upstream copies the 32-bit magisk under this name
for n in z.namelist():                            # assets/ -> $MAGISKBIN
    if n.startswith("assets/") and not n.endswith("/"):
        rel = n[len("assets/"):]
        if rel not in DROP:
            put(rel, n)
for root, dirs, _ in os.walk(dst):
    for d in dirs:
        os.chmod(os.path.join(root, d), 0o755)
print("   " + " ".join(sorted(os.listdir(dst))))
PY
tar cf "$W/env.tar" -C "$W/env" .

echo "== 2. push and install into /data/adb/magisk"
"${ADB[@]}" push -q "$W/env.tar" /data/local/tmp/magisk-seed.tar
"${ADB[@]}" shell "cd /data/local/tmp && rm -rf magisk-seed && mkdir magisk-seed && tar xf magisk-seed.tar -C magisk-seed && rm -rf /data/adb/magisk && mkdir -p /data/adb/magisk && cp -af magisk-seed/. /data/adb/magisk/ && chown -R 0:0 /data/adb/magisk && chmod -R 755 /data/adb/magisk && chcon -R u:object_r:system_file:s0 /data/adb/magisk && rm -rf magisk-seed magisk-seed.tar"

echo "== 3. check the transferred bytes against the host copies"
( cd "$W/env" && sha256sum busybox magisk magisk32 magiskinit magiskboot magiskpolicy util_functions.sh stub.apk ) > "$W/host.sha256"
"${ADB[@]}" shell "cd /data/adb/magisk && sha256sum busybox magisk magisk32 magiskinit magiskboot magiskpolicy util_functions.sh stub.apk" > "$W/dev.sha256"
if diff -q <(cut -d' ' -f1 "$W/host.sha256") <(cut -d' ' -f1 "$W/dev.sha256") >/dev/null; then
    echo "   all 8 sha256 match"
else
    echo "STOP: the files on the tablet differ from the ones built here"; diff "$W/host.sha256" "$W/dev.sha256"; exit 1
fi

echo "== 4. install the module that disables the GSI's phh su"
"$HERE/make-no-phh-su-module.sh" "$W/ifive-no-phh-su.zip" "$APK" >/dev/null
"${ADB[@]}" push -q "$W/ifive-no-phh-su.zip" /data/local/tmp/ifive-no-phh-su.zip
"${ADB[@]}" shell '/data/adb/magisk/magisk --install-module /data/local/tmp/ifive-no-phh-su.zip; rm -f /data/local/tmp/ifive-no-phh-su.zip' \
    | sed 's/^/   /'
[ -n "$("${ADB[@]}" shell 'ls /data/adb/modules 2>/dev/null | grep -x ifive-no-phh-su')" ] \
    || { echo "STOP: the module is not in /data/adb/modules"; exit 1; }
echo "   module installed: ifive-no-phh-su"

echo "== 5. check the boot partition's Magisk config for PREINITDEVICE"
# Without this key Magisk's env_check returns 2 (assets/app_functions.sh:17-22 needs the block node
# $MAGISKTMP/.magisk/device/preinit), and the app shows "Requires additional setup - your device
# needs reflash Magisk" on every start. The key can only come from the ramdisk config:
# parse_config_file() runs inside patch_ro_root()/patch_rw_root() (native/src/init/rootdir.cpp:264
# and :342), long before fs_mgr mounts /data, so the same file in /data is read too late to matter
# (measured: writing /data/.backup/.magisk changed nothing, "mount: preinit dir not found" stayed).
"${ADB[@]}" exec-out "head -c 2097152 /dev/block/by-name/boot" > "$W/boot.head"
if python3 - "$W/boot.head" <<'PY'
import gzip, struct, sys
d = open(sys.argv[1], "rb").read()
if d[:4] != b"KRNL":
    sys.exit("the boot partition does not start with a KRNL container")
n, = struct.unpack("<I", d[4:8])
raw = gzip.decompress(d[8:8 + n])
i = 0
while raw[i:i + 6] == b"070701":
    namesz = int(raw[i + 94:i + 102], 16); fsz = int(raw[i + 54:i + 62], 16)
    nm = raw[i + 110:i + 110 + namesz - 1].decode("utf8", "replace")
    off = (i + 110 + namesz + 3) // 4 * 4
    if nm == ".backup/.magisk":
        cfg = raw[off:off + fsz].decode()
        print("   " + cfg.replace("\n", "\n   ").rstrip())
        sys.exit(0 if "PREINITDEVICE=" in cfg else 1)
    i = (off + fsz + 3) // 4 * 4
sys.exit("no .backup/.magisk in the boot ramdisk")
PY
then
    echo "   PREINITDEVICE is present"
else
    echo "   WARNING: the boot partition carries a Magisk image without PREINITDEVICE."
    echo "            Rebuild it with scripts/make-magisk-boot.sh (it writes the key since this"
    echo "            change) and write it again: rkdeveloptool wl 0x16000 <image>"
fi

echo
echo "Done. Reboot the tablet (\`${ADB[*]} reboot\`) - the daemon runs this setup only at boot."
echo "After the reboot:"
echo "  * magiskd logs boot-complete and /data/adb/magisk.db keeps bootloop=0"
echo "  * /system/xbin/su is Magisk's own (su -c id -> context u:r:magisk:s0)"
echo "  * Magisk's own check passes: MAGISKBIN=/data/adb/magisk MAGISKTMP=/debug_ramdisk sh -c \\"
echo "      '. /data/adb/magisk/app_functions.sh; env_check 31.0 31000'   -> exit 0"
echo "    (exit 2 there means the boot image still lacks PREINITDEVICE)"
