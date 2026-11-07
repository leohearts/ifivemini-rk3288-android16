#!/bin/bash
# flashX.sh (recreated for Lead-2 after /tmp/rk3288-port/scripts was lost).
# Kernel/resource/ramdisk writer for a device in maskrom (2207:320a). Modelled on gsi/flashX-gsi.sh
# (kernel path) and release/build/flash.sh.src (LBAs: RES 0x6000 "RSCE", KRN 0xE000 "KRNL", RD 0x16000 "KRNL").
# Usage: flashX.sh --kernel <krnl> --res <img> --ramdisk <krnl-container> [--rd]
# The ramdisk is written raw (as images/ramdisk.img, a KRNL container), same as flash.sh.src.
# Every input needs a basename-format sha256 sidecar (<file>.sha256) that matches.
# Writes only those three LBA ranges. Reset only if --rd is given. No retries.
set -u
RK=${RKDEVELOPTOOL:-/tmp/rkdev/usr/bin/rkdeveloptool}
KRN=""; RES=""; RAMD=""; MODE=""
usage() { echo "STOP: usage: $0 --kernel <krnl> --res <img> --ramdisk <krnl> [--rd]"; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) [ $# -ge 2 ] || usage; KRN=$2; shift 2 ;;
    --res) [ $# -ge 2 ] || usage; RES=$2; shift 2 ;;
    --ramdisk) [ $# -ge 2 ] || usage; RAMD=$2; shift 2 ;;
    --rd) MODE=rd; shift ;;
    *) usage ;;
  esac
done
[ -n "$KRN" ] && [ -n "$RES" ] && [ -n "$RAMD" ] || usage
[ -x "$RK" ] || { echo "STOP: rkdeveloptool missing ($RK)"; exit 2; }
DATA_R=/run/media/leohearts/Data/rk3288-a11
WORKDIR=${WORKDIR:-$DATA_R/scratch/flash}; mkdir -p "$WORKDIR"

gate() { # file sidecar
  [ -f "$1" ] && [ -f "$2" ] || { echo "STOP: missing $1 or sidecar $2"; exit 3; }
  read -r want name < "$2"
  name=${name#\*}
  [ "$name" = "${1##*/}" ] || { echo "STOP: sidecar $2 names '$name', file is ${1##*/}"; exit 3; }
  got=$(sha256sum "$1" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { echo "STOP: sha mismatch ${1##*/} got=$got want=$want"; exit 3; }
  echo "SHA OK ${1##*/} ${want:0:8}"
}
size_max() { # file max-bytes label
  local s; s=$(stat -c %s "$1") || { echo "STOP: stat $1"; exit 3; }
  [ "$s" -le "$2" ] || { echo "STOP: $3 is $s B, slot holds $2 B"; exit 3; }
}
prewl() { # file want-magic-hex : refuse sparse (wl would expand unbounded) and wrong magic
  local m; m=$(xxd -p -l 4 "$1")
  [ "$m" != ed26ff3a ] || { echo "STOP: ${1##*/} starts with Android sparse magic"; exit 3; }
  [ "$m" = "$2" ] || { echo "STOP: ${1##*/} magic $m != $2"; exit 3; }
}

gate "$KRN" "$KRN.sha256"
gate "$RES" "$RES.sha256"
gate "$RAMD" "$RAMD.sha256"
size_max "$KRN" 16777216 krnl
size_max "$RES" 16777216 res
size_max "$RAMD" 16777216 ramdisk
prewl "$KRN" 4b524e4c
prewl "$RES" 52534345
prewl "$RAMD" 4b524e4c

# maskrom check
lsusb | grep -q 2207:320a || { echo "STOP: no maskrom device 2207:320a"; exit 1; }
timeout 30 $RK ld || { echo "NO DEVICE"; exit 1; }

# read-only base probe: each LBA must already hold its expected magic, else STOP with no writes
for l in 0x6000 0xE000 0x16000; do
  case $l in
    0x6000) want=52534345 ;;          # "RSCE"
    0xE000|0x16000) want=4b524e4c ;;  # "KRNL"
  esac
  rm -f "$WORKDIR/flashX_base_$l.bin"
  timeout 30 $RK rl $l 8 "$WORKDIR/flashX_base_$l.bin" >/dev/null 2>&1 || { echo "STOP: base probe rl $l failed"; exit 1; }
  got=$(xxd -p -l 4 "$WORKDIR/flashX_base_$l.bin")
  echo "base $l magic=$got want=$want"
  [ "$got" = "$want" ] || { echo "STOP: base $l magic $got != $want; no writes"; exit 2; }
done

wr() { # lba file label
  local lba=$1 f=$2 label=$3 size secs out rc rb="$WORKDIR/flashX_rb_$3.bin"
  size=$(stat -c %s "$f") || return 1
  secs=$(( (size + 511) / 512 ))
  echo "--- $label @ $lba : $size B ($secs sectors) ---"
  out=$(timeout 300 $RK wl "$lba" "$f" 2>&1); rc=$?
  echo "$out" | tail -n 2
  [ $rc -eq 0 ] || { echo "STOP: write $label failed rc=$rc"; exit 4; }
  rm -f "$rb"
  timeout 300 $RK rl "$lba" "$secs" "$rb" >/dev/null 2>&1 || { echo "STOP: readback $label failed"; exit 4; }
  cmp -n "$size" "$f" "$rb" || { echo "STOP: cmp mismatch $label"; exit 4; }
  rm -f "$rb"; echo "CMP OK $label"
}
wr 0x6000 "$RES" res
wr 0xE000 "$KRN" krnl
wr 0x16000 "$RAMD" ramdisk

echo "FLASHX WRITTEN res=${RES##*/} krnl=${KRN##*/} ramdisk=${RAMD##*/}"
if [ "$MODE" = rd ]; then
  timeout 30 $RK rd || { echo "STOP: reset failed"; exit 5; }
  echo "RESET ISSUED"
else
  echo "Not reset. Re-run with --rd to reset."
fi
