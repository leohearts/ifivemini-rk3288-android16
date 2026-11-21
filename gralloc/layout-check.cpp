// Compile-time check of the private_handle_t ABI that other vendor code relies on.
//
// libGLES_mali.so (r18p0-01rel0) validates every handle it imports in
// mali_egl_image_get_format (disassembly, vendor image /lib/egl/libGLES_mali.so):
//     ldr r0,[r4]       ; cmp r0,#12        -> native_handle.version == sizeof(native_handle)
//     ldr r0,[r4,#20]   ; cmp r0,#0x3141592 -> private_handle_t::magic at offset 20
//     ldmib r4,{r0,r1}  ; add; cmp r0,#55   -> numFds + numInts == 55
//     ldr r0,[r4,#12]   ; cmn r0,#1; ble    -> share_fd at offset 12
// gralloc/build.sh compiles this file against the android14-rockchip gralloc headers and
// against hwc/hdr/libgralloc/src (the Android 11 headers the HWC and the vendor
// gralloc were built with); both must pass with the same numbers.
#include <cstddef>

#include "mali_gralloc_buffer.h"

static_assert(sizeof(native_handle_t) == 12, "native_handle header");
static_assert(sizeof(private_handle_t) == 232, "private_handle_t size");
static_assert(private_handle_t::sMagic == 0x3141592, "private_handle_t magic");
static_assert(GRALLOC_ARM_NUM_FDS + NUM_INTS_IN_PRIVATE_HANDLE == 55, "numFds + numInts");

#define CHECK_OFFSET(field, off) \
    static_assert(offsetof(private_handle_t, field) == (off), "offset of " #field)
CHECK_OFFSET(share_fd, 12);
CHECK_OFFSET(share_attr_fd, 16);
CHECK_OFFSET(magic, 20);
CHECK_OFFSET(flags, 24);
CHECK_OFFSET(width, 28);
CHECK_OFFSET(height, 32);
CHECK_OFFSET(req_format, 36);
CHECK_OFFSET(producer_usage, 40);
CHECK_OFFSET(consumer_usage, 48);
CHECK_OFFSET(internal_format, 56);
CHECK_OFFSET(stride, 64);
CHECK_OFFSET(byte_stride, 68);
CHECK_OFFSET(internalWidth, 72);
CHECK_OFFSET(internalHeight, 76);
CHECK_OFFSET(alloc_format, 80);
CHECK_OFFSET(plane_info, 88);
CHECK_OFFSET(size, 136);
CHECK_OFFSET(layer_count, 140);
CHECK_OFFSET(base, 144);
CHECK_OFFSET(backing_store_id, 152);
CHECK_OFFSET(backing_store_size, 160);
CHECK_OFFSET(cpu_read, 164);
CHECK_OFFSET(cpu_write, 168);
CHECK_OFFSET(allocating_pid, 172);
CHECK_OFFSET(remote_pid, 176);
CHECK_OFFSET(ref_count, 180);
CHECK_OFFSET(attr_base, 184);
CHECK_OFFSET(yuv_info, 192);
CHECK_OFFSET(fd, 196);
CHECK_OFFSET(offset, 200);
CHECK_OFFSET(attr_size, 208);
CHECK_OFFSET(reserved_region_size, 216);
CHECK_OFFSET(imapper_version, 224);
