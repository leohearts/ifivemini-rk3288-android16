#!/bin/bash
# Patch vendor.img using files from vendor-changes/ via debugfs.
# Usage: ./patch-vendor.sh [source_vendor.img] [output_vendor.img]

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

IN_VEN=${1:?Usage: $0 <source_vendor.img> [output_vendor.img]}
OUT_VEN=${2:-$HERE/vendor-patched.img}

command -v debugfs >/dev/null 2>&1 || { echo "STOP: debugfs not found"; exit 1; }
command -v e2fsck >/dev/null 2>&1 || { echo "STOP: e2fsck not found"; exit 1; }

cp "$IN_VEN" "$OUT_VEN"

apply_file() {
    local src="$1"
    local dst="$2"
    local mode="$3"
    local seclabel="$4"

    echo "Applying $dst ..."
    debugfs -w "$OUT_VEN" <<EOF >/dev/null 2>&1
rm $dst
write $src $dst
sif $dst mode $mode
sif $dst uid 0
sif $dst gid 0
ea_set $dst security.selinux $seclabel
EOF
}

# 1. chgpolicy script
apply_file "$ROOT/vendor-changes/bin/chgpolicy.sh" "/bin/chgpolicy.sh" "0100755" "u:object_r:vendor_shell_exec:s0"

# 2. Power HAL binary
apply_file "$ROOT/vendor-changes/bin/hw/android.hardware.power-service.rockchip" "/bin/hw/android.hardware.power-service.rockchip" "0100755" "u:object_r:hal_power_default_exec:s0"

# 3. HWC library
apply_file "$ROOT/vendor-changes/lib/hw/hwcomposer.rk30board.so" "/lib/hw/hwcomposer.rk30board.so" "0100644" "u:object_r:vendor_file:s0"

# 4. init.rk3288.rc
apply_file "$ROOT/vendor-changes/etc/init/hw/init.rk3288.rc" "/etc/init/hw/init.rk3288.rc" "0100644" "u:object_r:vendor_configs_file:s0"

# 5. VINTF manifest.xml
apply_file "$ROOT/vendor-changes/etc/vintf/manifest.xml" "/etc/vintf/manifest.xml" "0100644" "u:object_r:vendor_configs_file:s0"

echo "Checking filesystem consistency..."
e2fsck -fy "$OUT_VEN" >/dev/null 2>&1 || true
e2fsck -fn "$OUT_VEN" >/dev/null

echo "Successfully patched vendor image: $OUT_VEN"
