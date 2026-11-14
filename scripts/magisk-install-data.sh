#!/bin/bash
# Finish a Magisk ramdisk install on this tablet: fill /data/adb/magisk.
#
#   ./magisk-install-data.sh <magisk.apk> [adb-serial]
#
# Run this once after writing the Magisk boot partition (scripts/make-magisk-boot.sh) and
# booting it, when the app shows "Ramdisk = Yes, Not installed".
#
# The daemon needs /data/adb/magisk: in Magisk 31.0 (native/src/core/bootstages.rs)
# setup_magisk_env() returns false when /data/adb/magisk/busybox is missing, and the boot log
# says "* Magisk environment incomplete, abort". The Magisk app creates this directory while
# re-patching the boot image, and magiskboot cannot unpack this tablet's boot partition (a
# Rockchip KRNL container). Step 2 below does the environment part of Magisk's flashable-zip
# installer (scripts/flash_script.sh): lib/<abi>/libX.so renamed to X, plus magisk32, plus
# assets/, minus bootctl/main.jar/module_installer.sh/uninstaller.sh, chmod -R 755.
# Everything it writes is under /data.
#
# The tablet must be reachable with root adb (this build is userdebug: `adb root`).

set -euo pipefail

APK=${1:?usage: $0 <magisk.apk> [adb-serial]}
SER=${2:-}
ADB=(adb)
[ -n "$SER" ] && ADB+=( -s "$SER" )

ABI=armeabi-v7a          # the ramdisk init and this device's userspace are both 32-bit ARM
W=$(mktemp -d "${TMPDIR:-/tmp}/ifive-magisk-install.XXXXXX")
trap 'rm -rf "$W"' EXIT

[ -f "$APK" ] || { echo "STOP: no APK at $APK"; exit 1; }
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

echo "== 4. check the boot partition's Magisk config for PREINITDEVICE"
# Magisk's env_check returns 2 unless the block node $MAGISKTMP/.magisk/device/preinit exists
# (assets/app_functions.sh:17-22), and the app then asks to reflash Magisk on every start.
# magiskinit creates that node from PREINITDEVICE in the ramdisk config; parse_config_file()
# runs in patch_ro_root()/patch_rw_root() (native/src/init/rootdir.cpp:264 and :342), before
# /data is mounted, so the key has to be in the boot partition.
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
    echo "            Rebuild it with scripts/make-magisk-boot.sh and write it again:"
    echo "            rkdeveloptool wl 0x16000 <image>"
fi

echo
echo "Done. Reboot the tablet (\`${ADB[*]} reboot\`) - the daemon runs this setup only at boot."
echo "After the reboot:"
echo "  * magiskd logs boot-complete and /data/adb/magisk.db keeps bootloop=0"
echo "  * su -c id -> uid=0, context u:r:magisk:s0"
echo "  * Magisk's own check passes: MAGISKBIN=/data/adb/magisk MAGISKTMP=/debug_ramdisk sh -c \\"
echo "      '. /data/adb/magisk/app_functions.sh; env_check 31.0 31000'   -> exit 0"
echo "    (exit 2 there means the boot image still lacks PREINITDEVICE)"
