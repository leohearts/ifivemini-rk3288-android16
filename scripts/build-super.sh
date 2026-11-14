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

echo "Packing super.img:"
echo "  system: $SYS ($SYS_SZ bytes)"
echo "  vendor: $VEN ($VEN_SZ bytes)"
echo "  odm:    $ODM ($ODM_SZ bytes)"

lpmake \
  --metadata-size 65536 \
  --metadata-slots 2 \
  --super-name system \
  --device system:2037186560 \
  --group rockchip_dynamic_partitions:2036137984 \
  --partition system:readonly:"$SYS_SZ":rockchip_dynamic_partitions --image system="$SYS" \
  --partition vendor:readonly:"$VEN_SZ":rockchip_dynamic_partitions --image vendor="$VEN" \
  --partition odm:readonly:"$ODM_SZ":rockchip_dynamic_partitions --image odm="$ODM" \
  --output "$OUT"

echo "Successfully generated: $OUT ($(stat -c %s "$OUT") bytes)"
