#!/bin/bash
# Build the gralloc 4.0 HIDL allocator + mapper implementations for the iFive mini 4S
# vendor partition (armeabi-v7a, VNDK v30) from the Rockchip "midgard" gralloc
# (android14-rockchip) with the Android NDK compiler. The allocator uses dma-buf heaps
# (/dev/dma_heap/*), so the pair works on the 6.1 kernel which has no /dev/ion.
#
#   gralloc/build.sh <aosp-tree> <tablet-libs>
#
# <aosp-tree>    LineageOS 23.2 / AOSP 16 source tree (read only). Used for
#                system/memory/libdmabufheap (BufferAllocator, compiled in statically,
#                as libdmabufheap is not part of VNDK v30) and the frozen
#                android.hardware.graphics.common AIDL V4 snapshot (header-only enums).
# <tablet-libs>  directory filled by gralloc/pull-libs.sh (adb pull from the tablet): the
#                VNDK v30 / LLNDK libraries this links against, plus orig/ with the
#                two vendor gralloc libraries the result is checked against.
#
# Headers of the VNDK-30 libraries (libcxx, libhidl, libgralloctypes, libutils, generated
# HIDL headers ...) come from hwc/hdr/vndk30 (the Android 11 header set the HWC is built
# against; downloaded here if missing), because the new libraries link against the
# device's Android 11 libc++/libhidlbase/libgralloctypes.
#
# Sources (cloned into out/gralloc/src, pinned commits):
#   TinkerBoard-Android/rockchip-android-hardware-libgralloc-midgard   android14-rockchip
#   TinkerBoard-Android/rockchip-android-hardware-rk35-libhardware_rockchip (hardware_rockchip.h)
#
# Configuration = what the android14-rockchip Android.bp files hard-code (gralloc 4.x,
# Rockchip format selection, dma-buf heap allocator, GRALLOC_INIT_AFBC,
# GRALLOC_USE_ION_DMABUF_SYNC) plus gralloc.device.mk defaults for a board without Mali
# display/video IP (MALI_DISPLAY_VERSION=0, MALI_VIDEO_VERSION=0, no static AFBC
# capability bits: the GPU capabilities are read from /vendor/lib/egl/libGLES_mali.so).
#
# Output: vendor-changes/lib/hw/android.hardware.graphics.allocator@4.0-impl-midgard.so
#         vendor-changes/lib/hw/android.hardware.graphics.mapper@4.0-impl-midgard.so
# Env: NDK (default ~/Android/Sdk/ndk/25.0.8775105), AIDL (default newest SDK build-tools
#      aidl), VNDK30 (header set), JOBS.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
T=$(cd "${1:?usage: $0 <aosp-tree> <tablet-libs>}" && pwd)
LIBS=$(cd "${2:?usage: $0 <aosp-tree> <tablet-libs>}" && pwd)
NDK=${NDK:-$HOME/Android/Sdk/ndk/25.0.8775105}
AIDL=${AIDL:-$(ls -d "$HOME"/Android/Sdk/build-tools/*/aidl | sort -V | tail -1)}
OUT=$ROOT/out/gralloc
VNDK30=${VNDK30:-$ROOT/hwc/hdr/vndk30}
API=30

GRALLOC_URL=https://github.com/TinkerBoard-Android/rockchip-android-hardware-libgralloc-midgard.git
GRALLOC_COMMIT=f3be79b37b12ab2202b0e371415d5bf749622f92
HWR_URL=https://github.com/TinkerBoard-Android/rockchip-android-hardware-rk35-libhardware_rockchip.git
HWR_COMMIT=223df5502fae66ca3a3462450fa4808956f9c32f
VNDK30_URL=https://github.com/leohearts/ifivemini-rk3288-android16/releases/download/init/vndk30.tar.gz

ALLOC=android.hardware.graphics.allocator@4.0-impl-midgard.so
MAPPER=android.hardware.graphics.mapper@4.0-impl-midgard.so

TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
CXX=$TC/bin/armv7a-linux-androideabi$API-clang++
for f in "$CXX" "$AIDL" "$T/system/memory/libdmabufheap/BufferAllocator.cpp" \
         "$T/hardware/interfaces/graphics/common/aidl/aidl_api/android.hardware.graphics.common/4/.hash" \
         "$ROOT/hwc/hdr/libgralloc/interfaces/aidl/aidl_api/arm.graphics/1/arm/graphics/ArmMetadataType.aidl"; do
    [ -e "$f" ] || { echo "STOP: missing $f"; exit 1; }
done
for l in libhardware liblog libcutils libion libsync libutils libnativewindow libhidlbase libgralloctypes \
         libdrm libbase libc++ android.hardware.graphics.allocator@4.0 android.hardware.graphics.mapper@4.0 \
         android.hardware.graphics.common@1.2; do
    [ -f "$LIBS/$l.so" ] || { echo "STOP: missing $LIBS/$l.so (run gralloc/pull-libs.sh)"; exit 1; }
done
mkdir -p "$OUT"

echo "== 1. sources"
clone() { # <url> <commit> <dir>
    if [ ! -d "$3/.git" ]; then
        git clone -q --single-branch --branch android14-rockchip "$1" "$3"
    fi
    git -C "$3" reset -q --hard "$2"   # drops the patches of an earlier run
    [ "$(git -C "$3" rev-parse HEAD)" = "$2" ] || { echo "STOP: $3 is not at $2"; exit 1; }
}
SRC=$OUT/src/libgralloc-midgard
HWR=$OUT/src/libhardware_rockchip
mkdir -p "$OUT/src"
clone "$GRALLOC_URL" "$GRALLOC_COMMIT" "$SRC"
clone "$HWR_URL" "$HWR_COMMIT" "$HWR"
if [ ! -d "$VNDK30/external/libcxx/include" ]; then
    echo "   downloading $VNDK30_URL"
    mkdir -p "$(dirname "$VNDK30")"
    curl -sfL "$VNDK30_URL" | tar xz -C "$(dirname "$VNDK30")"
fi
for p in "$HERE"/patches/*.patch; do
    [ -f "$p" ] || continue
    if patch -d "$SRC" -p1 -N -s --dry-run < "$p" >/dev/null 2>&1; then
        patch -d "$SRC" -p1 -N -s < "$p"
        echo "   applied $(basename "$p")"
    fi
done

echo "== 2. AIDL NDK headers (enums only: arm.graphics V1, graphics.common V4)"
GEN=$OUT/gen
rm -rf "$GEN"; mkdir -p "$GEN"
gen() { # <api snapshot dir>  <aidl files...>
    local dir=$1; shift
    local f
    for f in "$@"; do
        "$AIDL" --lang=ndk --structured --stability=vintf -I "$dir" -h "$GEN/include" -o "$GEN/src" "$f"
    done
}
ARMAPI=$ROOT/hwc/hdr/libgralloc/interfaces/aidl/aidl_api/arm.graphics/1
gen "$ARMAPI" "$ARMAPI"/arm/graphics/*.aidl
# The device's libgralloctypes is built against graphics.common V1, whose BufferUsage lacks
# FRONT_BUFFER (used with GRALLOC_ALLOCATOR_AIDL_VERSION=1). The enum is header-only and the
# type layouts gralloctypes uses are identical in V1..V4, so the V4 BufferUsage.h goes first
# in the include path, in front of the V1 headers of the vndk30 set.
CMNAPI=$T/hardware/interfaces/graphics/common/aidl/aidl_api/android.hardware.graphics.common/4
gen "$CMNAPI" "$CMNAPI/android/hardware/graphics/common/BufferUsage.aidl"

echo "== 3. compile"
V=$VNDK30
INC=(
    -nostdinc++ -isystem "$V/external/libcxx/include" -isystem "$V/external/libcxxabi/include"
    -I "$SRC/src" -I "$SRC/interfaces/libs/drmutils" -I "$HWR/include"
    -I "$GEN/include" -I "$SRC/src/capabilities"
    -I "$V"/generated-headers/hardware/interfaces/graphics/common/aidl/*ndk_platform-source/gen/include
    -I "$V/hardware/libhardware/include"
    -I "$V/system/core/libutils/include" -I "$V/system/core/libcutils/include_vndk" -I "$V/system/core/libcutils/include"
    -I "$V/system/core/liblog/include_vndk" -I "$V/system/core/libsystem/include" -I "$V/system/core/base/include"
    -I "$V/frameworks/native/libs/nativewindow/include" -I "$V/frameworks/native/libs/nativebase/include"
    -I "$V/frameworks/native/libs/arect/include" -I "$V/frameworks/native/libs/gralloc/types/include"
    -I "$V/frameworks/native/libs/binder/ndk/include_ndk" -I "$V/frameworks/native/libs/binder/ndk/include_platform"
    -I "$V/system/libhidl/base/include" -I "$V/system/libhidl/transport/include" -I "$V/system/libhwbinder/include"
    -I "$V/system/libfmq/include" -I "$V/system/libfmq/base"
    -I "$V/system/memory/libion/include" -I "$V/system/memory/libion/kernel-headers"
    -I "$ROOT/hwc/hdr/aosp/system/core/libsync/include" -I "$ROOT/hwc/hdr/aosp/external/libdrm"
    -I "$ROOT/hwc/hdr/aosp/external/libdrm/include" -I "$ROOT/hwc/hdr/aosp/external/libdrm/include/drm"
    -I "$T/system/memory/libdmabufheap/include"
)
for d in graphics/allocator/4.0 graphics/mapper/4.0 graphics/common/1.0 graphics/common/1.1 graphics/common/1.2; do
    INC+=(-I "$V"/generated-headers/hardware/interfaces/$d/*genc++_headers/gen)
done
INC+=(-I "$V"/generated-headers/system/libhidl/transport/base/1.0/*genc++_headers/gen
      -I "$V"/generated-headers/system/libhidl/transport/manager/1.0/*genc++_headers/gen)
# configuration of the android14-rockchip midgard Android.bp, gralloc 4.x, SDK 30 vendor
DEF=(
    -DANDROID -D__ANDROID_VENDOR__ -D__ANDROID_VNDK__ -D_LIBCPP_ENABLE_THREAD_SAFETY_ANNOTATIONS=1 -DNDEBUG
    -DGRALLOC_LIBRARY_BUILD=1 -DDISABLE_FRAMEBUFFER_HAL=1 -DGRALLOC_USE_LEGACY_CALCS=0 -DGRALLOC_USE_LEGACY_LOCK=0
    -DUSE_RK_SELECTING_FORMAT_MANNER=1 -DMALI_DISPLAY_VERSION=0 -DGRALLOC_CAMERA_WRITE_RAW16=1
    -DPLATFORM_SDK_VERSION=$API -DGRALLOC_HOST_BUILD=0
    '-DLOG_TAG="gralloc4"' -DGRALLOC_VERSION_MAJOR=4 -DHIDL_ALLOCATOR_VERSION_SCALED=400
    -DHIDL_MAPPER_VERSION_SCALED=400 -DHIDL_COMMON_VERSION_SCALED=120 -DGRALLOC_ALLOCATOR_AIDL_VERSION=1
)
CXXFLAGS=(--target=armv7a-linux-androideabi$API --sysroot="$TC/sysroot" -std=gnu++17 -fPIC -mthumb -O2
          -mfloat-abi=softfp -mfpu=neon -fno-rtti -fno-exceptions -fvisibility-inlines-hidden
          -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=2
          -Wno-unused-parameter -Wno-deprecated-declarations -Wno-error)
OBJ=$OUT/obj; rm -rf "$OBJ"; mkdir -p "$OBJ"
compile() { # <object group> <source> [extra flags...]
    local grp=$1 s=$2; shift 2
    local o=$OBJ/${grp}_$(basename "${s%.cpp}").o
    "$CXX" "${CXXFLAGS[@]}" "${DEF[@]}" "${INC[@]}" "$@" -c "$s" -o "$o" 2>"$o.log" ||
        { echo "FAILED: $s"; grep -m8 -A3 'error' "$o.log"; return 1; }
}
# libgralloc_core_midgard
for s in mali_gralloc_bufferaccess mali_gralloc_bufferallocation mali_gralloc_formats \
         mali_gralloc_reference mali_gralloc_debug format_info; do
    compile core "$SRC/src/core/$s.cpp" -DGRALLOC_DISP_W=0 -DGRALLOC_DISP_H=0 &
done
# libgralloc_capabilities_midgard (32-bit library paths)
compile capabilities "$SRC/src/capabilities/src/gralloc_capabilities.cpp" -DMALI_VIDEO_VERSION=0 \
    '-DMALI_GRALLOC_GPU_LIBRARY_PATH1="/vendor/lib/egl/"' '-DMALI_GRALLOC_GPU_LIBRARY_PATH2="/system/lib/egl/"' \
    '-DMALI_GRALLOC_DPU_LIBRARY_PATH="/vendor/lib/hw/"' '-DMALI_GRALLOC_DPU_AEU_LIBRARY_PATH="/vendor/lib/hw/"' &
# libgralloc_allocator_midgard: dma-buf heap allocator
for s in mali_gralloc_dmabufheap mali_gralloc_shared_memory; do
    compile allocator "$SRC/src/allocator/$s.cpp" -DGRALLOC_INIT_AFBC=1 -DGRALLOC_USE_ION_DMABUF_SYNC=1 &
done
for s in Allocator Mapper RegisteredHandlePool MapperMetadata SharedMetadata; do
    compile hidl_common "$SRC/src/hidl_common/$s.cpp" &
done
for s in GrallocAllocator GrallocMapper; do compile 4.x "$SRC/src/4.x/$s.cpp" & done
compile drmutils "$SRC/interfaces/libs/drmutils/src/drmutils.cpp" &
# libdmabufheap: dma-buf heap helper with the ION fallback; links the device's libion/libbase
compile libdmabufheap "$T/system/memory/libdmabufheap/BufferAllocator.cpp" -Du64=__u64 &
fail=0
for p in $(jobs -p); do wait "$p" || fail=1; done
[ "$fail" = 0 ] || exit 1

echo "== 4. link"
core=()
for o in "$OBJ"/core_*.o "$OBJ"/capabilities_*.o "$OBJ"/allocator_*.o "$OBJ"/libdmabufheap_*.o; do core+=("$o"); done
cat > "$OUT/allocator.map" <<'EOF'
{ global: HIDL_FETCH_IAllocator; local: *; };
EOF
cat > "$OUT/mapper.map" <<'EOF'
{ global: HIDL_FETCH_IMapper; local: *; };
EOF
link() { # <soname> <version script> <objects...>
    local name=$1 map=$2; shift 2
    "$CXX" --target=armv7a-linux-androideabi$API --sysroot="$TC/sysroot" -shared -nostdlib++ -fuse-ld=lld \
        -Wl,-soname,"$name" -Wl,--version-script="$map" -Wl,--gc-sections -Wl,--hash-style=gnu \
        -Wl,-z,noexecstack -Wl,--no-undefined -Wl,--allow-shlib-undefined -Wl,--build-id=sha1 \
        -Wl,--as-needed -Wl,--icf=all -Wl,--pack-dyn-relocs=android \
        -o "$OUT/$name" "$@" "${core[@]}" -L "$LIBS" \
        -l:libhardware.so -l:liblog.so -l:libcutils.so -l:libion.so -l:libsync.so -l:libutils.so \
        -l:libnativewindow.so -l:libhidlbase.so -l:libgralloctypes.so -l:libbase.so \
        -l:android.hardware.graphics.mapper@4.0.so -l:android.hardware.graphics.common@1.2.so \
        "${EXTRA_LIBS[@]}" -l:libc++.so -lc -lm -ldl
    "$TC/bin/llvm-strip" --strip-unneeded "$OUT/$name"
}
# allocator: HIDL allocator@4.0 stub; mapper: libdrm (drm modifiers/fourcc helpers)
EXTRA_LIBS=(-l:android.hardware.graphics.allocator@4.0.so)
link "$ALLOC" "$OUT/allocator.map" "$OBJ"/4.x_GrallocAllocator.o "$OBJ"/hidl_common_Allocator.o "$OBJ"/hidl_common_SharedMetadata.o
EXTRA_LIBS=(-l:libdrm.so)
link "$MAPPER" "$OUT/mapper.map" "$OBJ"/4.x_GrallocMapper.o "$OBJ"/hidl_common_Mapper.o "$OBJ"/hidl_common_RegisteredHandlePool.o \
    "$OBJ"/hidl_common_MapperMetadata.o "$OBJ"/hidl_common_SharedMetadata.o "$OBJ"/drmutils_drmutils.o

echo "== 5. checks"
# private_handle_t ABI (libGLES_mali.so r18p0 handle validation, Android 11 gralloc headers of the HWC)
LAYOUT_INC=("${INC[@]}")
for headers in "$SRC/src" "$ROOT/hwc/hdr/libgralloc/src"; do
    "$CXX" "${CXXFLAGS[@]}" -Wno-invalid-offsetof "${DEF[@]}" "${LAYOUT_INC[@]}" -I "$headers" -fsyntax-only "$HERE/layout-check.cpp" ||
        { echo "STOP: private_handle_t layout differs for headers in $headers"; exit 1; }
    echo "-- private_handle_t layout (size 232, magic 0x3141592, numFds+numInts 55) matches: $headers"
done
mkdir -p "$ROOT/vendor-changes/lib/hw"
for f in "$ALLOC" "$MAPPER"; do
    install -m 0644 "$OUT/$f" "$ROOT/vendor-changes/lib/hw/$f"
    echo "-- $f: $(stat -c %s "$OUT/$f") bytes, sha256 $(sha256sum "$OUT/$f" | cut -d' ' -f1)"
    needed=$("$TC/bin/llvm-readelf" -d "$OUT/$f" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p')
    echo "   NEEDED:   $(echo $needed)"
    # everything NEEDED must be a library that is on the tablet (pulled into $LIBS from the VNDK v30
    # apex, /system/lib LLNDK or /vendor/lib) or one of the bionic libraries
    for n in $needed; do
        case $n in libc.so|libm.so|libdl.so) ;; *) [ -f "$LIBS/$n" ] || { echo "STOP: $n is not a tablet library"; exit 1; } ;; esac
    done
    exported=$("$TC/bin/llvm-nm" -D --defined-only "$OUT/$f" | awk '$2 ~ /[TWDBR]/ {print $3}')
    echo "   exported: $(echo $exported)"
    case $f in *allocator*) sym=HIDL_FETCH_IAllocator ;; *) sym=HIDL_FETCH_IMapper ;; esac
    [ "$exported" = "$sym" ] || { echo "STOP: expected the single export $sym"; exit 1; }
    [ -f "$LIBS/orig/$f" ] && echo "   original exports $sym: $("$TC/bin/llvm-nm" -D --defined-only "$LIBS/orig/$f" | awk -v s="$sym" '$3 == s' | wc -l)"
done
echo "built: vendor-changes/lib/hw/{$ALLOC,$MAPPER}"
