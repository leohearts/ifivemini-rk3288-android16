#!/bin/bash
# Pull the libraries gralloc/build.sh links against from the tablet (adb pull only,
# nothing is written to the device), plus the two original vendor gralloc libraries
# that build.sh compares the new ones with.
#
#   gralloc/pull-libs.sh <dest-dir>
#
# Env: ADB (default "adb -d"). The tablet may drop off adb while SurfaceFlinger
# crash-loops; every pull is retried.
set -euo pipefail
DEST=${1:?usage: $0 <dest-dir>}
ADB=${ADB:-adb -d}
mkdir -p "$DEST/orig"

pull() { # <device path> <dest dir>
    local f=$1 d=$2
    for _ in $(seq 1 60); do
        if $ADB pull "$f" "$d/" >/dev/null 2>&1 && [ -s "$d/$(basename "$f")" ]; then return 0; fi
        sleep 3
    done
    echo "STOP: cannot pull $f"; exit 1
}

# VNDK v30 libraries visible to vendor code
for l in libbase libc++ libcutils libgralloctypes libhardware libhidlbase libion libutils \
         android.hardware.graphics.allocator@4.0 android.hardware.graphics.mapper@4.0 \
         android.hardware.graphics.common@1.0 android.hardware.graphics.common@1.1 \
         android.hardware.graphics.common@1.2; do
    pull "/apex/com.android.vndk.v30/lib/$l.so" "$DEST"
done
# LLNDK libraries (system partition) and the vendor's libdrm
for l in liblog libnativewindow libsync; do pull "/system/lib/$l.so" "$DEST"; done
pull /vendor/lib/libdrm.so "$DEST"
# the originals
for l in android.hardware.graphics.allocator@4.0-impl-midgard android.hardware.graphics.mapper@4.0-impl-midgard; do
    pull "/vendor/lib/hw/$l.so" "$DEST/orig"
done
echo "pulled into $DEST"
