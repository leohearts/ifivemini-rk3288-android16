# FbconWake: wake shows fbcon instead of Android

## Verified
- Kernel is 4.19 (`ksrc-touch/Makefile`: VERSION 4, PATCHLEVEL 19).
- `SOC_ID` CRTC property is absent for RK3288 VOP1. A grep of `ksrc-touch/drivers/gpu/drm` finds it only in `rockchip_drm_vop2.c`, not in the VOP1 driver.
- HWC log (`runs/fbfix/uevent_test.txt`, `logcat_now.txt`):
  - `BindDpyRes,line=1942 TryAssignPlane fail, ret = -1`
  - `CheckStateAndReinit,line=670 Failed to BindDpyRes for display=0 -1`
  - `HandleEvent,line=5333 hotplug ... state is error, skip hotplug`
- `SetPowerMode,line=2498 init_success_=0 skip.` repeats on every power transition, and HWComposer gets `BAD_DISPLAY`.
- DRM state (`runs/fbfix/dri_before.txt`, `drm_boot_state.txt`): `plane-0` stays on `crtc-0` with `fb=70`, `allocated by = [fbcon]`. Planes 1–5 are unused. Nothing takes over the primary plane. Connector `card0-DSI-1` reports `connected`.
- Code path:
  - `drm/drmcrtc.cpp` reads `SOC_ID`. On failure it forces `soc_id_` only under `#ifdef RK3399` or `#elif defined(RK3326)`, and only for kernels 4.4/4.19. There is no RK3288 branch.
  - `Planner::CreateInstance` and `HwcPlatform::CreateInstance` (`rockchip/platform/common/platform.cpp`) register stages only for `case 0x3288`. With `soc_id_ == 0` they register nothing, so `TryAssignPlane` returns -1.
- `Android.mk` defines `RK3576`, `RK3399` and `RK3326` macros. It defines no `RK3288` macro.

## Root cause (strong, not fully proven)
On this kernel, the RK3288 VOP1 exposes no `SOC_ID`. The HWC fallback that forces `soc_id_` exists only for RK3399/RK3326. With `soc_id_ == 0`, no planner or HWC stage is registered for RK3288, so `BindDpyRes` fails. Init is left at `init_success_=0`, so display power commands are skipped and the panel never leaves fbcon. The `fbcon` framebuffer (fb 70) stays on the primary plane.

Not yet directly observed: the `"Cann't fina a suitable Planner Stage, soc_id=0"` log line. My logcat grep for it returned nothing, so treat it as expected, not seen.

## Open discrepancy
`runs/fbfix/fbfix_wake.png` shows the Android lock screen (clock 8:14, USB debugging notification), not fbcon. `fbfix_fixed.png` and `fbfix_now.png` are byte-identical (`cmp` reports SAME). The screenshot may be a SurfaceFlinger snapshot, not what the panel scanned out. This needs a direct check of what the panel actually shows after wake, for example a photo or an fbcon-vs-plane readout during the wake.

## Fix proposal (not applied)
1. `drm/drmcrtc.cpp`: add an RK3288 branch next to RK3399/RK3326. When `SOC_ID` is missing on 4.19, force `soc_id_ = 0x3288`.
2. `Android.mk`: add `-DRK3288=1` in the platform define block so the branch compiles.
3. Rebuild the HWC `.so`, flash, wake the device, and check that `TryAssignPlane` succeeds and `plane-0` moves off fbcon.

## Checks for Main
- Build the HWC `.so` (`hwc/build` script) after the fix.
- Flash the vendor `.so`, reboot, press power, and capture the panel, not just SurfaceFlinger.
- Confirm `logcat` no longer shows `TryAssignPlane fail` or `init_success_=0`.
- Keep `fbcon=font:SUN12x22` and `console=tty0` in bootargs, as requested.
