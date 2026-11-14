#!/bin/bash
# make-release.sh <inputs-dir> [DATE]
# Builds release/ifive-mini4s-android16-gsi-<DATE>.zip from:
#   out/kernel-gsi-release/kernel.img   (./build-kernel.sh)
#   release-build/resource-release-gsi.img (./release-build/build-resource.sh)
#   <inputs-dir>/super.img       GSI super (system = an Android 16 GSI, vendor = Tinker Board A11 vendor;
#                                the vendor region is patched with vendor-changes/ while packaging)
#   <inputs-dir>/ramdisk.img     Rockchip KRNL-packed boot ramdisk
#   <inputs-dir>/metadata.img    16 MiB empty ext4 metadata partition
#   <inputs-dir>/userdata-head-zero.img  1 MiB of zeros (clears the userdata superblock)
#   <inputs-dir>/rkdeveloptool   (optional) Linux x86_64 rkdeveloptool to bundle; default: the one in PATH is copied
# The release also gets the rescue part, built from the board definitions in
# release-build/boards/*.json and the stock backups they name:
#   devices/<board>/device.json          board id, display name, parameter LBAs
#   devices/<board>/parameter-p1.img     that board's p1 parameter partition image
#   devices/<board>/parameter-loader.img that board's loader-area parameter region
#   devices/<board>/head-8M.bin          that board's first 8 MiB of eMMC
#   devices/<board>/head-4M.bin          that board's first 4 MiB (idblock + u-boot.itb)
#   restore.sh                           restore of a wiped tablet (derives the write
#                                        map from the package, not from constants)
#   manifest.json                        the write map derived at build time
# The super/ramdisk/metadata images of the published release are inside the release zip on GitHub.
# Optional env:
#   MAGISK_APK=<Magisk.apk>  ship images/ramdisk.img patched with that Magisk (scripts/make-magisk-boot.sh)
#   SYSTEM_NAME=<text>       the GSI named in README.md (default: TrebleDroid a64_bvS)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd)
IN=${1:?inputs dir}; DATE=${2:-$(date +%F)}
NAME=ifive-mini4s-android16-gsi-$DATE
KRN=$TOP/out/kernel-gsi-release/kernel.img
RES=$HERE/resource-release-gsi.img
LOADER=$HERE/loader/RK3288UbootLoader_V2.30.10.bin
for f in $KRN $RES $LOADER $IN/super.img $IN/ramdisk.img $IN/metadata.img $IN/userdata-head-zero.img; do [ -f "$f" ] || { echo "STOP: missing $f"; exit 3; }; done
python3 "$HERE/tools/mkkrnl.py" verify "$KRN"; python3 "$HERE/tools/mkkrnl.py" verify "$IN/ramdisk.img"
RK=${IN}/rkdeveloptool; [ -x "$RK" ] || RK=$(command -v rkdeveloptool) || { echo "STOP: no rkdeveloptool to bundle"; exit 3; }
S=$TOP/out/release; T=$S/$NAME
# never wipe more than the one build directory this run owns
[ "${T#$S/}" != "$T" ] && [ "$T" != "$S" ] || { echo "STOP: refusing to remove $T"; exit 3; }
case "$IN" in "$T"|"$T"/*) echo "STOP: inputs dir $IN is inside the output dir $T"; exit 3 ;; esac
rm -rf "$T"; mkdir -p "$T/images" "$T/loader" "$T/tools"
cp "$RES" "$T/images/resource.img"; cp "$KRN" "$T/images/kernel.img"
cp "$IN/super.img" "$IN/metadata.img" "$IN/userdata-head-zero.img" "$T/images/"
if [ -n "${MAGISK_APK:-}" ]; then
  "$TOP/scripts/make-magisk-boot.sh" "$IN/ramdisk.img" "$MAGISK_APK" "$T/images/ramdisk.img"
  python3 "$HERE/tools/mkkrnl.py" verify "$T/images/ramdisk.img"
  BOOT_DESC="patched with Magisk $(unzip -p "$MAGISK_APK" assets/util_functions.sh | sed -n 's/^MAGISK_VER=.\(.*\).$/\1/p') by scripts/make-magisk-boot.sh (APK sha256 $(sha256sum "$MAGISK_APK" | cut -c1-16)...)"
else
  cp "$IN/ramdisk.img" "$T/images/"
  BOOT_DESC="the generic ramdisk, without Magisk"
fi
# the vendor region of the copied super gets vendor-changes/ (keeps every
# other region of super byte-exact)
echo "== patching super vendor with vendor-changes/ =="
"$HERE/splice-vendor.sh" "$T/images/super.img"
cp "$LOADER" "$T/loader/"; cp "$RK" "$T/tools/rkdeveloptool"
cp "$HERE/loader/rk3288_loader_v1.12.263.bin" "$T/loader/"   # Maskrom db file (BOOT-merged ddr+miniloader; UbootLoader.bin is NOT accepted by db)
# the rescue script needs the device tree tools to derive the partition map
cp "$HERE/tools/dtc" "$HERE/tools/resource_tool" "$T/tools/"
# chunked-write/resume library sourced by flash.sh and restore.sh (both die
# without it, so it must ship next to them in every package)
cp "$HERE/lib-wl.inc" "$T/lib-wl.inc"
# rescue part (restore of a wiped tablet): built from the board definitions
if [ -d "$HERE/boards" ]; then
  STOCK_BACKUP_DIR=${STOCK_BACKUP_DIR:-} python3 "$HERE/make-restore.py" "$T" --boards-dir "$HERE/boards"
else
  echo "WARNING: $HERE/boards not found - the release has no rescue data and no restore.sh"
  echo "WARNING: a wiped tablet cannot be restored from this package"
fi
if [ -d "$T/devices" ] && [ -n "$(ls -A "$T/devices" 2>/dev/null)" ]; then
  cp "$HERE/restore-full.sh.src" "$T/restore.sh"; chmod +x "$T/restore.sh"
  # the loader area (below every rkdeveloptool LBA) is written by its own script
  cp "$HERE/write-loader-head.sh.src" "$T/write-loader-head.sh"; chmod +x "$T/write-loader-head.sh"
  # manifest.json: the write map derived from the package data, per board
  python3 "$HERE/make-manifest.py" "$T"
  # flash.sh takes its addresses from that manifest, so flash.sh and
  # restore.sh of the same package can never write an image to different places
  python3 "$HERE/make-flash.py" "$T" --template "$HERE/flash.sh.src" --output "$T/flash.sh" --layout gsi
else
  echo "WARNING: no rescue data - the release has no restore.sh"
  echo "WARNING: a wiped tablet cannot be restored from this package"
  python3 "$HERE/make-flash.py" "$T" --template "$HERE/flash.sh.src" --output "$T/flash.sh" --layout gsi
fi
# SHA256SUMS covers every shipped payload: images/*.img, loader/*.bin, the
# files of every board, the loader-area script and the shared chunked-write
# library (flash.sh and restore.sh both run "sha256sum -c" on it)
( cd "$T" && find . -type f \( -path './images/*.img' -o -path './loader/*.bin' -o -path './devices/*/*' -o -path './write-loader-head.sh' -o -path './lib-wl.inc' \) -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
python3 "$HERE/guard-release.py" "$T/images/resource.img" "$T/images/super.img" "$T/flash.sh"
sed -e "s/{{DATE}}/$DATE/g" -e "s|{{SYSTEM}}|${SYSTEM_NAME:-TrebleDroid a64_bvS}|g" -e "s|{{BOOT}}|$BOOT_DESC|g" \
  "$HERE/README-gsi.md.tmpl" > "$T/README.md"
{ echo "Build date: $DATE"; echo "Layout: gsi (SUPER 0x92000, META 0x692000, UD 0x6ba000)"; ( cd "$T" && sha256sum images/* loader/* ); } > "$T/BUILD-INFO.txt"
mkdir -p "$TOP/release"; rm -f "$TOP/release/$NAME.zip"
( cd "$S" && zip -qr -X "$TOP/release/$NAME.zip" "$NAME" )
( cd "$TOP/release" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" && unzip -tq "$NAME.zip" && cat "$NAME.zip.sha256" )
