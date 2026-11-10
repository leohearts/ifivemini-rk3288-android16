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

### What the 11.13 ms `Drawing` pass really is (corrected four times - read the last table)

First read of this data blamed the wallpaper; parsing sf.txt's visible/invisible
flags properly disproves that: with the shade open, **only 4 layers are visible
on the display** - `ColorFade BLAST` (frame=18, a static remnant), `NotificationShade`,
`StatusBar`, `Taskbar` - while `ImageWallpaper`, the wallpaper BBQ wrapper, all
`ActivityRecordInputSink` layers and the `Dim layer` are invisible and never
reach the HWC at all. The launcher window is likewise absent from the visible
set (zero commits during drag clusters, measured above).

The `Drawing 0.0 0.0 558.0 2048.0` region that carried the 11.13 ms median:
in the same sf.txt dump, `[0 0 558, 2048]` is the *visible* rect of
`SettingsHomepageActivity` (the part not covered by the shade panel), so the
pass was SF re-compositing the whole visible stack on GLES - damage rect
sized by what actually changed - and the identification of any single
"culprit layer" is moot: the layer list itself shows the mechanism was
rejection, not force. (See the final correction below; intermediate drafts
of this section attributed it to the shade card and then to the wallpaper -
both were wrong, kept in git history for the correction chain.)

Third and final correction of this section, with the loop closed:

The all-CLIENT state in sf.txt is the **old HWC build's** doing, layer by
layer - every layer rejected in `validate()`. That is the same alpha-gate bug
fixed at 21:44 (`4b03399d6`): the full log line `vop cann't support first
layer with global alpha` appears 727 times across the afternoon's hwc
captures (`pull-hwclog.txt`), and the old HWC GLES-composited the whole
screen every frame - exactly the 9.2 ms-vs-4.9 ms pattern published by
another GSI project for the same mechanism.

FOURTH correction (2026-11-11 late, slice ownership by pid): every "Drawing
WxH" atrace slice belongs to the process that named the marker - HWUI's
RenderThread names its GPU drawing pass `Drawing x y w h`; SurfaceFlinger's
composition pass has no `Drawing` slice. Counting EVERY `Drawing` slice in
trace2 (no duration threshold) by owner and exact region:

| drawing process | window | region | n |
|---|---|---|---|
| 21010 SystemUI | NotificationShade | 1536x2048 | 461 |
| 21010 SystemUI | StatusBar | 1536x42 | 20 |
| 21365 Launcher | Taskbar strip | 1536x175 | 169 |
| 21365 Launcher | Taskbar strip | 1536x201 | 43 |
| 21365 Launcher | home surface | 1536x2048 | 39 (all outside the pull-down bursts) |
| 6915 Settings | exposed band | 558x2048 | 167 |
| 6915 Settings | exposed band | 978x2048 | 51 |

The earlier "11.13 ms median" mixed these populations: it is not one SF pass
and never was. All 167 of the 558-wide Settings frames fall inside one 2.8 s
burst (9471.8-9474.6 s of uptime) = a single pull-down animation.

The same audit on trace3.txt - the HOME scene, i.e. the user's exact
complaint (pull-down from the desktop) - is worse, not better. Counting
`Drawing` slices >3 ms by owner and shape (FULL = w>1000 and h>1000,
STRIP = w>1000 h<300, band = tall strips h>1000 w<1000):

| capture | SystemUI(21010) | Launcher(21365) | app behind |
|---|---|---|---|
| trace2 (Settings behind drawer) | FULL 461 | STRIP 212, FULL 39 (all outside bursts: the Settings launch) | Settings(6915): tall bands 218 (558/978 px wide) |
| trace3 (home behind drawer) | FULL 305 | STRIP 405, FULL 1 | - |

The contention is the taskbar strip: 405 draws at 10.6 ms median during the
home-scene session, 212 in the app-scene one - the taskbar animates (lifts /
fades) under the drawer on every frame of every pull-down, in the Launcher
process, on the same Mali queue as SystemUI's shade. And the app behind the
drawer (Settings in trace2) re-renders its exposed vertical band 218 times
at 8 ms. SystemUI's own shade draws run 12-15 ms in the same captures while
their standalone flush-commands time is ~3.4 ms: roughly 9-11 ms of each
frame is queue wait behind these other painters.

A fully-covering shade makes both occupants idle: it hides the home/app
window behind it, and it hides the taskbar. The "occluded windows stop
submitting" premise is measured on this device, not assumed: in trace2 the
Launcher's home surface is covered by Settings and its FULL-frame count
inside the pull-down bursts is exactly 1 for the whole session (the 39
full-screen draws are the Settings launch, outside the bursts) - covered =
idle. The taskbar stays busy there because Settings does not cover it; the
shade does.

The new build's validate behaviour was captured at 22:1x with
`vendor.hwc.log=2` over 307 composition windows: **zero GLES downgrades, zero
bandwidth rejections** (`HwcFix1110.md` Validation; the 445 number is plane
log lines, not per-frame plane counts). That removes the *rejection* cause of
whole-screen GLES. Whether an SF `Drawing` pass still appears on-device under
the fixed HWC (and with what duration) has no host-side capture - the trace
in hand predates the fix - so the honest status of the 11 ms item is
"mechanism identified and the identified cause fixed; on-device confirmation
of its removal still owed", via the atrace arms of
`scripts/shade-scene-atrace.sh`. The `no_rounded_corners`/shadow experiments
remain in the script as fallbacks: they only matter if the on-device trace
still shows a big `Drawing` with zero downgrades in the hwc log.

What the residual jank is then, under the fixed HWC - and what removes it:
the janky pull-down is GPU **contention** with the taskbar strip (and, when
an app is behind the drawer, that app's exposed band) - the per-pid counts
in the table above. Both occupants exist only because this build shows the
shade in **split-shade (left-drawer) form**:
`com.android.wm.shell.R.bool.config_use_split_notification_shade` resolves
true (its `(sw600dp)`/`(land)` variants), so the launcher taskbar stays
visible and animates under the drawer (405 draws x 10.6 ms in the home
scene, 212 in the app scene) and the sliding drawer leaves a band of the
app behind exposed (Settings: 218 tall-band draws x 8 ms in one session).
With the drawer form off, the shade is the classic full-screen top-down
panel: it fully occludes the app behind it (an
occluded window stops submitting - measured, see above) and covers the
taskbar likewise. The
decision is read live from resources in
`SplitShadeStateControllerImpl.shouldUseSplitNotificationShade()` (jadx
decompile of this exact SystemUI), and the fallback branch is an unreleased
aconfig flag (`lockscreen.enable.landscape`, default off) - so one static
RRO setting the bool to false flips the form deterministically.

Expected effect from the same measurements: the shade's own GPU pass alone
drains in 3.4 ms (`flush commands` medians) while its Drawing slices average
12.3-14.8 ms - ~9-11 ms per frame is queue wait behind the taskbar-strip (and
app-band) painters. Removing 4.3 s of overlapping GPU submissions from the
home-scene session (405 x 10.6 ms) leaves SystemUI's chain (8.7 ms main +
~4 ms GPU) inside the 16.6 ms period. That is the mechanism-level reason to
expect jank to collapse; the numbers are from before/after the same app
code, the only changed quantity is who else touches the GPU. Acceptance
protocol on device (`scripts/shade-splitshade-accept.sh`): `before` phase
(2x12 cycle + 6 s atrace) -> install `ifive-split-shade-off-module.zip` ->
reboot -> `after` phase; the `after` phase first asserts
`cmd overlay lookup com.android.systemui com.android.systemui:bool/config_use_split_notification_shade`
resolves false (if the base `(sw600dp)` variant still wins there, swap in
the per-variant module B from the same build). PASS requires the
non-SystemUI STRIP/band `Drawing` counts inside pull-down bursts to drop to
~0 (`scripts/shade-frame-audit.py --compare`), with jank% as the headline.

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

### Floor analysis (superseded 2026-11-11 - kept for the correction chain)

The earlier version of this section claimed a ~27 ms floor (8 ms CPU + 15-18
ms GPU) from prebuilt SystemUI and concluded only source-level changes could
help. Both halves are wrong: the 15-18 ms GPU figure measured the shade's
draws *while the Launcher's taskbar strip and the app band were drawing on
the same queue*, and the shade's own GPU time is 3.4 ms (flush-commands
medians, this same trace). Removing the other painters is possible without
touching SystemUI's code - the split-shade overlay above. The real floor is
therefore 8 ms main thread + ~4 ms GPU ≈ 12 ms < 16.6 ms, i.e. 60 fps is
arithmetically in reach for the pull-down once contention is gone; the
on-device acceptance measures whether it is.

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

## Session state at 2026-11-11 00:4x (for the next continuation)

Delivered: kernel (ramp-up tail fix, verified to dtb level), HWC (alpha gate,
max_scale 6.0, mix-order preference), final release zip sha256 `636a4a77...`,
module zip sha256 `43892f5e...`, draft release `v2026-11-10` with all assets
and this analysis referenced, branch through commit `d1eb11700`, capture script
`scripts/shade-scene-atrace.sh` covering everything below.

Open, in priority order - all need device minutes, all have their exact
commands inside the capture script:
1. **Run the split-shade acceptance** (`scripts/shade-splitshade-accept.sh`
   before -> install `ifive-split-shade-off-module.zip` -> reboot -> after,
   verdict via `scripts/shade-frame-audit.py --compare`): the contention
   finding (FOURTH correction above) says removing the non-SystemUI band
   redraws should collapse the >24 ms gap share; this is the one experiment
   that turns the causal chain into a measured before/after.
2. **Confirm the fix removed the SF pass on-device**: same atrace windows
   answer it as a side effect (expect no full-screen GLES composition and
   SystemUI's own draws back near their 3.4 ms standalone time).
3. If a big `Drawing` persists while the hwc log shows zero downgrades and
   bands are gone: only then re-armed as fallback - `no_rounded_corners 1`
   and aconfig `ignore_corner_radius_and_shadows` (both already arms of the
   scene-capture script).
4. Quantify after each: 2x12 cycle (same protocol as all published numbers) -
   target below 60% janky before any claim is made anywhere.
Offline avenues this pass: AOSP source-level SystemUI work is not possible
on this machine (26 G free on /home vs several hundred G required), so the
attack went through the shipped binary instead - jadx decompile of this exact
SystemUI located the resource-gated split-shade decision
(`SplitShadeStateControllerImpl.shouldUseSplitNotificationShade`, gating bool
`config_use_split_notification_shade`, `(sw600dp)/(land)` variants true),
which is flip-able by static RRO without any source tree. AOSP tree build and
SystemUI patching remains the only deeper route not taken, deliberately.
No device partition was ever written; the test tablet still runs the
22:03 module build and is owed the `7575aed5` module + new kernel.

## Reproduce the analysis (host only)

```
python3: parse tracing_mark_write B|21010|animation / flush commands gaps,
         sched_switch on/off CPU accounting for tid 21010,
         clk_set_rate: sclk_gpu state machine - see commands in this report's
         session; inputs /tmp/perf1/trace2.txt, sf.txt, sf2.txt
```
