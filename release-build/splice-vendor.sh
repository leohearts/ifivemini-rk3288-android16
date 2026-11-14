#!/bin/bash
# splice-vendor.sh - apply vendor-changes/ to the vendor ext4 image embedded
# in a super.img, without repacking super. Used by make-release.sh, so every
# package carries exactly the vendor files kept in the repository.
#
# Why a splice instead of lpmake: the super.img stays byte-exact except for
# the vendor region, so every other partition (system, odm, the lp metadata)
# keeps its existing checksum. Verified on 2026-11-12: the extracted region
# compared byte-identical to lpunpack's vendor.img.
#
# usage: splice-vendor.sh <super.img>
set -euo pipefail
SUPER=${1:?usage: $0 <super.img>}
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd)
command -v lpdump >/dev/null || { echo "STOP: need lpdump"; exit 3; }
[ -w "$SUPER" ] || { echo "STOP: $SUPER not writable"; exit 3; }

# 1) locate the vendor partition inside super from the "Super partition
# layout" section: `  <dev>: <start> .. <end>: <partition> (<n> sectors)`.
# The per-partition "Extents:" table lists group-RELATIVE starts and must
# not be used.
read -r START COUNT < <(lpdump "$SUPER" 2>/dev/null | awk '
  $5 == "vendor" && $3 == ".." && $2 ~ /^[0-9]+$/ && $6 ~ /^\([0-9]+$/ {
    gsub(/[()]/, "", $6); print $2, $6; exit
  }') || true
[ -n "${START:-}" ] || { echo "STOP: no vendor partition in $SUPER"; exit 3; }
[ "$START" -ge 2048 ] || { echo "STOP: implausible start sector $START (layout parse wrong?)"; exit 3; }
echo "  vendor region: sectors $START +$COUNT"

# scratch stays on the same real disk as the image
W=$(mktemp -d "$(dirname "$SUPER")/splice-vendor.XXXXXX"); trap 'rm -rf "$W"' EXIT
dd if="$SUPER" of="$W/in.img" bs=512 skip="$START" count="$COUNT" status=none

# 2) patch (patch-vendor.sh writes, reads back mode/owner/label/content, fscks)
"$TOP/scripts/patch-vendor.sh" "$W/in.img" "$W/out.img"
[ "$(stat -c%s "$W/out.img")" = "$((COUNT * 512))" ] || { echo "STOP: patched vendor changed size"; exit 3; }

# 3) splice back and re-verify the region read through the whole file
dd if="$W/out.img" of="$SUPER" bs=512 seek="$START" conv=notrunc status=none
dd if="$SUPER" bs=512 skip="$START" count="$COUNT" status=none | cmp - "$W/out.img"
echo "  SUPER SPLICE OK"
