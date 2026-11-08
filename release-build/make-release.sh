#!/bin/bash
# make-release.sh <inputs-dir> [DATE]
# Builds release/ifive-mini4s-android16-gsi-<DATE>.zip from:
#   out/kernel-gsi-release/kernel.img   (./build-kernel.sh)
#   release-build/resource-release-gsi.img (./release-build/build-resource.sh)
#   <inputs-dir>/super.img       GSI super (system = TrebleDroid a64_bvS GSI, vendor = Tinker Board A11 vendor + vendor-changes/)
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
rm -rf "$S"; mkdir -p "$T/images" "$T/loader" "$T/tools"
cp "$RES" "$T/images/resource.img"; cp "$KRN" "$T/images/kernel.img"
cp "$IN/ramdisk.img" "$IN/super.img" "$IN/metadata.img" "$IN/userdata-head-zero.img" "$T/images/"
cp "$LOADER" "$T/loader/"; cp "$RK" "$T/tools/rkdeveloptool"
# the rescue script needs the device tree tools to derive the partition map
cp "$HERE/tools/dtc" "$HERE/tools/resource_tool" "$T/tools/"
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
# files of every board and the loader-area script (flash.sh and restore.sh
# both run "sha256sum -c" on it)
( cd "$T" && find . -type f \( -path './images/*.img' -o -path './loader/*.bin' -o -path './devices/*/*' -o -path './write-loader-head.sh' \) -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
python3 "$HERE/guard-release.py" "$T/images/resource.img" "$T/images/super.img" "$T/flash.sh"
sed "s/{{DATE}}/$DATE/g" "$HERE/README-gsi.md.tmpl" > "$T/README.md"
{ echo "Build date: $DATE"; echo "Layout: gsi (SUPER 0x92000, META 0x692000, UD 0x6ba000)"; ( cd "$T" && sha256sum images/* loader/* ); } > "$T/BUILD-INFO.txt"
mkdir -p "$TOP/release"; rm -f "$TOP/release/$NAME.zip"
( cd "$S" && zip -qr -X "$TOP/release/$NAME.zip" "$NAME" )
( cd "$TOP/release" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" && unzip -tq "$NAME.zip" && cat "$NAME.zip.sha256" )
