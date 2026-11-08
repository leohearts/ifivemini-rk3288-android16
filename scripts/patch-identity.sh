#!/bin/bash
# Write this tablet's own identity into the GSI system image and the vendor image, so the
# device stops reporting the GSI defaults (brand google / model mainline / device generic /
# flavor treble_a64_bvS, and no ro.build.fingerprint key at all).
#
#   ./patch-identity.sh <system.img> <vendor.img> <out-dir>
#
#   <out-dir>/system.img   <out-dir>/vendor.img    patched copies; the inputs are untouched
#
# The identity can be changed from the environment:
#   ID_BRAND ID_MANUFACTURER ID_MODEL ID_NAME ID_DEVICE
# The build id, incremental, release, type and tags are read out of the images, so the
# resulting fingerprint still describes the real Android 16 build inside them.

set -euo pipefail

BRAND=${ID_BRAND:-iFive}
MANU=${ID_MANUFACTURER:-iFive}
MODEL=${ID_MODEL:-iFive mini 4S}
NAME=${ID_NAME:-ifive_mini4s}
DEVICE=${ID_DEVICE:-mini4s}

SYS=${1:?usage: $0 <system.img> <vendor.img> <out-dir>}
VEN=${2:?usage: $0 <system.img> <vendor.img> <out-dir>}
OUTD=${3:?usage: $0 <system.img> <vendor.img> <out-dir>}

command -v debugfs >/dev/null 2>&1 || { echo "STOP: debugfs not found (e2fsprogs)"; exit 1; }
command -v e2fsck  >/dev/null 2>&1 || { echo "STOP: e2fsck not found (e2fsprogs)"; exit 1; }
for f in "$SYS" "$VEN"; do [ -f "$f" ] || { echo "STOP: no such image: $f"; exit 1; }; done
mkdir -p "$OUTD"

rewrite_props() { # <props file> <partition prefix>
    ID_BRAND="$BRAND" ID_MANUFACTURER="$MANU" ID_MODEL="$MODEL" ID_NAME="$NAME" \
    ID_DEVICE="$DEVICE" ID_PREFIX="$2" python3 - "$1" <<'PY'
import os, re, sys

path = sys.argv[1]
b, m, mo, n, d = (os.environ[k] for k in
                  ("ID_BRAND", "ID_MANUFACTURER", "ID_MODEL", "ID_NAME", "ID_DEVICE"))
pfx = os.environ["ID_PREFIX"]

text = open(path, encoding="utf-8").read()
lines = text.splitlines()

def get(key):
    r = re.search(r'^%s=(.*)$' % re.escape(key), text, re.M)
    if not r:
        sys.exit("STOP: %s is not in %s; cannot derive a truthful fingerprint" % (key, path))
    return r.group(1)

# google/treble_a64_bvS/tdgsi_a64_ab:16/BP2A.250605.031.A3/250617:userdebug/test-keys
# -> 16/BP2A.250605.031.A3/250617:userdebug/test-keys
want = {
    "ro.product.brand": b, "ro.product.manufacturer": m, "ro.product.model": mo,
    "ro.product.name": n, "ro.product.device": d,
    "ro.product.%s.brand" % pfx: b, "ro.product.%s.manufacturer" % pfx: m,
    "ro.product.%s.model" % pfx: mo, "ro.product.%s.name" % pfx: n,
    "ro.product.%s.device" % pfx: d,
}
if pfx == "system":
    # the fingerprint and the build description describe the Android 16 system image;
    # the vendor side keeps its own asus/A11 fingerprints, which is what those blobs are
    tail = get("ro.system.build.fingerprint").split(":", 1)[1]
    fp = "%s/%s/%s:%s" % (b, n, d, tail)
    flavor = "%s-%s" % (n, get("ro.build.type"))
    desc = "%s %s %s %s %s" % (flavor, get("ro.build.version.release_or_codename"),
                               get("ro.build.id"), get("ro.build.version.incremental"),
                               get("ro.build.tags"))
    want.update({"ro.build.fingerprint": fp, "ro.system.build.fingerprint": fp,
                 "ro.build.flavor": flavor, "ro.build.display.id": desc,
                 "ro.build.description": desc})

replaced, out = set(), []
for ln in lines:
    key = ln.split("=", 1)[0] if ln.startswith("ro.") else None
    if key in want:
        out.append("%s=%s" % (key, want[key]))
        replaced.add(key)
    else:
        out.append(ln)
added = [k for k in want if k not in replaced]
out.append("")
out.append("# device identity, written by scripts/patch-identity.sh")
out += ["%s=%s" % (k, want[k]) for k in added]
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("   build.prop: %d key(s) replaced, %d added" % (len(replaced), len(added)))
PY
}

patch_one() { # <in.img> <prop path in image> <partition prefix> <out name>
    local img=$1 prop=$2 pfx=$3 out=$4 work dir st mode uid gid label
    work=$(mktemp -d /tmp/ifive-identity.XXXXXX)
    trap 'rm -rf "$work"' RETURN
    dir="$OUTD/$out"
    cp "$img" "$dir"

    debugfs -R "cat $prop" "$dir" > "$work/props" 2>/dev/null \
        || { echo "STOP: cannot read $prop from $img"; exit 1; }
    st=$(debugfs -R "stat $prop" "$dir" 2>/dev/null)
    mode=$(sed -n 's/.*Mode:[[:space:]]*\([0-7]\{3,4\}\).*/\1/p' <<< "$st" | head -1)
    uid=$(sed -n 's/.*User:[[:space:]]*\([0-9]\{1,\}\)[[:space:]]*Group:.*/\1/p' <<< "$st" | head -1)
    gid=$(sed -n 's/.*Group:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' <<< "$st" | head -1)
    label=$(sed -n 's/.*security\.selinux *([0-9]*) *= *"\(.*\)"$/\1/p' <<< "$st" | head -1)
    label=${label%\\000}
    [ -n "$mode" ] && [ -n "$label" ] || { echo "STOP: cannot read mode/label of $prop in $img"; exit 1; }
    # stat prints only the permission bits; sif needs the mode with the file-type bits
    # (S_IFREG is 8#0100000, so the result must be 6 octal digits: 0100644, not 010644)
    mode=$(printf '0%06o' $((8#0100000 + 8#$mode)))

    rewrite_props "$work/props" "$pfx"

    debugfs -w "$dir" <<EOF >/dev/null
rm $prop
write $work/props $prop
sif $prop mode $mode
sif $prop uid $uid
sif $prop gid $gid
ea_set $prop security.selinux $label\\000
EOF
    # the file has to read back byte for byte, or the image is not usable
    got=$(debugfs -R "cat $prop" "$dir" 2>/dev/null | wc -c)
    want=$(wc -c < "$work/props")
    [ "$got" = "$want" ] || { echo "STOP: $prop read back as $got B, written $want B"; exit 1; }
    e2fsck -fn "$dir" >/dev/null || { echo "STOP: e2fsck reports damage in $dir"; exit 1; }

    echo "   read back from $out: $got B, mode $mode, owner $uid:$gid"
    debugfs -R "cat $prop" "$dir" 2>/dev/null \
        | grep -E "^ro\.(product\.|build\.fingerprint|system\.build\.fingerprint|build\.flavor|build\.description)" \
        | sed 's/^/      /'
}

echo "== identity: brand=$BRAND manufacturer=$MANU model=\"$MODEL\" name=$NAME device=$DEVICE"
echo "-- $SYS"
patch_one "$SYS" /system/build.prop system system.img
echo "-- $VEN"
patch_one "$VEN" /build.prop vendor vendor.img
echo "OK: $OUTD/system.img  $OUTD/vendor.img"
