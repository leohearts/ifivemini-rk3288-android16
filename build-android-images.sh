#!/bin/bash
# One-click build of the Android 16 super.img plus the remaining release inputs.
# Downloads the TrebleDroid GSI, extracts vendor/odm from a reference super.img,
# applies vendor-changes/, and packs inputs/ ready for release-build/make-release.sh.
#
# Usage: ./build-android-images.sh [output_dir]   (default: ./inputs)

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${1:-$HERE/inputs}
WORK_DIR="$HERE/out/super-work"
GSI_URL="https://github.com/TrebleDroid/treble_experimentations/releases/download/ci-20250617/system-td-arm32_binder64-vanilla.img.xz"

mkdir -p "$OUT_DIR" "$WORK_DIR"

echo "=== 1. Checking required tools ==="
MISSING=()
for tool in curl unxz unzip simg2img lpmake lpunpack debugfs e2fsck dd; do
    command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "STOP: missing tools: ${MISSING[*]}"
    echo "Fedora (verified on fc45):  sudo dnf install -y android-tools e2fsprogs xz curl unzip"
    echo "Debian/Ubuntu:              sudo apt-get install -y e2fsprogs xz-utils curl unzip android-sdk-libsparse-utils"
    echo "                            lpmake/lpunpack are NOT covered by the Debian packages above;"
    echo "                            build them from AOSP system/extras/partition_tools."
    exit 1
fi

echo "=== 2. System image: TrebleDroid Android 16 GSI (a64) ==="
GSI_XZ="$WORK_DIR/system-td-arm32_binder64-vanilla.img.xz"
GSI_IMG="$WORK_DIR/system.img"
if [ -f "$GSI_IMG" ]; then
    echo "using existing $GSI_IMG"
else
    [ -f "$GSI_XZ" ] || { echo "downloading GSI (~740 MB compressed) ..."; curl -L -C - -o "$GSI_XZ" "$GSI_URL"; }
    RAW="${GSI_XZ%.xz}"
    [ -f "$RAW" ] || unxz -k "$GSI_XZ"
    # GSI may be sparse or raw; simg2img fails on raw, so fall back to a plain copy.
    if simg2img "$RAW" "$GSI_IMG" 2>/dev/null; then
        echo "converted sparse GSI -> raw $GSI_IMG"
    else
        cp "$RAW" "$GSI_IMG"
        echo "GSI already raw -> $GSI_IMG"
    fi
    rm -f "$RAW"
fi

echo "=== 3. Vendor and ODM images (from a reference super.img) ==="
VENDOR_IMG="$WORK_DIR/vendor.img"
ODM_IMG="$WORK_DIR/odm.img"
if [ ! -f "$VENDOR_IMG" ] || [ ! -f "$ODM_IMG" ]; then
    BASE=""
    # Copy the reference first so step 5 never overwrites the only source.
    if [ -f "$OUT_DIR/super.img" ] && [ ! -f "$WORK_DIR/base-super.img" ]; then
        cp "$OUT_DIR/super.img" "$WORK_DIR/base-super.img"
    fi
    for c in "$WORK_DIR/base-super.img" "$HERE/out/release/ifive-mini4s-android16-gsi-rescue/images/super.img"; do
        [ -f "$c" ] && { BASE="$c"; break; }
    done
    if [ -z "$BASE" ]; then
        ZIP=$(ls "$HERE"/release/*.zip 2>/dev/null | head -n 1 || true)
        if [ -n "$ZIP" ]; then
            echo "extracting images/super.img from $ZIP ..."
            unzip -p "$ZIP" "images/super.img" > "$WORK_DIR/base-super.img"
            BASE="$WORK_DIR/base-super.img"
        fi
    fi
    [ -n "$BASE" ] || { echo "STOP: no reference super.img found (checked inputs/, out/release/, release/*.zip)"; exit 1; }
    echo "unpacking vendor/odm from $BASE"
    lpunpack "$BASE" "$WORK_DIR/unpacked"
    cp "$WORK_DIR/unpacked/vendor.img" "$VENDOR_IMG"
    cp "$WORK_DIR/unpacked/odm.img" "$ODM_IMG"
else
    echo "using existing $VENDOR_IMG / $ODM_IMG"
fi

echo "=== 4. Patch vendor (HWC, power HAL, chgpolicy, init.rk3288.rc, VINTF manifest) ==="
VENDOR_PATCHED="$WORK_DIR/vendor-patched.img"
"$HERE/scripts/patch-vendor.sh" "$VENDOR_IMG" "$VENDOR_PATCHED"

echo "=== 5. Device identity (brand/model/fingerprint) ==="
ID_DIR="$WORK_DIR/identity"
"$HERE/scripts/patch-identity.sh" "$GSI_IMG" "$VENDOR_PATCHED" "$ID_DIR"

echo "=== 6. Pack super.img ==="
"$HERE/scripts/build-super.sh" "$ID_DIR/system.img" "$ID_DIR/vendor.img" "$ODM_IMG" "$OUT_DIR/super.img"

echo "=== 7. Ancillary inputs (metadata, userdata head, ramdisk, rkdeveloptool) ==="
REF_DIR="$HERE/out/release/ifive-mini4s-android16-gsi-rescue/images"
[ -f "$OUT_DIR/metadata.img" ] || { [ -f "$REF_DIR/metadata.img" ] && cp "$REF_DIR/metadata.img" "$OUT_DIR/" || dd if=/dev/zero of="$OUT_DIR/metadata.img" bs=1M count=16 status=none; }
[ -f "$OUT_DIR/userdata-head-zero.img" ] || { [ -f "$REF_DIR/userdata-head-zero.img" ] && cp "$REF_DIR/userdata-head-zero.img" "$OUT_DIR/" || dd if=/dev/zero of="$OUT_DIR/userdata-head-zero.img" bs=1M count=1 status=none; }
[ -f "$OUT_DIR/ramdisk.img" ] || { [ -f "$REF_DIR/ramdisk.img" ] && cp "$REF_DIR/ramdisk.img" "$OUT_DIR/"; }
# make-release.sh copies this binary into tools/, so the zip ships the rkdeveloptool that
# was used on this tablet instead of whatever the host has in PATH.
if [ ! -f "$OUT_DIR/rkdeveloptool" ]; then
    for c in "$HERE/out/release/ifive-mini4s-android16-gsi-rescue/tools/rkdeveloptool" "$(command -v rkdeveloptool || true)"; do
        if [ -n "$c" ] && [ -f "$c" ]; then cp "$c" "$OUT_DIR/rkdeveloptool"; chmod +x "$OUT_DIR/rkdeveloptool"; echo "bundling rkdeveloptool from $c"; break; fi
    done
    [ -f "$OUT_DIR/rkdeveloptool" ] || echo "NOTE: no rkdeveloptool found - make-release.sh stops unless one is in PATH"
fi

echo
echo "Done. Inputs ready in $OUT_DIR:"
ls -lh "$OUT_DIR"
echo "Next: ./release-build/make-release.sh $OUT_DIR"
