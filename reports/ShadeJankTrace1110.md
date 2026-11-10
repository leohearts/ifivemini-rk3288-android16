# Shade jank: pipeline breakdown from the existing ftrace (2026-11-10 night)

Device writes: none. This is analysis of two traces already recorded on this
host during the 2026-11-10 afternoon pull-down sessions (`/tmp/perf1/trace2.txt`,
29.5 s of gesture capture, atrace categories gfx+binder+sched+freq+..., and
`pull-trace1.txt`, scheduler-only). The tablet was running the 2026-11-08 GSI
stack (before tonight's HWC module); SystemUI pid 21010, SurfaceFlinger 6915,
composer HAL 801.

## What the trace says, per frame

Frame period during the shade drag (measured as median gap between SystemUI
`animation` callbacks, `flush commands`, and SF `CommitFrame` - all agree):
**26.8-27.0 ms = 37 fps.** (p90 50-62 ms.) This matches the 82-89% janky-frame
figure measured the same afternoon, which counts anything slower than 16.7 ms
at 60 Hz as jank.

Main thread (tid 21010) time split over the 29.5 s, per frame:

| where the 27 ms goes | per frame |
|---|---|
| on-CPU (runnable and running; the real CPU cost) | **8.0 ms** |
| sleep S (interruptible - pipeline/vsync wait) | 16.8 ms |
| ready but waiting for a core (R) | 1.5 ms |
| blocked in kernel (D) | 0.1 ms |
| wakeups | all 1247 from its own Choreographer/vsync |

Correction of an earlier claim: this report and the release README said one
SystemUI thread spends "20-26 ms of CPU per shade frame". That number was
computed as thread CPU over an animation wall-time window, not divided by
completed frames. The trace-based value is **8 ms CPU + 18 ms waiting**. The
correction matters because it moves the bottleneck off the CPU and onto the
render pipeline.

Core placement: c3 48%, c2 27%, c1 15%, c0 9%. Across the whole 29.5 s the
system had 65 idle core-seconds out of 118 - the CPU is not the constrained
resource during the drag.

## What the 18 ms of waiting is

RenderThread (`flush commands` = display list submitted to the driver) starts
**median 18.0 ms, p90 40.5 ms** after the `animation` callback begins. The work
being waited on is GPU rasterization of the shade window:

- `dumpsys SurfaceFlinger` from the same session (sf.txt): the
  `NotificationShade` layer is a single full-screen buffer, bounds
  `{0,0,2048,1536}` = 3.1 M px. Everything in the shade (background, scrim,
  every notification row, icons, text) is drawn into it by HWUI each frame.
- Draw-op counts in the SystemUI trace sections over 493 animation frames:
  12998 FillRectOp, 3398 CircularRRectOp, 2692 AtlasTextOp, 1708 TextureOp,
  1152 CircleOp, 768 AAConvexPathOp, 286 FillRRectOp (about 28 ops/frame,
  several of them full-screen-area fills). Op count is modest; fill area is
  not.
- Wallpaper layers were `invisible (hidden by parent)` in the same dump: the
  opaque shade background replaces wallpaper draw, no wallpaper cost.

## GPU frequency: measured ceiling, not a tuning gap

`sclk_gpu` events over the trace window (27.1 s): 10.3 s at 198 MHz (mostly
screen-off/idle stretches), 16.7 s at 594 MHz. Every one of the 36 ramp-up
events was 198 -> 594. At the instant an `animation` callback fires, the GPU
is already at 594 MHz for 90% of frames (47/493 start below 400 MHz - the
first frame after wake-from-idle).

594 MHz is the ceiling for this board, and it is recorded in the device tree
source (`kernel/arch/arm/boot/dts/rk3288-ifive-mini4s.dts:869-903`):
`sclk_gpu` can only take CPLL (384 MHz) or GPLL (594 MHz); NPLL is in use as
`dclk_vop0` (display pixel clock) and usbphy480m is gated with the USB PHY, so
no higher OPP exists. The 2026-11-10 afternoon experiment that raised
`min_freq` to 594 MHz and changed the governor measured "no jank change" -
consistent with 90% of animation frames already running at 594 MHz; that
experiment only removes the ~10% first-frame-after-idle penalty.

## What follows from this

Per-frame floor with the current prebuilt SystemUI: 8 ms CPU + 15-18 ms of
GPU/bandwidth for one 3.1 M px shade surface = ~27 ms, about 37 fps. Reaching
16.7 ms (60 fps) would need the shade's per-frame work cut by roughly half,
which is only possible by changing what SystemUI draws (smaller shade surface,
less overdraw, cheaper rows) - the GSI's SystemUI.apk is a prebuilt we do not
build here, and no build.prop/Settings/flag switch on this image changes the
shade surface size.

Options considered and rejected with evidence:
- window-level/cross-window blur: `CROSS_WINDOW_BLUR_SUPPORTED` =
  `ro.surface_flinger.supports_background_blur` (default false), not set in the
  release vendor build.prop -> the blur code path never runs; nothing to save.
  (framework: `android.view.CrossWindowBlurListeners`, service:
  `com.android.server.wm.BlurController.updateBlurEnabled`.)
- the "1900 synchronous Settings calls" shade problem from custom-ROM fixer
  apps: the `query` annotations in the trace belong to `libui` gralloc calls
  (also present in SurfaceFlinger), not to `Settings` provider access -
  SystemUI's dex contains no matching callers.
- `NotificationStatsLoggerImpl.updateExpansionStates` / `maybeLog...`
  (present in this SystemUI): main-thread work is two ConcurrentHashMap
  lookups plus a coroutine dispatch on state change only; µs-level per frame,
  not the cost.
- Taskbar co-redraw (Taskbar layer 175 px tall = 8.6% of the screen,
  re-commits every frame during the drag): real, but small; disabling the
  taskbar is a user-visible trade (`Settings.Secure launcher_taskbar_enabled`)
  with an expected gain under 5%, so it is not defaulted anywhere in this
  release.
- wallpaper: not drawn under the opaque shade (invisible in the SF dump).

What was NOT changed: screen resolution, animation durations, frame rate,
touch settings. The jank percentages in the release README now point here for
the corrected attribution.

## Reproduce the analysis (host only)

```
python3: parse tracing_mark_write B|21010|animation / flush commands gaps,
         sched_switch on/off CPU accounting for tid 21010,
         clk_set_rate: sclk_gpu state machine - see commands in this report's
         session; inputs /tmp/perf1/trace2.txt, sf.txt, sf2.txt
```
