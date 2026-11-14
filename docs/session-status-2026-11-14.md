# Session status 2026-11-14 (00:00-04:00)

Nothing committed or pushed. Raw notes: `../lbam/scratch/rev-hwc/ANALYSIS.md`.

## Measurement fixes
- **Composer-only HAL swaps leave SF disconnected.** After `ctl.stop/ctl.start vendor.hwcomposer-2-1`
  SurfaceFlinger is not always killed; it then logs `executeCommands failed ... DEAD_OBJECT` and
  `present failed for display 0: NO_RESOURCES` every frame, the new composer holds DRM master with
  every VOP window disabled (panel black, scrcpy still shows the GPU-composited virtual display) and
  the VOP irq count does not move. Shade J ~18-24 measured in that state (nonblock-commit arms,
  source-HAL arms) is invalid. A HAL swap must restart SurfaceFlinger too.
- **Notification injection must run unrooted**: posts from uid 0 are dropped by NMS.
- **The foreground app and boot change the load**: the same Settings page measured J ~28 in one
  boot and ~43-50 in others; the heavier sessions had one more full-screen VOP window. Only
  same-session A/B comparisons are used below (`../lbam/scratch/arm.sh`, Settings in front,
  checks: same SF pid, DEAD_OBJECT 0, HAL `Composite failed` 0, VOP irq ~60/s, INJECTED >= 12).

## Memory bandwidth is the limit
`../lbam/scratch/ddrmon/ddrmon.ko` (read-only, GRF DFI counters, 10 ms samples): LPDDR2, 2 channels,
396 MHz. During shade animations the busy share stops at 71% in every burst; one full-screen ARGB
window costs ~12%. GPU at 594 vs 198 MHz only shortens GPU time ~18%.

## Changes
| Change | Files | Same-session result |
|---|---|---|
| DDR 396 -> 456 MHz (stock normal rate) via a trust-free DMC driver ported from ChromeOS 4.19 | `kernel/drivers/devfreq/rockchip/*`, `kernel/drivers/soc/rockchip/dmc-sync.c`, `kernel/arch/arm/mach-rockchip/{call_with_mmu_disabled.S,dmc-sram-call.c,embedded/*}`, VOP hook in `rockchip_drm_vop.c`, `kernel-configs/gsi-release.config`, `release-build/resource-release-gsi.dts`, `vendor-changes/etc/init/hw/init.rk3288.rc` | J 42.0/43.3% -> 33.9/34.5%; shade 1-vsync cadence 71.0/68.6% -> 77.9/76.4% |
| HWC: plane-alpha-0 layers get no VOP window | `hwc/src-a16/hwcomposer.cpp` | removes the blank frames SF layer caching caused (`-ENOSPC`, src outside fb); not shipped (vendor keeps 6699) |

## Tried and rejected (measured)
- Nonblocking atomic commit: J unchanged; releases the previous buffers before the new frame is latched.
- SF layer caching (Planner): -2.3 J points with three full-screen planes, +4.4 with two; off.
- VOP AXI gather 8 on win0/win1: no change in J or DDR; removed.
- DDR 528 MHz: SurfaceFlinger SIGILL under load ~1.5 min after the switch; not offered.
- GPU devfreq is not stuck: it spends ~5 s at 594 MHz per 18 s shade burst.

## Device state at the end
Kernel `out/kernel-gsi-release/kernel.img` a2a3a430 (DMC built in), test resource
(release DTS + `rkwdt=1 rkwdt_loader=1 rkwdt_sgrf=0x00420000`), vendor = previous vendor with the new
`init.rk3288.rc` only (HAL 6699). DDR 456 MHz after boot, set by init. 456 MHz soak: 30 shade
bursts + 6 x 128 MiB checksum checks, no crash or kernel error.

## Morning (04:00-05:50)

All arms: Settings in the foreground, 14 notifications, 16 shade animations per arm, same boot unless noted,
HAL `Composite failed` 0, `DEAD_OBJECT` 0, VOP irq ~4300 per 72 s.

### Fixed
- **High-resolution timers were off.** `/proc/timer_list`: `hres_active: 0`, resolution 3333333 ns on all CPUs,
  broadcast device `<NULL>`. Cause: `timer@ff6b0000` (`rockchip,rk3288-timer`) was `disabled` in
  `resource-release-gsi.dts` and the arch timer has no `always-on` (C3STOP). Enabled the node
  (resource `8ebef0fc`, flashed at 0x6000, readback PASS). Now: broadcast `rk_timer`, tick mode 1.
  SF `missedFrames` per arm 423-733 -> 0-44 (cold boot); J unchanged (~33%).
  Side effect: every earlier simpleperf profile on this device was sampled at ~1 per jiffy (3.3 ms);
  their percentages are unreliable.

### Measured, no effect on J
- DDR controller power-down idle count (`pd_cnt` 0/64/255): J 31.8-33.2%. Test parameter removed.
- HAL fb cache (`DrmGenericImporter`, keyed by gralloc4 BufferId) + per-frame debug strings only built when the
  log level asks: composer CPU -16% (11.8 s -> 9.7-10.0 s per arm), J 33.7% both ways. Source kept in
  `hwc/src-a16`, not in the package; device runs vendor HAL 6699.

### Measurement errors found and corrected
- "Restart SF -> J 23%": not real. Those arms started while the restarted framework was still on `FallbackHome`
  with a `BootAnimation` layer. Repeated with a longer settle: 32.6%, same as a cold boot.
  `hal-ab.sh` now settles 60 ping intervals after a composer/SF restart.
- `DisplayColorSetting` Managed vs Enhanced: no difference (all ~23% in that invalid state, interleaved).

### Where the remaining frame time goes (accurate sampling, 0.5 ms period)
- UI thread: ~78% Java (SystemUI dex 36.5%, boot.oat 24.3%, libart 16.7%).
- RenderThread: libhwui 50.2%, libGLES_mali 21.1%, kernel 12.6% (kbase ioctl ~2%), libgui 3.3%.
- Overrun frames (atrace): UI running 19 ms, runnable 5.6 ms, sleeping 7.4 ms (waiting for RenderThread, not for
  SF/HWC buffer release: no `dequeueBuffer` during those waits).

## Evening (17:45-18:35): real-use scenes, landscape composition

Scenes (`lbam/scratch/real3.sh`, 6 background tasks, real gestures, 8 counted rounds each):
portrait recents (KEYCODE_APP_SWITCH), landscape app drawer (swipe up), landscape shade (swipe down).

- Cause found: in landscape the wallpaper layer has `transform=ROTATE90`; `hwcomposer.cpp`
  `is_use_gles_comp` sent the whole frame to GLES for any rotated RGB layer
  ("too many rotate layers", every frame). clientCompositionFrames 369/369 (drawer), 448/451 (shade).
- Fix (hwc/src-a16): one rotated layer (RGB or NV12) is pre-rotated with RGA in `hwc_prepare`
  (existing RK_RGA_PREPARE_ASYNC code, previously NV12 only); RGA output reused while buffer id,
  crop, dst rect, transform, format are unchanged; compositor flushes RGA for any `is_rotate_by_rga`
  layer. `mix_policy`: with more layers than windows, mix down first when all bottom layers are
  unchanged since the previous frame (buffer-id + geometry fingerprint).
- `hwc/build.sh`: `--icf=all --pack-dyn-relocs=android` (vendor fs has 0 free blocks; HAL 366500 B).
- Same-boot A/B (rot-ab.sh), janky %: drawer stock 68.3/70.8, RGA 45.3/45.6, RGA+mixdown 47.0/46.6;
  shade stock 71.6/74.2, RGA 56.1/57.7/53.8, RGA+mixdown 49.8/49.8; recents stock 13.3-15.1,
  new 12.6-15.9. Drawer SF missedFrames ~400 -> 0-4.
- Written to vendor (tool LBA 0x413800, pre-read == previous image, read-back PASS), HAL md5 86579e6f.
  Clean boot: recents 12.3%, drawer 44.4% (0 GPU-composed), shade 46.7%.
- Note: the Magisk module `ifive-hwc-composition` still bind-mounts the old 6699 HAL after boot.
  Composer has already loaded the vendor file by then (maps: fd:01 inode 1137), but any composer
  restart would load the old HAL. Module left untouched (it lives in /data).
- Not verified: the RGA-rotated wallpaper image on the panel (screencap shows SF's GPU path, not VOP).

## 18:37-19:05: landscape shade SurfaceFlinger missed frames

- Trace (gfx/view/sched + VOP irq 40 + sched_blocked_reason): 29 of 200 SF frames had
  `PrevHwcFrameMissed=1`; GPU-missed 1. The composer frame worker's real commits always land on the
  next vblank (180/182 cross exactly one vblank). The composite thread (tid 800) ran a
  DRM_MODE_ATOMIC_TEST_ONLY `CommitFrame` for every geometry-changed frame: 151 tests, 28 over 5 ms,
  max 33.7 ms, blocked behind the blocking commit's `rockchip_drm_atomic_helper_wait_for_vblanks`.
  Its result (`use_hw_overlays_`) was only read by `if (0 && !use_hw_overlays_)` (squash disabled).
- Fix: removed the test commit, the dead squash block and `use_hw_overlays_`.
- Same-boot A/B (notest vs previous vendor HAL 86579e6f), landscape shade: janky 46.3/48.2 vs
  48.7/48.5, SF missedFrames 72/76 vs 329/110; drawer and recents unchanged within noise.
- Written to vendor (pre-read == vendor-rot.img, read-back PASS), HAL 366356 B md5 4ae6ae00;
  composer map_files match 4ae6ae00 after a clean boot.

## Night: recents opened from a running app
- Scene (`lbam/scratch/recset.sh`): open Settings, KEYCODE_APP_SWITCH, 6 swipes, 3 rounds. Settings is a rounded-corner live tile, so SurfaceFlinger composes it (and the wallpaper under it) on the GPU (OutputLayer.cpp:980). Janky frames 78-85%.
- Ruled out: keeping the wallpaper on a VOP window (HWC skip-range change, out-skip): wallpaper became DEVICE, jank unchanged (84.9-87.8% vs 79.7-84.8%). Change not kept.
- Cause: RenderEngine slept ~6.3 ms inside each FillRRectOp, woken by mali-cmar-backend (osup_sync_object_wait). Only 2 FramebufferSurface buffers (default max_frame_buffer_acquired_buffers=2).
- Fix: vendor/build.prop ro.surface_flinger.max_frame_buffer_acquired_buffers=3. resetprop A/B, same boot, 2 arms each: 43-47% vs 78-84% janky. Written to vendor (0x413800, pre-read == vendor-dev, read-back == vendor-fb3).
- Settings list scroll: 4.4% janky, no action.
- Mistake found and fixed: scripts/patch-vendor.sh copies vendor-changes/lib/hw/hwcomposer.rk30board.so, which was still the stock HAL (b9fb3947). The vendor-fb3 write therefore put the stock HAL back (device read b9fb3947), which is why drawer/shade/recents measured 74-80% / 73-79% / 22-23% after that boot. vendor-changes now holds the current HAL (out-rot4, 4ae6ae00); vendor-fb3h written (pre-read == vendor-fb3, read-back == vendor-fb3h).

## Black / striped panel (reported by owner; seen since 2026-11-13)
- Evidence (boot of 22:0x): `[60.037] rk_iommu ff930300.iommu: Page fault at 0x0a176000 of type read`, status 0x18b. The IOMMU stayed in the fault state; on the owner's screen off/on (621 s onward) `Enable stall request timed out` / `Failed to attach iommu device` repeat, panel black. SurfaceFlinger screencap was correct the whole time.
- VOP state dumped by the fault handler: win3 carried 3 areas: status bar (y 0-42), task bar (y 1873-2048) and a 108x108 layer at y 1940 - the last two share scanlines. The fault address is 48 KiB past the end of win1's buffer (0x0956a000 + 12 MiB).
- Cause in hwc/src-a16/hwc_rockchip.cpp combine_layer(): the vertical-pairing loop added by the status-bar/task-bar combine fix (2026-11-12/13) only checked each candidate against the group's first layer. The overlap-to-fault link is [INFERENCE]; the overlapping areas themselves are in the dump.
- Fix: check the candidate against every layer already in the group, and against every group it is moved below in z-order. Built out-area (cf0ec139). The HWC skip-range experiment was reverted from the source.

## 2026-11-15 00:00-00:20: nonblocking commit done right, and video playback

- Implemented nonblocking atomic commit the correct way (crtc `OUT_FENCE_PTR`; the replaced
  composition is released only after that fence signals at the vblank that latches the new
  frame; kernel `vop_handle_vblank` sends the event there). Same-boot A/B against vendor HAL
  cf0ec139, two arms each: gallery launch janky 44.5/44.2% vs 45.1/44.7%, SF missed 226/279 vs
  280/261; recents 23.0/24.0 vs 23.7/22.4; drawer 75.6/74.4 vs 74.2/76.3; shade 61.8/62.0 vs
  55.3/58.6. No fence timeouts, no failed commits, no IOMMU faults. No gain: the RK async path
  (`rockchip_drm_atomic_commit`) calls `flush_work()` on the previous commit, so the next commit
  still waits for the vblank. The earlier gain with `persist.vendor.hwc.nonblock_commit=1` came
  from releasing the previous frame's buffers before it left the screen. Both the experiment
  property and the new code were removed from `hwc/src-a16` (build out-clean OK, 366468 B).
- Video playback (Glimpse -> OMX.rk.video_decoder.avc -> SurfaceView, 1080p30, DEVICE
  composition): after a clean boot the video layer shows 94-96% of frames for exactly 2 vsyncs,
  SF missed 8-25 per 10 s. After many composer/SF restarts in the same boot the same test gave
  71% / 196 missed, and SF/composer stopped emitting atrace marks: the restart state is a test
  artifact, so measurements taken after `ctl.restart surfaceflinger` are not representative.
