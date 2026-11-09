#!/bin/bash
# Rebuild dynamic partition image (super.img) from system, vendor, and odm raw images.
# Usage: ./build-super.sh [system.img] [vendor.img] [odm.img] [out_super.img]

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

SYS=${1:-$HERE/system.img}
VEN=${2:-$HERE/vendor.img}
ODM=${3:-$HERE/odm.img}
OUT=${4:-$HERE/super.img}

command -v lpmake >/dev/null 2>&1 || { echo "STOP: lpmake not found in PATH"; exit 1; }

for f in "$SYS" "$VEN" "$ODM"; do
    if [ ! -f "$f" ]; then
        echo "STOP: Missing input file: $f"
        exit 1
    fi
done

SYS_SZ=$(stat -c %s "$SYS")
VEN_SZ=$(stat -c %s "$VEN")
ODM_SZ=$(stat -c %s "$ODM")

# The super image has to hold all three plus the group's 1 MiB headroom, so its size follows the
# base image instead of being fixed: the TrebleDroid a64 GSI fits in 1574 MiB, a LineageOS 23.2
# system image is 1.88 GB on its own. release-build/guard-release.py is the authority that the
# result still fits the device tree's system partition (3072 MiB here).
# 16 MiB of slack, not 1 MiB: liblp rounds every partition's extents up to its 4 KiB block size,
# so a group sized at exactly the sum of the three images runs out of space on the last one
# (measured: "Not enough space on device for partition odm").
NEED=$(( SYS_SZ + VEN_SZ + ODM_SZ + 16 * 1048576 ))
NEED=$(( (NEED + 511) / 512 * 512 ))
SUPER_DEV=${SUPER_DEV:-$NEED}
GROUP=$(( SUPER_DEV - 1048576 ))

echo "Packing super.img:"
echo "  system: $SYS ($SYS_SZ bytes)"
echo "  vendor: $VEN ($VEN_SZ bytes)"
echo "  odm:    $ODM ($ODM_SZ bytes)"
echo "  device: $SUPER_DEV bytes (needed $NEED), group: $GROUP"

lpmake \
  --metadata-size 65536 \
  --metadata-slots 2 \
  --super-name system \
  --device system:"$SUPER_DEV" \
  --group rockchip_dynamic_partitions:"$GROUP" \
  --partition system:readonly:"$SYS_SZ":rockchip_dynamic_partitions --image system="$SYS" \
  --partition vendor:readonly:"$VEN_SZ":rockchip_dynamic_partitions --image vendor="$VEN" \
  --partition odm:readonly:"$ODM_SZ":rockchip_dynamic_partitions --image odm="$ODM" \
  --output "$OUT"

echo "Successfully generated: $OUT ($(stat -c %s "$OUT") bytes)"
