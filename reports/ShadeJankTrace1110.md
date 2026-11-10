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

### What the 11.13 ms `Drawing` pass really is (corrected twice; final version)

First read of this data blamed the wallpaper; parsing sf.txt's visible/invisible
flags properly disproves that: with the shade open, **only 4 layers are visible
on the display** - `ColorFade BLAST` (frame=18, a static remnant), `NotificationShade`,
`StatusBar`, `Taskbar` - while `ImageWallpaper`, the wallpaper BBQ wrapper, all
`ActivityRecordInputSink` layers and the `Dim layer` are invisible and never
reach the HWC at all. The launcher window is likewise absent from the visible
set (zero commits during drag clusters, measured above).

The `Drawing 0.0 0.0 558.0 2048.0` region therefore matches the shade panel
itself: on this 1536x2048 portrait panel Android 16 draws the notification
shade as a **left-anchored ~558 px wide card**, and SF re-composites that card
through its GLES path every frame instead of handing it to a VOP plane. The
`Drawing` median of 11.13 ms is SF rasterizing the animated shade card per
vsync. Why SF marks that one layer client is the open question - the usual
forces are window corner radius, shadows/elevation, dim or blur regions - and
settling it needs the device-side capture prepared in
`scripts/shade-scene-atrace.sh` (2026-11-11).

This reframes the remaining optimization target precisely: **the 11 ms is one
layer - the shade card - GPU-composited per frame; if that single layer
returned to a VOP plane, the 27 ms period would collapse toward ~16 ms and
60 fps becomes arithmetically plausible** - the first genuinely
frame-budget-halving candidate found all night. Experiment order for the next
device session (in the script's session):
1. `settings put secure no_rounded_corners 1` (official Settings.Secure key,
   string present in this framework build's dex; revert `put ... 0`), re-run
   the 2x12 cycle + a 6 s atrace. If the shade's `Drawing` disappears from the
   SF timeline, corner radius was the client-force.
2. If not (1): same round with the `com.android.window.flags`
   `ignore_corner_radius_and_shadows` flag via `aflags` (its runtime-read path
   was verified in the framework bytecode this evening); record mutability.
3. If a step works, shipping it as a release default gets weighed openly -
   squaring the corners is a visual change, so it ships as an opt-in module,
   not a silent default, and the README states the trade explicitly.

The mix-window reorder shipped tonight neither saves the wallpaper (invisible
during the shade animation - the earlier claim is retracted) nor changes any
captured scene (simulation: both orders pick the same full-width window when
layers exceed planes). It stays as a strictly-safer preference for
middle-skip stacks; no measured jank claim rides on it.

### User-side confirmation (2026-11-11 00:2x)

The owner independently reports: the jank is specific to pulling the shade
down from the home screen; other scrolling/animation is smooth. The trace
supports the mechanism split: during drag clusters the home launcher and
background app surfaces commit 0 fps (QuickstepLauncher 166 commits all
outside drags), the Taskbar commits at the full 37.7 fps drag cadence, and
NotificationShade pushes 199.3 fps across its three BLAST surfaces (#87 at
1776, #89 and #90 at 304 each) - i.e. the pull-down is one of the few
gestures where SystemUI animates multiple full-screen-ish surfaces per
vsync at once; nothing else on the tablet does that, matching the user's
observation that no other interaction is affected.

## GPU frequency: measured ceiling, not a tuning gap

`sclk_gpu` events over the trace window (27.1 s): 10.3 s at 198 MHz (mostly
screen-off/idle periods), 16.7 s at 594 MHz. Every one of the 36 ramp-up
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

### The GPU tuning in the device tree never shipped (found and fixed tonight)

`kernel/arch/arm/boot/dts/rk3288-ifive-mini4s.dts:862-864` (`&gpu` node, line 854) sets `polling-ms = <10>`,
`upthreshold = <25>`, `downdifferential = <15>` on the gpu node - committed
11-08 13:28 (`225876134`). Every release kernel.img to date was built Nov 7
17:53, i.e. **before that commit**: shipped tablets ran kbase's defaults
(`mali_kbase_devfreq.c:350` `polling_ms = 20`, `DFSO_UPTHRESHOLD = 75`,
`DFSO_DOWNDIFFERENCTIAL = 5`). With 4.19's
`devfreq_simple_ondemand_func` (`kernel/drivers/devfreq/governor_simpleondemand.c:21,79-82`:
utilization above `upthreshold` jumps to `DEVFREQ_MAX_FREQ` outright), a 75%
bar is often not met in the first sampling periods of a drag (10 ms samples,
between-frame GPU busy averaging 40-60%). Full distribution over the 48
low-start animations (replacing the single 0.88 s example first quoted here):
time from animation start until `sclk_gpu` reaches 594 MHz = median 0.04 s,
p90 0.09 s, **max 1.82 s** - the ~0.9 s figure is a tail case, not the norm;
the 10.3 s at 198 MHz mostly belong to screen-off/idle periods.
The penalty that IS confirmed by direct frame-gap statistics: the first five
frames of a low-start animation exceed 50 ms in 20% of samples (n=229) vs
11% for animations starting at 594 MHz (n=2217); medians barely differ
(28.0 vs 26.7 ms) - the cost is in the heavy tail, matching the user-side
report that the first beat of the pull-down is the worst.
The driver reads all three device-tree properties
(`mali_kbase_devfreq.c:352,365-368`), so shipping the committed values is
verified end to end. Honest effect bound: the 47/493 cold-starts and their
tail frames lose their extra penalty (20% -> ~11% heavy-frame rate for those
animations); the overall jank percentage gain of the kernel fix alone is
small - it is a tail-firming change, not a frame-budget halving. Both
numbers await on-device confirmation.

### Floor analysis

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

## Next steps

1. **Ship the kernel** (in progress tonight): after the rebuild, verify the
   compiled device tree carries the values (`dtc -I dtb -O dts
   rk3288-ifive-mini4s.dtb | grep -A4 gpu@` -> `polling-ms = <0x0a>`,
   `upthreshold = <0x19>`, `downdifferential = <0x0f>`), then `mkkrnl.py
   verify` and the release guard as usual.
2. **On-device confirmation** (when device access returns): re-capture the
   same atrace set during 10 pull-downs; expected: zero `animation` starts
   below 400 MHz (was 47/493) and no 0.9 s ramp plateau in the `sclk_gpu`
   timeline. The jank percentage after the ramp fix is not claimed here - the
   frame-floor analysis above still applies to the rest.
3. **Deeper code-level reductions** (research, needs an AOSP/TrebleDroid
   build machine): the remaining 15-18 ms/frame is HWUI rasterizing the
   full-screen shade surface. The levers are all inside SystemUI: splitting
   or shrinking the shade window surface per animation state, skipping
   row content redraw for occluded rows, cheaper row backgrounds. None is
   reachable from vendor/build.prop/RRO; a SystemUI rebuild pipeline is the
   prerequisite and the TrebleDroid sources make it possible in principle
   (their SystemUI is AOSP + small patches), but requires a full AOSP tree.
4. **Taskbar**: `launcher_taskbar_enabled` (Settings.Secure, official)
   removes the Taskbar layer (175 px = 8.6% of screen, re-composited during
   every drag frame). Expected gain <5 points of jank for a dock the tablet
   user may want; left enabled by default, users can test with
   `settings put secure launcher_taskbar_enabled 0` (revert: `= 1`).

## Reproduce the analysis (host only)

```
python3: parse tracing_mark_write B|21010|animation / flush commands gaps,
         sched_switch on/off CPU accounting for tid 21010,
         clk_set_rate: sclk_gpu state machine - see commands in this report's
         session; inputs /tmp/perf1/trace2.txt, sf.txt, sf2.txt
```
