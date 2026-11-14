# Jank acceptance plan - RK3288 shade/taskbar fix (final matrix)

Owner decision record for the "rendering frame drops" task. Run everything
on-device via `hwc/ab-test.sh` (fixed version) plus the extra arms below.
Prerequisite: tablet boots (recovery-v7 repairs system partitions and
resets automatically; the battery/charger must sustain boot current).

No step touches /data. All toggles are: bind-mount (reverts on reboot),
setprop (volatile), stop/start daemon, install/uninstall module.

## Definitions
- STRIP = fixed HAL (md5 6699bf1d, already inside the 11-12 GSI vendor).
- BASE  = unmodified vendor HAL (md5 b9fb3947, `hwc/test/halbase.so`).
- BOOST = gpubboostd running (userspace governor, 594 MHz on touch).
- GATE  = HAL scale check driven by persist.vendor.hwc.vop.scale_trigger
  /scale_limit; HAL reads them live (property_get per evaluation, no
  cache), so toggling needs no restart. trigger=100 disables strip
  acceptance (forces the old GPU fallback on every frame).

## T1 attribution 2x2 (shade drag, 12 flings x 4 rounds alternating order)
| arm | HAL | BOOST | proves |
|---|---|---|---|
| A1 | STRIP (in-system) | ON | shipped experience |
| A2 | STRIP | OFF | strip-only |
| A3 | BASE (bind) | OFF | full baseline (expect ~76-96% family) |
| A4 | BASE | ON | boost-only |
Pass: A1 jank% <= 10 (per-round and mean) AND A1 <= A3 - 30 pts.
Report the 4 cells + contribution split (strip share = (A3-A4)/(A3-A1), boost share = (A3-A2)/(A3-A1), report >100%/negative honestly as interaction).

## T2 gate contribution (STRIP, BOOST ON)
B1: trigger=6.5  limit=5.5 (shipped default). B2: trigger=100 (gate
rejects all). 2 rounds each. Isolates plane-acceptance policy from the
strip-combine code path inside the same binary.

## T3 composition re-check (fills the missing post-fix dump)
Open shade, then `dumpsys SurfaceFlinger | grep -aE "id=2000|id=2019|composition"`
plus `--latency` window; compare vs pre-fix sf5.txt (0 DEVICE/5 CLIENT).
Pass: status bar id=2000 and task bar id=2019 show DEVICE in the opened
shade scene; `scale_factor.*so big` log count < 2 per 4 s (was ~107).

## T4 taskbar-only (never measured)
Shade closed; 12 long-press recents / app-switch gestures. gfxinfo for
launcher + SF missed frames. Report per-arm A1/A3 like T1.

## T5 input latency follow-up (74/103 "High input latency" @3.88%)
PRE-ANALYSIS DONE from existing traces (see docs/jank-audit-2026-11-12.md
"Latency pre-analysis"): driver->dispatch = 0.43-0.78 ms; SystemUI
eventTime->deliverInputEvent median 23 ms post-fix (38 ms pre-fix).
High-input-latency count is mostly 2-3-vsync pipeline phase, NOT a
broken stage. GSLX680 reports at ~55 Hz (18.2 ms IRQ cadence) which is
baked into vendor firmware pages - firmware will NOT be swapped
(unverifiable panel firmware change; the 18 ms is accepted cost).
Capture that actually overlaps the measured window:
```
adb shell "atrace -t 20 -b 32000 input gfx view sched freq idle power binder am wm > /data/local/tmp/t13.txt" &
sleep 2
adb shell "dumpsys gfxinfo com.android.systemui reset"
# 12 flings on shade + 1 shade open, REAL FINGER or getevent replay, not shell input
adb shell "dumpsys gfxinfo com.android.systemui > /data/local/tmp/fs_t13.txt"
adb pull /data/local/tmp/t13.txt out/tmp/jankwork/t13.txt
```
Pass: event->first-frame median <= 40 ms AND no single stage > 15 ms.

## T6 SystemUI main-thread cost (4/103 "Slow UI thread" + per-frame computePalette seen in traces)
With A1 STRIP+BOOST during flings: `atrace -t 20 -b 32000 gfx view sched` and
count `computePalette` occurrences per frame for pid com.android.systemui
(`grep -c computePalette` in the pulled trace). If it is >0 per scene frame,
test the Monet/wallpaper-tint toggle (`cmd overlay list | grep -i monet`,
disable SystemUI tint overlays) and re-measure gfxinfo for both states.
Report whether the residual 4 janky + p99 61 ms is owned by palette work.

## T7 AFBC buffer-compression pipeline arm (bandwidth lever, after T1-T6)
Evidence both ends exist but are OFF: HAL compiled -DUSE_AFBC_LAYER=0
(hwc/build.sh:71) though it carries AFBC code paths (internal_format read
via gralloc4 at drmdisplaycompositor.cpp:542/933, `DrmPlane::get_afbc`);
kernel rockchip_drm_vop.c has the afbc plane property with a hard cap
"vop only support one afbc layer" (:3335); board dts has no afbc flags.
Prereq check on-device first (unknown offline): does the vendor A11 gralloc
blob ever allocate AFBC modifiers?
  adb shell "dumpsys SurfaceFlinger --list | head; grep -a . /proc/mali/num_samples 2>/dev/null"
  strings /vendor/lib/hw/gralloc.rk3288.so | grep -ai afbc   # alloc-side support
If yes: use the PREBUILT variant hwc/test/halafbc.so (md5 553b27510629649761be2c863f17f578,
372576 B - strip-combine edits + -DUSE_AFBC_LAYER=1, compiled 2026-11-13,
built from the same patched src-a16 tree), push via
bind (same arm-switch as ab-test.sh), pick the wallpaper layer (full-screen,
static-ish) for the one AFBC plane slot, re-run burst5 protocol. Pass:
postAndWait p99 < 30 ms and J% drop >= 5 pts vs A1 same-day. Failure mode to
watch: vop rejects 2nd AFBC layer -> log flood; if seen, restrict to primary.
This is bandwidth/pipeline work only - no draw reduction.

## T8 deeper display buffer pipeline (triple buffering)
SF built with NUM_FRAMEBUFFER_SURFACE_BUFFERS=2 (seen in atrace build-config
header). At 2 buffers the RenderThread serializes one frame behind present;
any present jitter propagates into app-side waits (postAndWait). Volatile
toggle, clears on reboot, changes nothing about what is drawn:
  adb shell service call SurfaceFlinger 1008 i32 1
  # re-run burst5 sets A1 protocol, then:
  adb shell service call SurfaceFlinger 1008 i32 0
Pass: J% median drops >= 5 pts and/or postAndWait p99 improves. Record both.

## Protocol
Every run: `burst5.sh` prints N=, MISSED_DIFF and J= (burst4.sh kept only for
cross-checking pre-2026-11-13 numbers); gfxinfo reset between
arms; 30 s idle cool-down between arms (GPU thermal honesty); record
cur_freq trace during each fling burst (boost actually active?).
Results append to `docs/jank-results.md` (table per arm, one line per
round, raw captures under out/tmp/jankwork/<runid>/, .so md5 logged in
every row - the gap that invalidated the 12d-12j history).

## T9 evaluated and REJECTED (2026-11-13 06:0x): USE_SQUASH=1 variant
Idea: squash RGA merges layers to free a plane (4-plane VOP fully booked
by the open-shade scene). Checked the code before betting on it:
USE_SQUASH appears in exactly 3 files (drmdisplaycomposition.cpp:613,723;
platform.cpp:92), Android.mk ships it =0, no complete squash worker found.
Half-finished vendor experiment - enabling it is a gamble, not a plan.
REPLACED BY EVIDENCE: diag_burst counts "go to GPU GLES" lines per arm
during a burst. If plane exhaustion during animation is real, that count
spikes; only then does plane-pressure work (better merge/eviction policy
in match_process/mix_policy) become the next HAL iteration.
