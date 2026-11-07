/*
 * STUB header for the vendor libbaseparameter API.
 *
 * Source: NOT available in the repo. Reconstructed from the call sites in
 * rockchip/common/drmbaseparameter.cpp (api_.validate, api_.get_disp_info,
 * api_.set_screen_info; info->screen_info[0].{type,id,resolution}) and from
 * the field names used there. Layouts are the minimum needed to compile;
 * they are NOT the vendor ABI.
 *
 * The member functions are declared but NOT defined here. They must be
 * provided at runtime by the vendor libbaseparameter. Until that library is
 * linked, checkso.py reports them as unresolved.
 */
#ifndef HWC_STUB_BASEPARAMETER_API_H_
#define HWC_STUB_BASEPARAMETER_API_H_

#include <stdint.h>
#include <xf86drmMode.h>  // drmModeModeInfo, for screen_info.resolution

struct overscan_info {
  uint32_t maxvalue;
  uint32_t leftscale;
  uint32_t rightscale;
  uint32_t topscale;
  uint32_t bottomscale;
};

struct framebuffer_info {
  uint32_t framebuffer_width;
  uint32_t framebuffer_height;
  uint32_t fps;
};

struct bcsh_info {
  uint32_t brightness;
  uint32_t contrast;
  uint32_t saturation;
  uint32_t hue;
};

struct screen_info {
  uint32_t type;
  uint32_t id;
  drmModeModeInfo resolution;
  // Output format, depth and feature. Names come from the bp.cpp dump; layout is an [INFERENCE].
  uint32_t format;
  uint32_t depthc;
  uint32_t feature;
};

// Stub LUT blob: `size` entries per channel. Member names and uint16_t channel
// type are taken from drmdevice.cpp call sites (drm_color_lut is uint16_t per
// channel); the vendor ABI was not inspected, so this layout is [INFERENCE].
struct lut_data {
  uint32_t size;
  uint16_t *lred;
  uint16_t *lgreen;
  uint16_t *lblue;
};

struct disp_info {
  uint32_t connector_type;
  uint32_t connector_id;
  struct overscan_info overscan_info;
  struct framebuffer_info framebuffer_info;
  struct bcsh_info bcsh_info;
  struct screen_info screen_info[2];
  // Gamma and 3D LUT blobs. Only `.size` is read by the call sites in
  // drmbaseparameter.cpp; `data` is an [INFERENCE] layout.
  struct lut_data gamma_lut_data;
  struct lut_data cubic_lut_data;
};

class baseparameter_api {
 public:
  baseparameter_api();
  ~baseparameter_api();

  // Stub: vendor implementation required.
  int validate();
  // Stub: vendor implementation required.
  int get_disp_info(unsigned int connector_type, unsigned int connector_id,
                    struct disp_info *info);
  // Stub: vendor implementation required.
  int set_screen_info(unsigned int connector_type, unsigned int connector_id,
                      int index, struct screen_info *info);
};

#endif  // HWC_STUB_BASEPARAMETER_API_H_
