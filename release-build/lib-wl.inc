# lib-wl.inc - chunked, throttled image writes with resume, shared by
# flash.sh and restore.sh.  This file defines functions; it is sourced, not
# executed (make-release.sh ships it next to both scripts).
#
# Why: this tablet's power stage drops the USB session during long writes - a
# 16 MiB wl can fail half-way and leave the partition half-written.  Every
# image is therefore written in WL_CHUNK-byte pieces (default 512 KiB) with
# WL_GAP seconds of quiet between the pieces, and every piece goes through
# the caller's existing wl_verify (write, read back, compare).  Only after
# ALL pieces of a partition are written AND verified is the partition
# appended to $HERE/.flash-progress.txt as "<name> <sha256 of the source
# image>".  A later run prints "RESUME: skipping <name>" for every recorded
# partition and does not restart the flash from zero; --fresh (FRESH=1)
# ignores the progress file.
#
# Requires from the sourcing script:
#   HERE, WL_CHUNK (piece size, bytes, multiple of 512), WL_GAP (seconds),
#   FRESH (0/1), and
#   wl_verify <lba> <file> <byte-off> <byte-len> <label>
#     - writes one byte range of the file to that LBA and read-compares it.
#     flash.sh's wl_verify dies on any failure; restore.sh's returns
#     non-zero - wl_window/wl_chunk handle both conventions.
#   DRY is optional (${DRY:-0}); in dry-run mode a range prints exactly the
#   single write/readback plan pair of the pre-chunking scripts, so the
#   --dry-run output stays byte-compatible (resume lines are the only
#   additions when a progress file exists).

WL_PROGRESS=${WL_PROGRESS:-$HERE/.flash-progress.txt}

# Is this partition already done (recorded in the progress file, and not
# --fresh)?  Matches on the partition name; the recorded sha256 is the audit
# trail of which image bytes the skip decision is based on.
resume_has() { # name
  if [ "${FRESH:-0}" = 1 ]; then return 1; fi
  if [ ! -f "$WL_PROGRESS" ]; then return 1; fi
  awk -v n="$1" '$1 == n { found = 1 } END { exit !found }' "$WL_PROGRESS"
}

# Record a finished partition: "<name> <sha256-of-src>" - only ever called
# after the chunked write AND the full readback verify of that partition
# passed, so a half-written partition is never skipped on resume.
resume_record() { # name src-file
  local sum
  sum=$(sha256sum "$2") || return 1
  printf '%s %s\n' "$1" "${sum%% *}" >> "$WL_PROGRESS"
}

# Write the byte range [off, off+len) of a file starting at an LBA, in
# WL_CHUNK-byte pieces (exact multiples, final piece partial), sleeping
# WL_GAP seconds between the pieces.  Chunk i goes to LBA + i*(WL_CHUNK/512)
# sectors.  In dry-run mode this is the single plan line pair of the old
# scripts.  Returns non-zero when a piece failed (restore.sh convention;
# flash.sh's wl_verify exits the script before that).
wl_window() { # lba file byte-off byte-len label
  local lba=$1 f=$2 off=$3 len=$4 label=$5
  local step=$((WL_CHUNK / 512)) n i o l rc=0
  if [ "${DRY:-0}" = 1 ]; then
    wl_verify "$lba" "$f" "$off" "$len" "$label"
    return 0
  fi
  n=$(( (len + WL_CHUNK - 1) / WL_CHUNK ))
  if [ "$n" -gt 1 ]; then
    echo "-- $label: $len B in $n piece(s) of $WL_CHUNK B, gap ${WL_GAP}s"
  fi
  for ((i = 0; i < n; i++)); do
    o=$((off + i * WL_CHUNK)); l=$((len - i * WL_CHUNK))
    [ "$l" -le "$WL_CHUNK" ] || l=$WL_CHUNK
    if ! wl_verify "$((lba + i * step))" "$f" "$o" "$l" "$label"; then rc=1; break; fi
    if [ "$((i + 1))" -lt "$n" ]; then sleep "$WL_GAP"; fi
  done
  return $rc
}

# Chunked write of a whole partition image with the resume bookkeeping:
# skip when the progress file already lists <name>, write the file in pieces
# (a file that fits one piece is a single wl), and record <name> only after
# every piece was written and read back OK.  Nothing is recorded in dry-run
# mode - dry runs verify nothing on the device.
wl_chunk() { # lba src-file name
  local lba=$1 f=$2 name=$3 size
  if resume_has "$name"; then echo "RESUME: skipping $name"; return 0; fi
  size=$(stat -L -c %s "$f") || return 1
  wl_window "$lba" "$f" 0 "$size" "$name" || return 1
  if [ "${DRY:-0}" = 1 ]; then return 0; fi
  resume_record "$name" "$f"
}
