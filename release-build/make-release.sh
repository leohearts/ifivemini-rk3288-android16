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
sed -e 's/^LAYOUT=@LAYOUT@$/LAYOUT=gsi/' -e 's/@META_LBA@/0x692000/' -e 's/@UD_LBA@/0x6ba000/' "$HERE/flash.sh.src" > "$T/flash.sh"; chmod +x "$T/flash.sh"
python3 "$HERE/guard-release.py" "$T/images/resource.img" "$T/images/super.img" "$T/flash.sh"
sed "s/{{DATE}}/$DATE/g" "$HERE/README-gsi.md.tmpl" > "$T/README.md"
{ echo "Build date: $DATE"; echo "Layout: gsi (SUPER 0x92000, META 0x692000, UD 0x6ba000)"; ( cd "$T" && sha256sum images/* loader/* ); } > "$T/BUILD-INFO.txt"
# SHA256SUMS covers the flashed payload only: images/*.img and loader/*.bin (flash.sh runs sha256sum -c on it)
( cd "$T" && find . -type f \( -path './images/*.img' -o -path './loader/*.bin' \) -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
mkdir -p "$TOP/release"; rm -f "$TOP/release/$NAME.zip"
( cd "$S" && zip -qr -X "$TOP/release/$NAME.zip" "$NAME" )
( cd "$TOP/release" && sha256sum "$NAME.zip" > "$NAME.zip.sha256" && unzip -tq "$NAME.zip" && cat "$NAME.zip.sha256" )
