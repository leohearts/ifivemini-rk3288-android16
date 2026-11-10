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
#
# Constraint measured on this tablet (2026-11-10): the vendor filesystem has "Free blocks: 0".
# A replacement file must therefore stay within the number of blocks the original used, or
# debugfs silently writes a truncated file - mode/owner/label still read back correct, only the
# byte comparison below catches it (seen with /etc/init/hw/init.rockchip.rc at 4408 B: written
# back as exactly 4096 B). If a change genuinely needs more room, shrink another file or grow the
# partition in the parameter table; do not ship a vendor image this script reports as OK.

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
bin/chgpolicy.sh                  0100755  0:0     u:object_r:vendor_shell_exec:s0
bin/hw/android.hardware.power-service.rockchip 0100755 0:2000 u:object_r:hal_power_default_exec:s0
lib/hw/hwcomposer.rk30board.so    0100644  0:0     u:object_r:vendor_hal_file:s0
etc/init/hw/init.rk3288.rc        0100644  0:0     u:object_r:vendor_configs_file:s0
etc/init/hw/init.rockchip.rc      0100644  0:0     u:object_r:vendor_configs_file:s0
etc/vintf/manifest.xml            0100644  0:0     u:object_r:vendor_configs_file:s0
"

cp "$IN" "$OUT"

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
# debugfs reports exit code 0 even when a write failed midway (measured: "Could not allocate
# block in ext2 filesystem" while the file was silently cut at 4096 B), and mode/owner/label all
# still look right afterwards. Only a byte-for-byte comparison against the source catches that,
# so it runs first: a truncated .rc or a short .so must stop the build here, not on the tablet.
dumpe2fs -h "$OUT" 2>/dev/null | grep -iE "^Free blocks:" | sed 's/^/   /' || true
RB=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
trap 'rm -f "$RB"' EXIT
while read -r path mode owner label; do
    [ -n "$path" ] || continue
    # </dev/null matters twice over: debugfs asks for confirmation when the dump target already
    # exists, and inside this loop that prompt would be answered from the remaining TABLE lines.
    rm -f "$RB"
    debugfs -R "dump /$path $RB" "$OUT" </dev/null >/dev/null 2>&1
    if ! cmp -s "$ROOT/vendor-changes/$path" "$RB"; then
        echo "   FAIL /$path content: image holds $(wc -c <"$RB") B, source has $(wc -c <"$ROOT/vendor-changes/$path") B"
        echo "        (the filesystem is out of free blocks or the write was interrupted)"
        fail=1; continue
    fi
    st=$(debugfs -R "stat /$path" "$OUT" 2>/dev/null)
    got_mode=$(sed -n 's/.*Mode:[[:space:]]*\([0-7]\{3,4\}\).*/\1/p' <<< "$st" | head -1)
    got_user=$(sed -n 's/.*User:[[:space:]]*\([0-9]\{1,\}\)[[:space:]]*Group:[[:space:]]*\([0-9]\{1,\}\).*/\1:\2/p' <<< "$st" | head -1)
    got_label=$(sed -n 's/.*security\.selinux *([0-9]*) *= *"\(.*\)"$/\1/p' <<< "$st" | head -1)
    want_mode=$((8#${mode: -4}))          # sif sets the full mode, stat prints the permission bits
    want_label="$label\\000"              # debugfs prints the stored NUL as \000
    if   [ $((8#${got_mode:-0})) -ne "$want_mode" ]; then
        echo "   FAIL /$path mode: got '${got_mode}' want $(printf '%04o' "$want_mode")"; fail=1
    elif [ "${got_user:-?}" != "$owner" ]; then
        echo "   FAIL /$path owner: got '${got_user}' want $owner"; fail=1
    elif [ "$got_label" != "$want_label" ]; then
        echo "   FAIL /$path label: got [$got_label] want [$want_label]"; fail=1
    else
        printf "   OK   /%s  mode=%04o owner=%s label=%s\n" "$path" "$want_mode" "$got_user" "$label"
    fi
done <<< "$TABLE"
[ "$fail" = 0 ] || { echo "STOP: read-back mismatch, $OUT is not usable"; exit 2; }

echo "== filesystem check"
e2fsck -fy "$OUT" >/dev/null 2>&1 || true
e2fsck -fn "$OUT" >/dev/null
echo "OK: patched vendor image: $OUT"
