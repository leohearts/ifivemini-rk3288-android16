#!/bin/bash
# One-click script to build the Android 16 super.img and prepare release inputs.
# Usage: ./build-android-images.sh [output_dir]

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${1:-$HERE/inputs}
WORK_DIR="$HERE/out/super-work"

mkdir -p "$OUT_DIR" "$WORK_DIR"

echo "=== 1. Checking required tools ==="
MISSING=()
for tool in curl unxz simg2img lpmake lpunpack debugfs e2fsck; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING+=("$tool")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "STOP: Missing required tools: ${MISSING[*]}"
    echo "Please install them via:"
    echo "  Fedora: sudo dnf install -y android-tools e2fsprogs xz curl"
    echo "  Debian/Ubuntu: sudo apt-get install -y android-sdk-libsparse-utils e2fsprogs xz-utils curl"
    exit 1
fi
echo "All required tools are installed."

echo "=== 2. Obtaining TrebleDroid Android 16 GSI ==="
GSI_XZ="$WORK_DIR/system-td-arm32_binder64-vanilla.img.xz"
GSI_IMG="$WORK_DIR/system.img"
GSI_URL="https://github.com/TrebleDroid/treble_experimentations/releases/download/ci-20250617/system-td-arm32_binder64-vanilla.img.xz"

if [ ! -f "$GSI_IMG" ]; then
    if [ ! -f "$GSI_XZ" ]; then
        echo "Downloading GSI from $GSI_URL ..."
        curl -L -C - -o "$GSI_XZ" "$GSI_URL"
    fi
    echo "Decompressing GSI image..."
    unxz -k -f "$GSI_XZ"
    RAW_NAME="${GSI_XZ%.xz}"
    # Convert sparse to raw if needed
    if [ "$(xxd -p -l 4 "$RAW_NAME")" = "ed26ff3a" ]; then
        echo "Converting sparse GSI to raw image..."
        simg2img "$RAW_NAME" "$GSI_IMG"
        rm -f "$RAW_NAME"
    else
        mv "$RAW_NAME" "$GSI_IMG"
    fi
else
    echo "GSI system image already prepared: $GSI_IMG"
fi

echo "=== 3. Obtaining Vendor and ODM images ==="
VENDOR_RAW="$WORK_DIR/vendor.img"
ODM_RAW="$WORK_DIR/odm.img"

if [ ! -f "$VENDOR_RAW" ] || [ ! -f "$ODM_RAW" ]; then
    BASE_SUPER="$OUT_DIR/super.img"
    if [ ! -f "$BASE_SUPER" ]; then
        # Try finding in release assets
        ZIP_SUPER=$(find "$HERE/release" -name "*.zip" 2>/dev/null | head -n 1 || true)
        if [ -n "$ZIP_SUPER" ]; then
            echo "Extracting base images from $ZIP_SUPER ..."
            unzip -p "$ZIP_SUPER" "images/super.img" > "$WORK_DIR/base_super.img"
            BASE_SUPER="$WORK_DIR/base_super.img"
        fi
    fi

    if [ -f "$BASE_SUPER" ]; then
        echo "Unpacking vendor and odm from $BASE_SUPER ..."
        lpunpack "$BASE_SUPER" "$WORK_DIR/unpacked"
        cp "$WORK_DIR/unpacked/vendor.img" "$VENDOR_RAW"
        cp "$WORK_DIR/unpacked/odm.img" "$ODM_RAW"
    else
        echo "STOP: Cannot locate base vendor.img and odm.img."
        echo "Please place a reference super.img at $OUT_DIR/super.img or provide the ASUS Tinker Board Android 11 images."
        exit 1
    fi
else
    echo "Base vendor and odm images already present."
fi

echo "=== 4. Patching Vendor Image with custom HWC, Power HAL, and Charging policy ==="
VENDOR_PATCHED="$WORK_DIR/vendor-patched.img"
"$HERE/scripts/patch-vendor.sh" "$VENDOR_RAW" "$VENDOR_PATCHED"

echo "=== 5. Packaging final super.img ==="
FINAL_SUPER="$OUT_DIR/super.img"
"$HERE/scripts/build-super.sh" "$GSI_IMG" "$VENDOR_PATCHED" "$ODM_RAW" "$FINAL_SUPER"

echo "=== 6. Preparing ancillary release inputs (metadata, zeroed userdata, ramdisk) ==="
# 16 MiB metadata.img
if [ ! -f "$OUT_DIR/metadata.img" ]; then
    dd if=/dev/zero of="$OUT_DIR/metadata.img" bs=1M count=16 status=none
fi
# 1 MiB zeroed userdata head
if [ ! -f "$OUT_DIR/userdata-head-zero.img" ]; then
    dd if=/dev/zero of="$OUT_DIR/userdata-head-zero.img" bs=1M count=1 status=none
fi
# Ramdisk container
if [ -f "$HERE/out/release/ifive-mini4s-android16-gsi-rescue/images/ramdisk.img" ] && [ ! -f "$OUT_DIR/ramdisk.img" ]; then
    cp "$HERE/out/release/ifive-mini4s-android16-gsi-rescue/images/ramdisk.img" "$OUT_DIR/ramdisk.img"
fi

echo "=========================================================="
echo "Done! Generated files in $OUT_DIR:"
ls -lh "$OUT_DIR"
echo "You can now run: ./release-build/make-release.sh $OUT_DIR"
echo "=========================================================="
