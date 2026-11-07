/*
 * Compat shim for the RGA handle API used by drmhwc2 (lineage-23.2).
 *
 * The bundled librga in hwc/hdr/librga implements the older rga_buffer_t API
 * (wrapbuffer_*, imresize, ...). It has no rga_buffer_handle_t and no
 * releasebuffer_handle(). The HWC source expects both.
 *
 * This header is force-included (-include) by build-hwc2.sh. It only adds the
 * declarations needed to compile the handle-based call sites. It defines no
 * behavior. The symbols must be provided by a librga build that exports the
 * handle API. checkso.py reports them as unresolved until that exists.
 *
 * The typedef width is an [INFERENCE]: the source compares the handle with
 * `> 0` and initialises it with `= 0`, which fits an unsigned integer handle.
 */
#ifndef HWC_STUB_RGA_HANDLE_COMPAT_H_
#define HWC_STUB_RGA_HANDLE_COMPAT_H_

#include <stdint.h>

typedef uint32_t rga_buffer_handle_t;

// Declared here, not defined. Return value < 0 signals failure in the caller.
extern "C" int releasebuffer_handle(rga_buffer_handle_t handle);
// Declared here, not defined. Returns 0 on failure (caller checks `== 0`).
// Matches the handle API used by drmbuffer.cpp:761 and resourcescache.cpp:86.
extern "C" rga_buffer_handle_t importbuffer_fd(int fd, int size);

// STUB: LayerNameLength is defined only in hwc/hdr/rkhw/hardware/hwcomposer_defs.h
// (value 60, line 148). The vndk30 hwcomposer_defs.h has the same include guard and
// is loaded first by hwcomposer2.h's quoted include, so the rkhw copy is skipped and
// rkhw/hardware/hwcomposer.h:181 fails. Defining the same value here is legal
// (identical redefinition). Remove once the HWC1 and HWC2 defs are split.
#ifndef LayerNameLength
#define LayerNameLength 60
#endif

#endif  // HWC_STUB_RGA_HANDLE_COMPAT_H_
