#!/bin/bash
# Build a Magisk-patched replacement for the boot partition (the KRNL container that holds the
# Android generic ramdisk, written by flash.sh at tool LBA 0x16000) - from a release package,
# on the host, with no device attached and nothing flashed.
#
#   ./make-magisk-boot.sh <package-dir|ramdisk.img> <magisk.apk> <out.img>
#
#   <package-dir>   an unpacked release (the directory holding images/ramdisk.img), or that
#                   ramdisk image file itself
#   <magisk.apk>    a Magisk v25+ release APK: it is also a zip and carries magiskboot,
#                   magiskinit, magisk, init-ld, stub.apk and assets/boot_patch.sh
#   <out.img>       the patched KRNL container to write instead of images/ramdisk.img
#
# The ramdisk operations are the ones Magisk's own assets/boot_patch.sh performs
# (same magiskboot cpio command list). Only the container handling is Rockchip specific:
# unpack the KRNL payload, patch the cpio, gzip it the way the stock image is gzipped
# (checked in step 2), and pack it back with release-build/tools/mkkrnl.py, which also
# recomputes the CRC the bootloader checks.
#
# Flags - magiskboot reads these from the environment, not from the config file:
#   KEEPVERITY=true KEEPFORCEENCRYPT=true   leave fstab.rk30board untouched (this default)
#   RECOVERYMODE=false                      normal boot, not recovery
# Why the default differs from Magisk's upstream default: the stock ramdisk fstab declares
# "fileencryption=software" on /data and the vendor partition holds no plain
# /etc/fstab.rk30board (only .emmc and .sd variants), so letting Magisk strip those flags
# would change how /data is mounted compared with the image that boots today. Set
# KEEPFORCEENCRYPT=false to follow Magisk's upstream behaviour instead.

set -euo pipefail

PKG=${1:?usage: $0 <package-dir|ramdisk.img> <magisk.apk> <out.img>}
APK=${2:?usage: $0 <package-dir|ramdisk.img> <magisk.apk> <out.img>}
OUT=${3:?usage: $0 <package-dir|ramdisk.img> <magisk.apk> <out.img>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MKKRNL=$ROOT/release-build/tools/mkkrnl.py

# this script changes directory, so resolve the arguments now
PKG=$(realpath -m "$PKG"); APK=$(realpath -m "$APK"); OUT=$(realpath -m "$OUT")

KEEPVERITY=${KEEPVERITY:-true}
KEEPFORCEENCRYPT=${KEEPFORCEENCRYPT:-true}
RECOVERYMODE=${RECOVERYMODE:-false}
export KEEPVERITY KEEPFORCEENCRYPT RECOVERYMODE

case "$PKG" in
    *.img) RAMDISK=$PKG ;;
    *)     RAMDISK=$PKG/images/ramdisk.img ;;
esac
[ -f "$RAMDISK" ] || { echo "STOP: no ramdisk image at $RAMDISK"; exit 1; }
[ -f "$APK" ]     || { echo "STOP: no Magisk APK at $APK"; exit 1; }
[ -f "$MKKRNL" ]  || { echo "STOP: missing $MKKRNL"; exit 1; }
for t in unzip python3 gzip cmp sha256sum stat; do
    command -v "$t" >/dev/null || { echo "STOP: $t missing"; exit 1; }
done

# list a cpio archive as "mode name size"
cpio_list() { python3 -c "
import sys
raw = open(sys.argv[1], 'rb').read(); i = 0
while raw[i:i+6] == b'070701':
    mode = int(raw[i+15:i+23], 16); namesz = int(raw[i+94:i+102], 16)
    fsz  = int(raw[i+54:i+62], 16)
    nm   = raw[i+110:i+110+namesz-1].decode('utf8', 'replace')
    off  = (i + 110 + namesz + 3) // 4 * 4
    print('%06o %s %d' % (mode, nm, fsz))
    i = (off + fsz + 3) // 4 * 4
" "$1"; }

W=$(mktemp -d "${TMPDIR:-/tmp}/ifive-magisk-boot.XXXXXX")
trap 'rm -rf "$W"' EXIT
cd "$W"

echo "== 1. take the Magisk tools out of $APK"
unzip -q -o "$APK" "assets/stub.apk" "lib/*/libmagisk*.so" "lib/*/libinit-ld.so"
# magiskinit must match the architecture of the init binary already in the ramdisk
initarch=$(python3 - "$RAMDISK" <<'PY'
import gzip, struct, sys
d = open(sys.argv[1], "rb").read()
if d[:4] not in (b"KRNL", b"PARM"): sys.exit("STOP: %s is not a KRNL container" % sys.argv[1])
n, = struct.unpack("<I", d[4:8])
raw = gzip.decompress(d[8:8 + n]); i = 0
while raw[i:i + 6] == b"070701":
    namesz = int(raw[i + 94:i + 102], 16); filesz = int(raw[i + 54:i + 62], 16)
    nm = raw[i + 110:i + 110 + namesz - 1].decode("utf8", "replace")
    off = (i + 110 + namesz + 3) // 4 * 4
    if nm == "init":
        em = int.from_bytes(raw[off + 18:off + 20], "little")
        print({40: "armeabi-v7a", 183: "arm64-v8a", 3: "x86", 62: "x86_64"}.get(em, "unknown"))
        sys.exit(0)
    i = (off + filesz + 3) // 4 * 4
sys.exit("STOP: the ramdisk holds no init binary")
PY
)
case $(uname -m) in x86_64) HOSTABI=x86_64 ;; aarch64) HOSTABI=arm64-v8a ;; *) echo "STOP: unsupported host arch $(uname -m)"; exit 1 ;; esac
[ -d "lib/$initarch" ] || { echo "STOP: $APK has no lib/$initarch (the ramdisk init is $initarch)"; exit 1; }
echo "   ramdisk init arch: $initarch ; host tool arch: $HOSTABI"
cp "lib/$HOSTABI/libmagiskboot.so" magiskboot; chmod 755 magiskboot
cp "lib/$initarch/libmagiskinit.so" magiskinit
cp "lib/$initarch/libmagisk.so"     magisk
cp "lib/$initarch/libinit-ld.so"    init-ld
cp assets/stub.apk                  stub.apk
echo "   Magisk APK sha256: $(sha256sum "$APK" | cut -d' ' -f1)"

echo "== 2. take the ramdisk out of the KRNL container"
python3 "$MKKRNL" verify "$RAMDISK"
python3 "$MKKRNL" unpack "$RAMDISK" stock.cpio.gz
gzip -dc stock.cpio.gz > ramdisk.cpio
cp -a ramdisk.cpio ramdisk.cpio.orig
if gzip -n -9 -c ramdisk.cpio | cmp -s - stock.cpio.gz; then
    echo "   stock ramdisk gzips back byte-identical with gzip -n -9"
else
    echo "   NOTE: gzip -n -9 does not reproduce the stock bytes; the container is CRC-checked below anyway"
fi
cpio_list ramdisk.cpio | sed 's/^/      /'

echo "== 3. confirm it is a stock ramdisk"
rc=0; ./magiskboot cpio ramdisk.cpio test || rc=$?
[ "$rc" = 0 ] || { echo "STOP: magiskboot test says this ramdisk is not stock (exit $rc)"; exit 1; }
echo "   magiskboot cpio test: stock"

echo "== 4. patch the ramdisk (KEEPVERITY=$KEEPVERITY KEEPFORCEENCRYPT=$KEEPFORCEENCRYPT RECOVERYMODE=$RECOVERYMODE)"
./magiskboot compress=xz magisk   magisk.xz
./magiskboot compress=xz stub.apk stub.xz
./magiskboot compress=xz init-ld  init-ld.xz
# PREINITDEVICE: magiskinit uses it to create $MAGISKTMP/.magisk/device/preinit, and Magisk's own
# env_check (assets/app_functions.sh) returns 2 without that block device - the app then shows
# "Requires additional setup / your device needs reflash Magisk" on every start. Upstream
# boot_patch.sh fills it in with `magisk --preinit-device` because it runs on the device; building
# on a host cannot, so the name is read out of the package's own partition table instead: the
# kernel numbers blkdevparts entries in list order, so the 1-based position of the userdata entry
# is its /dev/mmcblk0pN suffix. (find_preinit_device() in native/src/core/mount.rs would pick
# /data here, because ro.crypto.state is "unsupported", i.e. the data partition is not encrypted.)
# A package given as a bare ramdisk image carries no device tree, so those need
# PREINITDEVICE=<name> from the caller.
if [ -z "${PREINITDEVICE:-}" ]; then
    PREINITDEVICE=$(python3 - "$PKG" "$ROOT/release-build" <<'PY'
import importlib.util, os, sys
package, lib = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("derive_layout", os.path.join(lib, "derive-layout.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
try:
    order = m.build_dtb_layout(package)["dtb_order"]
except Exception as e:
    sys.stderr.write("%s\n" % e)
    raise SystemExit(1)
try:
    n = order.index("userdata") + 1
except ValueError:
    sys.stderr.write("the blkdevparts table has no userdata entry: %s\n" % " ".join(order))
    raise SystemExit(1)
print("mmcblk0p%d" % n)
PY
) || true
fi
[ -n "$PREINITDEVICE" ] || { echo "STOP: cannot derive PREINITDEVICE from $PKG/images/resource.img."; echo "      pass it explicitly: PREINITDEVICE=mmcblk0pN $0 ..."; exit 1; }
echo "   PREINITDEVICE=$PREINITDEVICE"
printf 'KEEPVERITY=%s\nKEEPFORCEENCRYPT=%s\nRECOVERYMODE=%s\nVENDORBOOT=%s\nPREINITDEVICE=%s\n' "$KEEPVERITY" "$KEEPFORCEENCRYPT" "$RECOVERYMODE" "${VENDORBOOT:-false}" "$PREINITDEVICE" > config
chmod 644 config
./magiskboot cpio ramdisk.cpio \
    "add 0750 init magiskinit" \
    "mkdir 0750 overlay.d" \
    "mkdir 0750 overlay.d/sbin" \
    "add 0644 overlay.d/sbin/magisk.xz magisk.xz" \
    "add 0644 overlay.d/sbin/stub.xz stub.xz" \
    "add 0644 overlay.d/sbin/init-ld.xz init-ld.xz" \
    "patch" \
    "backup ramdisk.cpio.orig" \
    "mkdir 000 .backup" \
    "add 000 .backup/.magisk config"

echo "== 5. check the result"
rc=0; ./magiskboot cpio ramdisk.cpio test || rc=$?
[ "$rc" = 1 ] || { echo "STOP: magiskboot does not report the ramdisk as Magisk patched (exit $rc)"; exit 1; }
for e in init .backup/.magisk .backup/init.xz overlay.d/sbin/magisk.xz overlay.d/sbin/stub.xz overlay.d/sbin/init-ld.xz; do
    cpio_list ramdisk.cpio | grep -q " $e " || { echo "STOP: $e missing after patching"; exit 1; }
    echo "   present: $e"
done
if [ "$KEEPFORCEENCRYPT" = true ]; then
    cpio_extract() { python3 -c "
import sys
raw = open(sys.argv[1], 'rb').read(); i = 0
while raw[i:i+6] == b'070701':
    namesz = int(raw[i+94:i+102], 16); fsz = int(raw[i+54:i+62], 16)
    nm = raw[i+110:i+110+namesz-1].decode('utf8', 'replace')
    off = (i + 110 + namesz + 3) // 4 * 4
    if nm == sys.argv[2]:
        sys.stdout.buffer.write(raw[off:off+fsz]); break
    i = (off + fsz + 3) // 4 * 4
" "$1" "$2"; }
    cpio_extract ramdisk.cpio.orig fstab.rk30board > fstab.stock
    cpio_extract ramdisk.cpio      fstab.rk30board > fstab.now
    cmp fstab.stock fstab.now && echo "   fstab.rk30board is byte-identical to the stock one"
fi

echo "== 6. repack into a KRNL container"
gzip -n -9 -c ramdisk.cpio > patched.cpio.gz
python3 "$MKKRNL" pack patched.cpio.gz "$OUT"
python3 "$MKKRNL" verify "$OUT"
sz=$(stat -c %s "$OUT")
[ "$sz" -le 33554432 ] || { echo "STOP: $OUT is $sz B, the boot partition holds 33554432 B"; exit 1; }
echo "   $OUT: $sz B (boot partition limit 33554432 B)"

echo "== 7. round trip: read the produced file back"
python3 "$MKKRNL" unpack "$OUT" rt.cpio.gz
gzip -dc rt.cpio.gz > rt.cpio
rc=0; ./magiskboot cpio rt.cpio test || rc=$?
[ "$rc" = 1 ] || { echo "STOP: the round-tripped ramdisk is not Magisk patched (exit $rc)"; exit 1; }
cpio_list rt.cpio | grep -q " init " && echo "   init present in the round trip (magiskinit is $(stat -c %s magiskinit) B)"
sha256sum "$OUT"

echo
echo "Done. To use it, write it where flash.sh writes images/ramdisk.img (tool LBA 0x16000):"
echo "  rkdeveloptool wl 0x16000 $(basename "$OUT")"
echo "After that the tablet boots with Magisk; open the Magisk app once to finish the app side."
