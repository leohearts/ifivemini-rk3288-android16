#!/bin/bash
# flashX: write kernel container (LBA 0xE000), resource image (LBA 0x6000) and optional
# ramdisk container (LBA 0x16000) to the device in maskrom, read back and cmp each one.
# Only those LBA ranges are written. Reset only if --rd is given.
# Usage: flashX.sh --kernel <krnl> --res <img> [--ramdisk <krnl>] [--rd]
#        flashX.sh --system <img> [--meta <img> --udhead <img>] [--fullcmp] [--rd]
# --system writes a raw liblp super image into the system partition only
# (GSI layout: LBA 0x92000 .. 0x691FFF, 0x600000 sectors = 3072 MiB). It cannot be combined with
# --kernel/--res/--ramdisk. Optional, only together with --system, after the super is verified:
#   --meta <img>    exactly 16 MiB ext4 (label metadata) -> LBA 0x692000 (0x8000 sectors)
#   --udhead <img>  exactly 1 MiB of zeros -> LBA 0x6BA000 (userdata head, forces first-boot format)
# Every input needs a basename-format sha256 sidecar (<file>.sha256) that matches.
# RKDEVELOPTOOL overrides the tool path (used for offline dry runs).
set -u
RK=${RKDEVELOPTOOL:-/tmp/rkdev/usr/bin/rkdeveloptool}
KRN=""; RES=""; RAMD=""; MODE=""; SYS=""; FULL=""; META=""; UDH=""
usage() { echo "STOP: usage: $0 --kernel <krnl> --res <img> [--ramdisk <krnl>] [--rd]"; echo "STOP: usage: $0 --system <img> [--meta <img> --udhead <img>] [--fullcmp] [--rd]"; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) [ $# -ge 2 ] || usage; KRN=$2; shift 2 ;;
    --res) [ $# -ge 2 ] || usage; RES=$2; shift 2 ;;
    --ramdisk) [ $# -ge 2 ] || usage; RAMD=$2; shift 2 ;;
    --system) [ $# -ge 2 ] || usage; SYS=$2; shift 2 ;;
    --meta) [ $# -ge 2 ] || usage; META=$2; shift 2 ;;
    --udhead) [ $# -ge 2 ] || usage; UDH=$2; shift 2 ;;
    --fullcmp) FULL=1; shift ;;
    --rd) MODE=rd; shift ;;
    *) usage ;;
  esac
done
if [ -n "$SYS" ]; then
  [ -z "$KRN$RES$RAMD" ] || { echo "STOP: --system cannot combine with --kernel/--res/--ramdisk"; exit 64; }
else
  [ -n "$KRN" ] && [ -n "$RES" ] || usage
  [ -z "$FULL$META$UDH" ] || { echo "STOP: --fullcmp/--meta/--udhead only apply to --system"; exit 64; }
fi
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
prewl() { # file want-magic-hex|"" : refuse sparse (wl would expand it unbounded) and wrong magic
  local m; m=$(xxd -p -l 4 "$1")
  [ "$m" != ed26ff3a ] || { echo "STOP: ${1##*/} starts with Android sparse magic; wl would write unbounded"; exit 3; }
  [ -z "$2" ] || [ "$m" = "$2" ] || { echo "STOP: ${1##*/} magic $m != $2"; exit 3; }
}

rawwl() { # lba file label : fixed-target raw write (whole file, size already checked) + readback cmp
  local lba=$1 f=$2 label=$3 size secs out rc rb="$WORKDIR/flashSys_raw_rb.bin"
  size=$(stat -c %s "$f"); secs=$(( (size + 511) / 512 ))
  echo "--- raw $label @ $lba : $size B ($secs sectors) ---"
  out=$(timeout 300 $RK wl "$lba" "$f" 2>&1); rc=$?
  [ $rc -eq 0 ] || { echo "$out" | tail -n 2; echo "STOP: wl $label @ $lba failed rc=$rc"; exit 4; }
  rm -f "$rb"
  timeout 300 $RK rl "$lba" "$secs" "$rb" >/dev/null 2>&1 || { echo "STOP: readback $label failed"; exit 4; }
  cmp -n "$size" "$f" "$rb" || { echo "STOP: cmp mismatch $label"; exit 4; }
  rm -f "$rb"; echo "CMP OK raw $label"
}

sys_flash() { # --system path: gated raw super image into the system partition only
  local SLBA=$((0x92000)) SSECS=$((0x600000)) CH=16777216
  local SMAX=$((SSECS * 512)) T0=$SECONDS
  local size n i off len lba secs rc out got r
  local chunk="$WORKDIR/flashSys_chunk.bin" rb="$WORKDIR/flashSys_rb.bin"
  local -a vs=()
  gate "$SYS" "$SYS.sha256"
  size_max "$SYS" "$SMAX" system
  size=$(stat -c %s "$SYS")
  if [ -n "$META$UDH" ]; then
    [ -n "$META" ] && [ -n "$UDH" ] || { echo "STOP: --meta and --udhead must be given together"; exit 64; }
    gate "$META" "$META.sha256"; gate "$UDH" "$UDH.sha256"
    [ "$(stat -c %s "$META")" -eq 16777216 ] || { echo "STOP: --meta must be exactly 16 MiB"; exit 3; }
    [ "$(xxd -p -s 1080 -l 2 "$META")" = 53ef ] || { echo "STOP: --meta has no ext4 magic"; exit 3; }
    prewl "$META" ""
    [ "$(stat -c %s "$UDH")" -eq 1048576 ] || { echo "STOP: --udhead must be exactly 1 MiB"; exit 3; }
    cmp -s "$UDH" <(head -c 1048576 /dev/zero) || { echo "STOP: --udhead is not all zeros"; exit 3; }
  fi
  [ "$(xxd -p -s 4096 -l 4 "$SYS")" = 67446c61 ] || { echo "STOP: ${SYS##*/} lacks liblp magic at offset 4096"; exit 3; }
  n=$(( (size + CH - 1) / CH ))
  for ((i = 0; i < n; i++)); do # each chunk is a separate wl file: none may start with sparse magic
    [ "$(xxd -p -s $((i * CH)) -l 4 "$SYS")" != ed26ff3a ] || { echo "STOP: ${SYS##*/} chunk $((i + 1))/$n starts with Android sparse magic"; exit 3; }
  done

  # maskrom check
  lsusb | grep -q 2207:320a || { echo "STOP: no maskrom device 2207:320a"; exit 1; }
  timeout 30 $RK ld || { echo "NO DEVICE"; exit 1; }

  # read-only pre-write probe: 9 sectors from 0x92000 cover byte 4096 (sector 8); must already be an old super
  rm -f "$WORKDIR/flashSys_base.bin"
  timeout 30 $RK rl $(printf '0x%x' $SLBA) 9 "$WORKDIR/flashSys_base.bin" >/dev/null 2>&1 || { echo "STOP: base probe rl 0x92000 failed"; exit 1; }
  got=$(xxd -p -s 4096 -l 4 "$WORKDIR/flashSys_base.bin")
  echo "base 0x92000+4096 magic=$got want=67446c61"
  [ "$got" = 67446c61 ] || { echo "STOP: device super magic $got != 67446c61; no writes"; exit 2; }

  gate "$SYS" "$SYS.sha256"
  echo "--- system $size B in $n chunk(s) of $CH B @ 0x92000 ---"
  for ((i = 0; i < n; i++)); do
    off=$((i * CH)); len=$((size - off)); [ "$len" -le "$CH" ] || len=$CH
    secs=$(( (len + 511) / 512 ))
    lba=$(printf '0x%x' $((SLBA + off / 512)))
    [ $((SLBA + off / 512 + secs)) -le $((SLBA + SSECS)) ] || { echo "STOP: chunk $i outside system range"; exit 4; }
    dd if="$SYS" of="$chunk" bs=512 skip=$((off / 512)) count=$secs status=none || { echo "STOP: dd chunk $i"; exit 4; }
    prewl "$chunk" ""
    out=$(timeout 300 $RK wl "$lba" "$chunk" 2>&1); rc=$?
    [ $rc -eq 0 ] || { echo "$out" | tail -n 2; echo "STOP: wl chunk $((i + 1))/$n @ $lba failed rc=$rc"; exit 4; }
    echo "WROTE chunk $((i + 1))/$n lba=$lba off=$((off >> 20))MiB len=$len elapsed=$((SECONDS - T0))s"
  done
  rm -f "$chunk"

  # verify: first 64 MiB (4 chunks) + 3 random later chunks; --fullcmp verifies all
  if [ -n "$FULL" ]; then
    for ((i = 0; i < n; i++)); do vs+=("$i"); done
  else
    for ((i = 0; i < n && i < 4; i++)); do vs+=("$i"); done
    if [ "$n" -gt 4 ]; then
      for r in $(shuf -i 4-$((n - 1)) -n 3); do vs+=("$r"); done
    fi
  fi
  echo "VERIFY ${#vs[@]} of $n chunk(s): ${vs[*]}"
  for i in "${vs[@]}"; do
    off=$((i * CH)); len=$((size - off)); [ "$len" -le "$CH" ] || len=$CH
    secs=$(( (len + 511) / 512 ))
    lba=$(printf '0x%x' $((SLBA + off / 512)))
    rm -f "$rb"
    timeout 300 $RK rl "$lba" "$secs" "$rb" >/dev/null 2>&1 || { echo "STOP: readback chunk $((i + 1)) failed"; exit 4; }
    cmp -s -n "$len" -i "$off:0" "$SYS" "$rb" || { echo "STOP: cmp mismatch system chunk $((i + 1))/$n @ $lba"; exit 4; }
    echo "CMP OK chunk $((i + 1))/$n lba=$lba elapsed=$((SECONDS - T0))s"
  done
  rm -f "$rb"

  if [ -n "$META" ]; then
    rawwl 0x692000 "$META" metadata
    rawwl 0x6BA000 "$UDH" udhead
  fi

  echo "FLASHSYS WRITTEN system=${SYS##*/} bytes=$size chunks=$n verified=${#vs[@]} elapsed=$((SECONDS - T0))s"
  if [ "$MODE" = rd ]; then
    timeout 30 $RK rd || { echo "STOP: reset failed"; exit 5; }
    echo "RESET ISSUED"
  else
    echo "Not reset. Re-run with --rd to reset."
  fi
  exit 0
}

if [ -n "$SYS" ]; then sys_flash; fi

gate "$KRN" "$KRN.sha256"
gate "$RES" "$RES.sha256"
size_max "$KRN" 16777216 krnl
size_max "$RES" 16777216 res
prewl "$KRN" 4b524e4c
prewl "$RES" 52534345
LBAS="0x6000 0xE000"
if [ -n "$RAMD" ]; then
  gate "$RAMD" "$RAMD.sha256"
  size_max "$RAMD" 16777216 ramdisk
  prewl "$RAMD" 4b524e4c
  LBAS="$LBAS 0x16000"
fi

# maskrom check
lsusb | grep -q 2207:320a || { echo "STOP: no maskrom device 2207:320a"; exit 1; }
timeout 30 $RK ld || { echo "NO DEVICE"; exit 1; }

# read-only base probe: each LBA must already hold its expected magic, else STOP with no writes
for l in $LBAS; do
  case $l in
    0x6000) want=52534345 ;;          # "RSCE" resource container
    0xE000|0x16000) want=4b524e4c ;;  # "KRNL" kernel / ramdisk container
  esac
  rm -f "$WORKDIR/flashX_base_$l.bin"
  timeout 30 $RK rl $l 8 "$WORKDIR/flashX_base_$l.bin" >/dev/null 2>&1 || { echo "STOP: base probe rl $l failed"; exit 1; }
  got=$(xxd -p -l 4 "$WORKDIR/flashX_base_$l.bin")
  echo "base $l magic=$got want=$want"
  [ "$got" = "$want" ] || { echo "STOP: base $l magic $got != $want; no writes"; exit 2; }
done

wr() { # lba file label want-magic
  local lba=$1 f=$2 label=$3 size secs out rc
  gate "$f" "$f.sha256"
  prewl "$f" "$4"
  size=$(stat -c %s "$f") || return 1
  secs=$(( (size + 511) / 512 ))
  echo "--- $label @ $lba : $size B ($secs sectors) ---"
  out=$(timeout 300 $RK wl "$lba" "$f" 2>&1); rc=$?
  echo "$out" | tail -n 2
  [ $rc -eq 0 ] || { echo "STOP: write $label failed rc=$rc"; exit 4; }
  rm -f "$WORKDIR/flashX_rb_$label.bin"
  timeout 300 $RK rl "$lba" "$secs" "$WORKDIR/flashX_rb_$label.bin" >/dev/null 2>&1 || { echo "STOP: readback $label failed"; exit 4; }
  cmp -n "$size" "$f" "$WORKDIR/flashX_rb_$label.bin" || { echo "STOP: cmp mismatch $label"; exit 4; }
  echo "CMP OK $label"
}
wr 0x6000 "$RES" res 52534345
wr 0xE000 "$KRN" krnl 4b524e4c
if [ -n "$RAMD" ]; then
  wr 0x16000 "$RAMD" ramdisk 4b524e4c
fi

R=none; [ -n "$RAMD" ] && R=${RAMD##*/}
echo "FLASHX WRITTEN res=${RES##*/} krnl=${KRN##*/} ramdisk=$R"
if [ "$MODE" = rd ]; then
  timeout 30 $RK rd || { echo "STOP: reset failed"; exit 5; }
  echo "RESET ISSUED"
else
  echo "Not reset. Re-run with --rd to reset."
fi
