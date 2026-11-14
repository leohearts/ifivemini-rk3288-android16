#!/bin/bash
# Build Rockchip drm_hwcomposer 0.66 (005b18b) -> hwcomposer.rk30board.so for RK3288 / Android 11
# Flags mirror Android.mk with: TARGET_BOARD_PLATFORM=rk3288, TARGET_BOARD_PLATFORM_PRODUCT=tablet,
# TARGET_BOARD_PLATFORM_GPU=mali-t760, TARGET_RK_GRALLOC_VERSION=4, PLATFORM_SDK_VERSION=30, HWC2 off.
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$H/src-a16}
OUT=${OUT:-$H/out}
NDK=${NDK:-/home/leohearts/Android/Sdk/ndk/25.0.8775105}
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
SYSROOT=$TC/sysroot
CXX=$TC/bin/clang++
CC=$TC/bin/clang
TARGET=armv7a-linux-androideabi30
HDR=$H/hdr
V=${VNDK30:-$HDR/vndk30}   # release asset hwc-hdr-vndk30.tar.zst extracted here
VENDOR_LIB=$H/libs   # libdrm/librga/libsync_vendor from the vendor image, the rest from the GSI system image
SYSLIB=$H/libs
OBJ=$OUT/obj
mkdir -p "$OBJ"

GEN=$V/generated-headers
INCS=(
  # libc++ of the device (AOSP libc++, std::__1) -- NOT the NDK's __ndk1
  -nostdinc++ -isystem $V/external/libcxx/include -isystem $V/external/libcxxabi/include
  -I$SRC
  -I$SRC/../hdr/libgralloc/src -I$HDR/libgralloc -I$HDR/librga/include -I$HDR/librga
  -I$H/hdr2
  -I$HDR/rkhw -I$HDR/rkdrm
  -I$HDR/aosp/external/tinyxml2
  -I$HDR/aosp/external/libdrm -I$HDR/aosp/external/libdrm/include/drm -I$HDR/aosp/external/libdrm/include
  -I$HDR/aosp/system/core -I$HDR/aosp/system/core/libsync/include
  -I$V/system/core/libutils/include -I$V/system/core/libcutils/include_vndk -I$V/system/core/libcutils/include
  -I$V/system/core/liblog/include_vndk -I$V/system/core/libsystem/include -I$V/system/core/libprocessgroup/include
  -I$V/system/core/base/include -I$V/system/core/libbacktrace/include
  -I$V/hardware/libhardware/include -I$V/hardware/libhardware_legacy/include
  -I$V/frameworks/native/libs/ui/include_vndk -I$V/frameworks/native/libs/ui/include
  -I$V/frameworks/native/libs/nativewindow/include -I$V/frameworks/native/libs/nativebase/include
  -I$V/frameworks/native/libs/arect/include -I$V/frameworks/native/libs/math/include
  -I$V/frameworks/native/libs/gralloc/types/include
  -I$V/frameworks/native/libs/binder/ndk/include_ndk -I$V/frameworks/native/libs/binder/ndk/include_platform
  -I$V/frameworks/native/opengl/include
  -I$V/system/libhidl/base/include -I$V/system/libhidl/transport/include -I$V/system/libhidl/transport/base/1.0
  -I$V/system/libhwbinder/include -I$V/system/libfmq/include -I$V/system/libfmq/base
  -I$V/system/libhidl/transport/token/1.0/utils/include
  -I$V/system/core/libprocessgroup
)
# generated HIDL / AIDL headers
for d in "$GEN"/hardware/interfaces/graphics/mapper/4.0/*genc++_headers/gen \
         "$GEN"/hardware/interfaces/graphics/common/1.0/*genc++_headers/gen \
         "$GEN"/hardware/interfaces/graphics/common/1.1/*genc++_headers/gen \
         "$GEN"/hardware/interfaces/graphics/common/1.2/*genc++_headers/gen \
         "$GEN"/system/libhidl/transport/base/1.0/*genc++_headers/gen \
         "$GEN"/system/libhidl/transport/manager/1.0/*genc++_headers/gen \
         "$GEN"/hardware/interfaces/graphics/common/aidl/*ndk_platform-source/gen/include \
         "$GEN"/hardware/interfaces/graphics/common/aidl/*ndk_platform-source/gen/include; do
  [ -d "$d" ] && INCS+=(-I"$d")
done
[ -n "${EXTRA_INC:-}" ] && INCS+=($EXTRA_INC)

# --- flags from Android.mk (rk3288, tablet/MID, mali-t760, gralloc4, SDK 30) ---
DEFS=(
  -DANDROID_R -DANDROID_P -DDRM_DRIVER_VERSION=2 -DUSE_NO_ASPECT_RATIO=1
  -DUSE_GRALLOC_4=1 -DRK_MID
  -DPLATFORM_SDK_VERSION=30
  -DMALI_PRODUCT_ID_T76X=1
  -DTARGET_BOARD_PLATFORM_RK3288 -DMALI_AFBC_GRALLOC=1 -DRK_MULTI_AREAS_FORMAT_LIMIT -DRK3288_MID
  -DDUAL_VIEW_MODE=0
  -DUSE_SQUASH=0 -DRK_RGA_TEST=0 -DRK_VR=0 -DRK_STEREO=0 -DUSE_GL_WORKER=0
  -DUSE_DRM_GENERIC_IMPORTER -DUSE_MULTI_AREAS=1 -DRK_RGA_PREPARE_ASYNC=1 -DRK_RGA_COMPSITE_SYNC=0
  -DUSE_AFBC_LAYER=0 -DRK_SKIP_SUB=1 -DRK_VIDEO_UI_OPT=1 -DRK_VIDEO_SKIP_LINE=1
  -DRK_INVALID_REFRESH=1 -DRK_HDR_PERF_MODE=0 -DRK_3D_VIDEO=1 -DRK_PRINT_LAYER_NAME=1
  -DRK_SORT_AREA_BY_XPOS=0 -DRK_HOR_INTERSECT_LIMIT=1 -DRK_RGA_SCALE_AND_ROTATE=1
  -DRGA_VER=3 -DRK_PER_MODE=0 -DRK_ROTATE_VIDEO_MODE=1 -DRK_CTS_WORKROUND=0
  '-DRK_GRAPHICS_VER="RK_GRAPHICS_VER=commit-id:2e49c26"'
  -D__ANDROID_VNDK__ -D__ANDROID_VENDOR__ -DANDROID -D_LIBCPP_ENABLE_THREAD_SAFETY_ANNOTATIONS=1
  -DNDEBUG
)
CFLAGS_COMMON=(--target=$TARGET --sysroot=$SYSROOT -fPIC -mthumb -Os -fno-strict-aliasing -g0 -ffunction-sections -fdata-sections
  -Wno-unused-function -Wno-unused-parameter -Wno-unused-variable -Wno-error -w
  -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fmacro-prefix-map=$SRC=hardware/rockchip/hwcomposer/drmhwc -fno-exceptions -fno-rtti -fvisibility-inlines-hidden -mfloat-abi=softfp -mfpu=neon)
CXXFLAGS=("${CFLAGS_COMMON[@]}" -std=gnu++17 -include unistd.h)  # hwc_util.cpp relies on a transitive <unistd.h> in the AOSP tree

SRCS=(autolock drmresources drmcomposition drmcompositor drmcompositorworker drmconnector drmcrtc
  drmdisplaycomposition drmdisplaycompositor drmencoder drmeventlistener drmmode drmplane drmproperty
  glworker hwcomposer platform platformdrmgeneric platformnv separate_rects virtualcompositorworker
  vsyncworker worker hwc_util hwc_rockchip hwc_debug drmgralloc4)

compile() {
  local f=$1
  "$CXX" "${CXXFLAGS[@]}" "${DEFS[@]}" "${INCS[@]}" -c "$SRC/$f.cpp" -o "$OBJ/$f.o"
}
export -f compile 2>/dev/null || true
pids=(); fail=0
for f in "${SRCS[@]}"; do
  ( compile "$f" ) 2> "$OBJ/$f.log" & pids+=($!)
  while [ "$(jobs -rp | wc -l)" -ge "$(nproc)" ]; do wait -n || true; done
done
for p in "${pids[@]}"; do wait "$p" || fail=1; done
# tinyxml2 (static, as LOCAL_STATIC_LIBRARIES := libtinyxml2)
"$CXX" "${CXXFLAGS[@]}" "${DEFS[@]}" "${INCS[@]}" -c "$HDR/aosp/external/tinyxml2/tinyxml2.cpp" -o "$OBJ/tinyxml2.o" 2> "$OBJ/tinyxml2.log" || fail=1
if [ $fail -ne 0 ]; then
  echo "COMPILE FAILED"; for f in "${SRCS[@]}" tinyxml2; do [ -s "$OBJ/$f.log" ] && { echo "== $f"; grep -m6 -A3 "error" "$OBJ/$f.log"; }; done; exit 1
fi

# --- link: NEEDED must be a subset of the vendor original's list ---
OBJS=(); for f in "${SRCS[@]}" tinyxml2; do OBJS+=("$OBJ/$f.o"); done
LIBC=$SYSROOT/usr/lib/arm-linux-androideabi/30
mkdir -p "$OUT/stubs"
# --icf / packed relocations (DT_ANDROID_REL, bionic API 23+) keep the .so small enough to
# replace the vendor original in place: the vendor ext4 image has 0 free blocks.
"$CXX" --target=$TARGET --sysroot=$SYSROOT -shared -nostdlib++ -fuse-ld=lld \
  -Wl,-soname,hwcomposer.rk30board.so -Wl,--gc-sections -Wl,--hash-style=gnu -Wl,-z,noexecstack \
  -Wl,--no-undefined -Wl,--allow-shlib-undefined -Wl,--build-id=sha1 -Wl,--as-needed \
  -Wl,--icf=all -Wl,--pack-dyn-relocs=android \
  -o "$OUT/hwcomposer.rk30board.so" "${OBJS[@]}" \
  -L"$VENDOR_LIB" -L"$SYSLIB" -L"$LIBC" \
  -l:libcutils.so -l:libdrm.so -l:libEGL.so -l:libGLESv2.so -l:libhardware.so -l:liblog.so -l:libui.so \
  -l:libutils.so -l:librga.so -l:libsync_vendor.so -l:libhidlbase.so -l:libgralloctypes.so \
  -l:android.hardware.graphics.mapper@4.0.so -l:libc++.so -lc -lm -ldl
echo built "$OUT/hwcomposer.rk30board.so"
cp "$OUT/hwcomposer.rk30board.so" "$OUT/hwcomposer.rk30board.unstripped.so"
"$TC/bin/llvm-strip" --strip-unneeded "$OUT/hwcomposer.rk30board.so"
