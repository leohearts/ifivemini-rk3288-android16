# HWC composition fixes (2026-11-10 evening)

Goal from the user: fix the pull-down shade jank properly, not by lowering the
resolution. Investigate our own hwc/sf/gpu code first.

## What the old report said, and what is now known

`Issues1110.md` section 2 concluded "SystemUI main thread is simply too slow;
nothing in this repository can help". That conclusion was wrong in an important
part: measured again with a clean protocol, **every animated frame of the whole
screen was being GPU-composited by SurfaceFlinger, on top of SystemUI's own
work**. The reason is in our HWC, in two places, found one after another.

## Measurement protocol (the corrected one)

The first A/B rounds were invalid and were redone. Two traps, both recorded so
they don't bite again:

1. Restarting the composer HAL (`setprop ctl.restart vendor.hwcomposer-2-1`)
   restarts SurfaceFlinger too (`init: ctl.start bootanim from pid ...(surfaceflinger)`
   in dmesg). The boot animation then owns the display for 20-30 s; frames and
   layer tables measured during it are meaningless. Every measurement below
   waits for `init.svc.bootanim=stopped` first.
2. `dumpsys SurfaceFlinger` prints the HWC layer table four times; `grep -c
   DEVICE` on the whole section multiplies. Take the first table only.
3. `umount` of the bind-mounted .so under a running composer unmaps live code
   pages of that process (SEGV on the next cold page, e.g. in
   `VSyncWorker::Routine`, and the crash cascades SF -> zygote -> system_server).
   Load order must be: `ctl.stop` -> sleep -> umount -> bind -> `ctl.start`.
   Also: a `pkill -f abNN` issued over `adb shell` matches the adb shell process
   itself (its command line contains the pattern) and kills the session.
4. After a system_server crash, the framework relaunches but can take >2 min
   on this board (full PMS scan every boot). A 90 s "bootanim=stopped" wait in
   a measurement script is too short and reports phantom failures; poll
   `sys.boot_completed` + `ps system_server` instead.

Jank protocol: 12 scripted pull-down/close cycles,
`dumpsys gfxinfo com.android.systemui` reset before, read after.

## Facts collected before the fix (all on the release build, screen on)

- Hardware vsync is healthy: `ff930300.iommu, ff930300.vop` line in
  /proc/interrupts grows 124 per 2 s idle = 60 Hz; `VSyncState` has no
  `synthetic` flag with the panel on (`synthetic` earlier was the screen-off
  artifact). No "Failed to set vsync" in logs. VSyncWorker's drmWaitVBlank
  path is fine as-is.
- `vendor.hwc.compose_policy` is already `6` on this device (stock TinkerBoard
  vendor sets it), which enables overlay for the primary display. Interleaved
  runs with policy 1 vs 6 (73/64/79/77%) confirmed they are equivalent for
  this display; the policy is not the problem.
- During a pull-down, HWC `prepare()` received **one** layer (the GLES client
  target): SurfaceFlinger had already merged everything. The reason was
  visible with `vendor.hwc.log=2`: per frame, ~1 line of
  `MatchPlanes: vop cann't support first layer with global alpha`
  followed by `mix_policy failed, go to GPU GLES at line=3065`.
- GPU (Mali r18p0, devfreq in DT, OPP 198-594 MHz) and the 4.19 VOP driver are
  not broken: VOP big exposes 10 RGBA planes with GLOBAL_ALPHA
  (`rockchip_drm_vop.c:2250, 1961-1994`), ZPOS-orderable, standard atomic +
  vblank events.

## Fix 1 — the first-layer global-alpha gate in MatchPlanes

`hwc/src-a16/hwc_rockchip.cpp` (MatchPlanes): the bottom layer group was
rejected outright when `alpha != 0xFF` ("vop cann't support first layer with
global alpha"). The claim is false for this kernel: every VOP plane has a
GLOBAL_ALPHA property and blends against the same black background a GLES
client target would produce. `MatchPlane` already skips individual planes that
lack the property (the `b_alpha` check), so the whole-frame rejection is
redundant. It is now only rejected when no crtc-supported plane has
GLOBAL_ALPHA at all.

Effect measured: `prepare()` now receives the real layer list (2.5 layers/frame
average, up to 5) instead of just the client target, and the per-frame GLES
downgrade stopped. Jank unchanged at this step (84-87% either way), because the
next gate below then rejected the frames.

## Fix 2 — the static 3.3 bandwidth cap (vendor figure) for this panel

With Fix 1 in, failures moved to
`mix_policy: vop band with is too big, fail match (3,4), scale_factor=4.88`
(three hardcoded 3.3 checks around `vop_band_width()`: 1.0 if a mix merge is
in play, plus sum of per-layer display/source scale factors; the "try to merge
first" branch triggers above 4.5).

3.3 is a vendor figure tuned for 1080p boards. The pull-down scene on this
tablet (wallpaper scaled 1.067, launcher, shade, status strip, taskbar) sums
to ~3.9-4.9 with every plane already matched successfully (245 "all match"
group assignments in the same log window, 0 plane-capability rejections). The
JD9165 dual-DSI panel runs 1536x2048@60 with dclk 230 MHz.

Change: the limit is now `vop_band_limit()` - property
`vendor.hwc.vop.max_scale` (float, read once per composer start), default
`6.0` under `RK3288_MID`, unchanged `3.3` for anything else. The "try to
shrink via mix" trigger scales with it (`limit * 1.36`, same ratio as the old
4.5/3.3). With 6.0 the scene composes on planes directly.

## Validation

### Composition (the part that got fixed, for real)

With both HWC fixes bound and `vendor.hwc.log=2`, one scripted slow
pull-down (307 composition windows sampled):

```
frames=307  downgrades_to_GLES=0  bandwidth_rejections=0
overlay lines=445   dmesg vop/drm warnings: none
```

The same window before the fixes: every animated frame logged
`vop cann't support first layer with global alpha` +
`mix_policy failed, go to GPU GLES`. Screenshots mid-shade and settled
show identical pixels through the plane path; the teal wallpaper, quick
settings, both notification cards, the toast, status bar and taskbar all
compose correctly. The "missing wallpaper" scare in one earlier shot was
FallbackHome's blank home during the first ~20 s after a framework start,
not a plane bug (confirmed by a clean desktop screenshot at 9:23).

### Jank (what the fix does NOT change)

Protocol: 12 pull-down/close cycles, `gfxinfo com.android.systemui`.
Valid steady-state runs (bootanim excluded, framework settled):

|build|jank runs|% jank|frames|
|---|---|---|---|
|fixed HWC (bandwidth+alpha), log=0|82.5% / 66.5%|~75%|349 / 442|
|stock HWC|80.6% / 76.5%|~79%|376 / 391|
|fixed HWC, later sessions|85.8% / 87.6% / 80.7%|~85%|473 / 314 / 310|
|stock HWC, historical (Issues1110)|76-89%|~82%|-|

The composition fix moves work onto the VOP planes but does not move the
jank needle beyond run-to-run spread. Two further levers were tested and
are also flat:

- SF pipeline phase: giving the app a 33.2 ms budget instead of 16.6 ms
  (`debug.sf.{early,late}.app.duration`) — 80.9/78.3% vs 84.5/78.7%
  control: no effect.
- CPU headroom: `scaling_governor=performance` + low-power off. This
  board's cpufreq policy is already capped at 1.608 GHz on all four
  cores and measured 1.608 GHz during swipes before any change, so there
  is no clock to gain — jank 84.4/82.8% vs 80.7% baseline.

Reading together with the frame-attribution data from the morning
session (SystemUI main thread at 8.0 ms CPU per frame, then an 18 ms wait for
GPU rasterization of the full-screen shade surface - the per-frame breakdown
with the earlier 20-26 ms figure corrected is in `ShadeJankTrace1110.md`, four cores only
30-37% busy): SystemUI's per-frame UI traversal against the 16.7 ms
deadline is what remains. Composition, vsync, GPU clock and CPU clock
have each been measured and ruled out with the levers that exist on
stock-like GSI + this vendor stack.

## Stability incidents found while testing (vendor stack issues, pre-existing)

1. Unmounting a bind-mounted HAL .so while the old HAL process is still
   running SEGVs it on its next cold code page (tombstone_16:
   `hwcomposer.rk30board.so`, `VSyncWorker::Routine()+128`). This is a
   test-procedure trap, but the same page can be hit by anything that
   unmounts vendor overlays under a live HAL.
2. A composer restart with the shade open took down SF, then the
   framework, and re-starting the *stock* composer under the same state
   reproduced two more SF `DEAD_OBJECT` aborts (tombstone_21..23,
   `Failed HIDL return status not checked ... DEAD_OBJECT`) and the
   device finally rebooted. Not chased further here; the safe procedure
   is: stop service, umount, (bind), start, wait for
   `sys.boot_completed=1` and `bootanim=stopped` before measuring.
3. CPU governor/limits were restored to the board's normal state
   (interactive, 408000-1608000) at the end.

## Delivery to devices: two Magisk traps measured today

1. `magisk --install-module` does not place files in `/data/adb/modules/<id>`
   live; the first reboot moves them out of `.update-modules`, so check module
   state after one more reboot.
2. On this tablet, magisk 31.0 magic mount applies a module's `system/`
   directory (both pre-existing modules work) but **silently skips a module
   whose content is only under `vendor/`** - no "loading module files" line,
   no error, three reboots. Fixed in `scripts/make-hwc-module.sh`: the module
   keeps the .so at its root and binds it onto `/vendor/lib/hw/...` from
   `post-fs-data.sh` - the same boot stage the tracefs module uses, after
   /vendor is mounted and before any framework process exists, so the composer
   HAL maps the replaced file on its very first start. SELinux context of the
   module dir is `adb_data_file` either way (verified matching the working
   modules).

## Third change (23:52): mix-window preference reordered - and the wallpaper story retracted twice

What the evening's trace finally supports (`ShadeJankTrace1110.md` keeps the
full correction chain): SurfaceFlinger spends a median **11.13 ms per frame**
in a GLES `Drawing 0.0 0.0 558.0 2048.0` pass. Parsing sf.txt visible flags:
during the open-shade animation only four layers are visible (ColorFade remnant,
NotificationShade, StatusBar, Taskbar) - the wallpaper and launcher are not in
the frame at all. The 558x2048 region matches the **shade card itself** (this
A16 build draws the pull-down as a left-anchored ~558 px portrait panel), so
the 11 ms is SF compositing one animated client layer per vsync - not the
wallpaper, and not whole-screen plane exhaustion from eight visible layers.
Two earlier framings of this section are retracted as wrong.

The `mix_policy()` fallback-order change (try widening the mix range upwards
before `first = 0`) did ship in this build: it is a strictly-safer preference,
but per the simulation it changes no outcome in any captured scene, and since
the dragged layer set is 4 visible + fb target (well under 5 planes), even the
old order could not have been exhausting planes here. **No jank improvement
is claimed for this change** - it stays because it can only choose equal-or-
better windows. The real prize it exposed is the open question of *why SF
marks the shade card client* (corner radius? shadow? dim?), which is now the
planned next device experiment (`no_rounded_corners`, then the
`ignore_corner_radius_and_shadows` aconfig route - see the trace report's
final section).

New library: 370484 B, sha256 `7575aed5...` (size unchanged, decision order
only). Both channels rebuilt: vendor image -> super.img, and the
`ifive-hwc-composition` Magisk module (zip sha256 `43892f5e...`).

## Rollout

- [x] `vendor-changes/lib/hw/hwcomposer.rk30board.so` <- new build (370484 B, sha256 528bb260..., commit 9d5ccb169)
- [x] release README vendor-changes line + new sha
- [x] Issues1110.md section 2 rewritten (points here)
- [x] rebuild zip, guard, draft release assets swap (zip sha256 66279cfc...; super.img inside the final zip unpacked and checked: lib/hw/hwcomposer.rk30board.so = 370484 B / 528bb260...)
- [x] module installed on the test tablet and soaked (2026-11-10 22:10-22:30: 2x12 pull-down jank runs 83.90%/84.91%, 100-cycle swipe stress, 15 min screen-off idle; composer/surfaceflinger/system_server pids unchanged from boot, tombstones stayed at 32, dmesg clean; live .so verified 370484/528bb260 via post-fs-data bind)
- [ ] **pending device access**: the test tablet still runs the 22:03 module (sha256 `528bb260`); it needs the mix-window build (`7575aed5`, module zip `43892f5e`) and the 23:38 kernel (via flash.sh or the release's boot flow) - then the on-device confirmation list of `ShadeJankTrace1110.md` section "Next steps" items 1-2, plus fresh 2x12 jank cycles for the numbers this report so far deliberately leaves unclaimed.
