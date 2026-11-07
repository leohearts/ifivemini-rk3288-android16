#!/bin/bash
# make-release.sh [a11|gsi12|gsi16]
# a11 : assemble release/stage (A11 resource, A11 flash.sh.src) from verified inputs.
# gsi12/gsi16 : build release/ifive-mini4s-android{12,16}-gsi-$GSI_DATE.zip from the GSI package trees
#   in scratch/acc6 with images/resource.img replaced by resource-release-gsi.img (GSI blkdevparts).
# Every package runs guard-release.py (super fits system; flash.sh LBAs match the resource layout).
set -eu
A=/run/media/leohearts/Data/rk3288-a11
R=$A/release; B=$R/build; S=$R/stage
VARIANT=${1:-a11}
GUARD="python3 $B/guard-release.py"
chk() { ( cd "$(dirname "$1")" && sha256sum -c "$(basename "$1").sha256" >/dev/null ) || { echo "STOP: sidecar $1"; exit 3; }; }

case $VARIANT in
gsi16)
  GSI_DATE=${GSI_DATE:-2026-11-07}
  NAME=ifive-mini4s-android16-gsi-$GSI_DATE
  GSI_SRC=$A/scratch/acc6/ifive-mini4s-android16-gsi-2026-11-06   # ramdisk only
  SUPER=${GSI16_SUPER:-$A/gsi/new/super-td16n.img}                  # HWC2 + chgpolicy seclabel fix (td16n)
  KRN=$A/work-rl5/kernel-release-rl5bj.krnl
  MKKRNL=$B/tools/mkkrnl.py
  RAMDISK=$GSI_SRC/images/ramdisk.img
  META_IN=$A/gsi/metadata-16M.img; UDZ_IN=$A/gsi/zero-1M.img
  LOADER_SRC=$B/loader/RK3288UbootLoader_V2.30.10.bin
  chk $B/resource-release-gsi.img; chk $KRN; chk $LOADER_SRC
  for f in $SUPER $A/gsi/metadata-16M.img $A/gsi/zero-1M.img; do [ -f $f ] || { echo "STOP: missing $f"; exit 3; }; done
  [ -f $RAMDISK ] || { echo "STOP: missing $RAMDISK"; exit 3; }
  python3 $MKKRNL verify $KRN
  T=$S/gsi/$NAME
  rm -rf $S/gsi; mkdir -p $T/images $T/loader
  cp $B/resource-release-gsi.img $T/images/resource.img
  cp $KRN $T/images/kernel.img
  cp $RAMDISK $T/images/ramdisk.img
  cp $SUPER $T/images/super.img
  cp $META_IN $T/images/metadata.img
  cp $UDZ_IN $T/images/userdata-head-zero.img
  cp $LOADER_SRC $T/loader/
  sed -e 's/^LAYOUT=@LAYOUT@$/LAYOUT=gsi/' -e 's/@META_LBA@/0x692000/' -e 's/@UD_LBA@/0x6ba000/' $B/flash.sh.src > $T/flash.sh
  chmod +x $T/flash.sh
  $GUARD $T/images/resource.img $T/images/super.img $T/flash.sh
  cp $B/README-gsi.md.tmpl $T/README.md
  sed -i "s/{{DATE}}/$GSI_DATE/g" $T/README.md
  printf 'Build date: %s\nSuper: %s sha256 %s\nKernel: kernel-release-rl5bj.krnl sha256 %s\nResource: resource-release-gsi.img sha256 %s\nRamdisk: scratch/acc6/ifive-mini4s-android16-gsi-2026-11-06/images/ramdisk.img sha256 %s\nLoader: RK3288UbootLoader_V2.30.10.bin sha256 %s\nLayout: gsi (SUPER 0x92000, META 0x692000, UD 0x6ba000)\n' \
    "$GSI_DATE" "$(basename $SUPER)" "$(sha256sum $SUPER | cut -d' ' -f1)" "$(sha256sum $KRN | cut -d' ' -f1)" \
    "$(sha256sum $B/resource-release-gsi.img | cut -d' ' -f1)" "$(sha256sum $RAMDISK | cut -d' ' -f1)" "$(sha256sum $LOADER_SRC | cut -d' ' -f1)" > $T/BUILD-INFO.txt
  ( cd $T && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
  rm -f $R/$NAME.zip $R/$NAME.zip.sha256
  ( cd $S/gsi && zip -r -X -q $R/$NAME.zip $NAME )
  ( cd $R && sha256sum $NAME.zip > $NAME.zip.sha256 && cat $NAME.zip.sha256 )
  echo "MADE $NAME.zip"
  exit 0 ;;
gsi12) echo "gsi12 removed: no GSI12 inputs in this cutover"; exit 2 ;;
a11) ;;
*) echo "usage: make-release.sh [a11|gsi12|gsi16]"; exit 2 ;;
esac

DATE=${RELEASE_DATE:-$(date +%F)}
NAME=ifive-mini4s-android11-$DATE
ZIP=$R/$NAME.zip
KBUILD=$A/kbuild-rl5-release
LOADER_SRC=$R/release/build/loader/RK3288UbootLoader_V2.30.10.bin
# A11 super: super18b = super18 with the product RRO product-partition auto-rotation value set to true (A11Sens.md).
# inputs (sidecar-checked)
chk $A/super2/super18f/super18f.img; chk $A/out/mk-ramdisk.krnl; chk $A/gsi/metadata-16M.img; chk $A/gsi/zero-1M.img; chk $B/resource-release.img; chk $A/work-rl5/kernel-release-rl5j.krnl
# kernel: kernel-release-rl5j.krnl (A11 kernel, sidecar-checked above). The GSI packages use kernel-release-rl5bj.krnl.
python3 /tmp/rk3288-port/scripts/mkkrnl.py verify $A/work-rl5/kernel-release-rl5j.krnl
rm -rf $S/images $S/loader $S/work; mkdir -p $S/images $S/loader $S/work
cp $A/work-rl5/kernel-release-rl5j.krnl $S/images/kernel.img
cp $B/resource-release.img $S/images/resource.img
cp $A/out/mk-ramdisk.krnl $S/images/ramdisk.img
cp $A/super2/super18f/super18f.img $S/images/super.img
cp $A/gsi/metadata-16M.img $S/images/metadata.img
cp $A/gsi/zero-1M.img $S/images/userdata-head-zero.img
cp $LOADER_SRC $S/loader/RK3288UbootLoader_V2.30.10.bin
cp $KBUILD/.config $S/kernel-release.config
cp $B/release.fragment $S/kernel-release.fragment
rmdir $S/work
sed -e 's/^LAYOUT=@LAYOUT@$/LAYOUT=a11/' -e 's/@META_LBA@/0x392000/' -e 's/@UD_LBA@/0x3BA000/' $B/flash.sh.src > $S/flash.sh
cp $B/kernel-uncommitted.txt $S/kernel-uncommitted-files.txt
# (kernel-uncommitted listing copied above)
$GUARD $S/images/resource.img $S/images/super.img $S/flash.sh
# package: zip root dir = $NAME; SHA256SUMS over package files (excluding itself)
A11T=$S/a11/$NAME; rm -rf $S/a11; mkdir -p $A11T
cp -a $S/images $S/loader $S/flash.sh $S/kernel-release.config $S/kernel-release.fragment $S/kernel-uncommitted-files.txt $A11T/
[ -f $S/BUILD-INFO.txt ] && cp $S/BUILD-INFO.txt $S/README.md $S/dry-run-comparison.txt $A11T/ || true
( cd $A11T && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
rm -f $ZIP $ZIP.sha256
( cd $S/a11 && zip -r -X -q $ZIP $NAME )
( cd $R && sha256sum $NAME.zip > $NAME.zip.sha256 && cat $NAME.zip.sha256 )
echo "MADE $NAME.zip"
