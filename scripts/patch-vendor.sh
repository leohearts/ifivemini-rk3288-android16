#!/bin/bash
# Patch a vendor.img with the board changes kept in vendor-changes/.
#
#   ./patch-vendor.sh <in.img> <out.img>
#
# Each target path is removed and rewritten with debugfs, then mode/owner/SELinux
# label are set and the result is read back and compared with the table below.
# Any mismatch stops the script.
#
# Labels are stored NUL-terminated, the way AOSP e2fsdroid writes them into Android
# images (debugfs ea_set takes the octal escape \000). The mode/owner/label values in
# the table were read out of the vendor partition that boots on the tablet
# (debugfs -R stat, 2026-11-08), so a patched image matches what the device expects.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

IN=${1:?usage: $0 <in.img> <out.img>}
OUT=${2:?usage: $0 <in.img> <out.img>}

command -v debugfs >/dev/null 2>&1 || { echo "STOP: debugfs not found (e2fsprogs)"; exit 1; }
command -v e2fsck  >/dev/null 2>&1 || { echo "STOP: e2fsck not found (e2fsprogs)"; exit 1; }
[ -f "$IN" ] || { echo "STOP: no such image: $IN"; exit 1; }

# path                            mode     owner   security.selinux
TABLE="
bin/hw/android.hardware.power-service.rockchip 0100755 0:2000 u:object_r:hal_power_default_exec:s0
lib/hw/hwcomposer.rk30board.so    0100644  0:0     u:object_r:vendor_hal_file:s0
etc/init/hw/init.rk3288.rc        0100644  0:0     u:object_r:vendor_configs_file:s0
etc/init/hw/init.connectivity.rc 0100644  0:0     u:object_r:vendor_configs_file:s0
etc/init/hw/init.rk30board.rc    0100644  0:0     u:object_r:vendor_configs_file:s0
etc/init/hw/init.rockchip.rc     0100644  0:0     u:object_r:vendor_configs_file:s0
etc/init/android.hardware.drm@1.3-service.widevine.rc 0100644 0:0 u:object_r:vendor_configs_file:s0
bin/hw/android.hardware.gatekeeper-service.ifive 0100755 0:2000 u:object_r:hal_gatekeeper_default_exec:s0
etc/init/android.hardware.gatekeeper-service.ifive.rc 0100644 0:0 u:object_r:vendor_configs_file:s0
bin/hw/android.hardware.keymaster@4.0-service.ifive 0100755 0:2000 u:object_r:hal_keymaster_default_exec:s0
etc/init/android.hardware.keymaster@4.0-service.ifive.rc 0100644 0:0 u:object_r:vendor_configs_file:s0
etc/vintf/manifest/android.hardware.gatekeeper-service.ifive.xml 0100644 0:0 u:object_r:vendor_configs_file:s0
etc/selinux/vendor_service_contexts 0100644 0:0 u:object_r:vendor_configs_file:s0
etc/vintf/manifest.xml            0100644  0:0     u:object_r:vendor_configs_file:s0
etc/selinux/vendor_sepolicy.cil     0100644  0:0     u:object_r:vendor_configs_file:s0
etc/selinux/vendor_property_contexts 0100644 0:0  u:object_r:vendor_configs_file:s0
etc/selinux/vendor_file_contexts 0100644 0:0  u:object_r:vendor_configs_file:s0
etc/fstab.rk30board.emmc 0100644 0:0  u:object_r:vendor_configs_file:s0
build.prop                        0100644  0:0     u:object_r:vendor_file:s0
etc/permissions/ifive-settings.xml 0100644  0:0     u:object_r:vendor_configs_file:s0
priv-app/IfiveSettings/IfiveSettings.apk 0100644 0:0 u:object_r:vendor_app_file:s0
overlay/DeepDoze.apk              0100644  0:0     u:object_r:vendor_overlay_file:s0
"
# directories the files above need that the Tinker Board vendor image lacks
DIRS="
priv-app                          040755   0:2000  u:object_r:vendor_app_file:s0
priv-app/IfiveSettings            040755   0:2000  u:object_r:vendor_app_file:s0
"

cp "$IN" "$OUT"

while read -r path mode owner label; do
    [ -n "$path" ] || continue
    debugfs -R "stat /$path" "$OUT" 2>&1 | grep -q "File not found" || continue
    debugfs -w "$OUT" >/dev/null <<EOF
mkdir /$path
sif /$path mode $mode
sif /$path uid ${owner%%:*}
sif /$path gid ${owner##*:}
ea_set /$path security.selinux $label\\000
EOF
done <<< "$DIRS"

# files earlier packages added that no longer exist in vendor-changes/; the Tinker
# Board service for /vendor/bin/install-recovery.sh, which this vendor lacks; and
# the OP-TEE services (gatekeeper, weaver, tee-supplicant): this board has no TEE
REMOVE="bin/chgpolicy.sh etc/init/vendor_flash_recovery.rc
etc/init/android.hardware.gatekeeper@1.0-service.optee.rc
etc/vintf/manifest/android.hardware.gatekeeper@1.0-service.optee.xml
etc/init/android.hardware.weaver@1.0-service.rc
etc/vintf/manifest/android.hardware.weaver@1.0-service.xml
etc/init/init.tee-supplicant.rc
bin/tee-supplicant
bin/hw/android.hardware.gatekeeper@1.0-service.optee lib/libRkgatekeeper.so
bin/hw/android.hardware.weaver@1.0-service lib/hw/android.hardware.weaver@1.0-impl.so lib/libRkTeeWeaver.v1.so
lib/optee_armtz/0b82bae5-0cd0-49a5-9521516dba9c43ba.ta
lib/optee_armtz/258be795-f9ca-40e6-a8699ce6886c5d5d.ta
lib/optee_armtz/481a57df-aec8-47ad-92f5eb9fc24f64a6.ta
lib/libteec.so lib/libRkTeeKeymaster.so lib/libRkkeymaster4.so lib/libRkpurekeymasterdevice.so
lib/libRkkeymaster_portable.so lib/libRkkeymaster_messages.so
bin/hw/android.hardware.keymaster@4.0-service.soft etc/init/android.hardware.keymaster@4.0-service.soft.rc"
for path in $REMOVE; do
    debugfs -w -R "rm /$path" "$OUT" >/dev/null 2>&1 || true
    debugfs -R "stat /$path" "$OUT" 2>&1 | grep -q "File not found" || { echo "STOP: /$path still in $OUT"; exit 1; }
done

echo "== writing"
while read -r path mode owner label; do
    [ -n "$path" ] || continue
    src="$ROOT/vendor-changes/$path"
    [ -f "$src" ] || { echo "STOP: missing $src"; exit 1; }
    echo "   /$path"
    debugfs -w "$OUT" >/dev/null <<EOF
rm /$path
write $src /$path
sif /$path mode $mode
sif /$path uid ${owner%%:*}
sif /$path gid ${owner##*:}
ea_set /$path security.selinux $label\\000
EOF
done <<< "$TABLE"

echo "== read-back check"
fail=0
while read -r path mode owner label; do
    [ -n "$path" ] || continue
    st=$(debugfs -R "stat /$path" "$OUT" 2>/dev/null)
    got_mode=$(sed -n 's/.*Mode:[[:space:]]*\([0-7]\{3,4\}\).*/\1/p' <<< "$st" | head -1)
    got_user=$(sed -n 's/.*User:[[:space:]]*\([0-9]\{1,\}\)[[:space:]]*Group:[[:space:]]*\([0-9]\{1,\}\).*/\1:\2/p' <<< "$st" | head -1)
    # stat leaves out values longer than 40 bytes; ea_get always prints the value
    got_label=$(debugfs -R "ea_get /$path security.selinux" "$OUT" 2>/dev/null | sed -n 's/^security\.selinux *([0-9]*) *= *"\(.*\)"$/\1/p' | head -1)
    want_mode=$((8#${mode: -4}))          # sif sets the full mode, stat prints the permission bits
    want_label="$label\\000"              # debugfs prints the stored NUL as \000
    rm -f "$OUT.chk"
    debugfs -R "dump /$path $OUT.chk" "$OUT" >/dev/null 2>&1
    if ! cmp -s "$OUT.chk" "$ROOT/vendor-changes/$path"; then
        echo "   FAIL /$path content differs from vendor-changes/$path (image full?)"; fail=1
    elif [ $((8#${got_mode:-0})) -ne "$want_mode" ]; then
        echo "   FAIL /$path mode: got '${got_mode}' want $(printf '%04o' "$want_mode")"; fail=1
    elif [ "${got_user:-?}" != "$owner" ]; then
        echo "   FAIL /$path owner: got '${got_user}' want $owner"; fail=1
    elif [ "$got_label" != "$want_label" ]; then
        echo "   FAIL /$path label: got [$got_label] want [$want_label]"; fail=1
    else
        printf "   OK   /%s  mode=%04o owner=%s label=%s\n" "$path" "$want_mode" "$got_user" "$label"
    fi
done <<< "$TABLE"
rm -f "$OUT.chk"
[ "$fail" = 0 ] || { echo "STOP: read-back mismatch, $OUT is not usable"; exit 2; }

echo "== filesystem check"
e2fsck -fy "$OUT" >/dev/null 2>&1 || true
e2fsck -fn "$OUT" >/dev/null
echo "OK: patched vendor image: $OUT"
