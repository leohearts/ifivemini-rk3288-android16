# RK3288 shade/taskbar jank — measurement history reconstructed from host artifacts

**Headline:** every jank number that exists on disk was captured **before ~2026-11-12 midday**; the tablet bricked at 12:5x (eMMC write-dead beyond 32 MiB, `docs/release-notes-2026-11-12.md:229-245`). Modules **12d–12j were all packaged after the brick (8h/5h before audit, `release/` mtimes) and were never measured on-device**. The only trustworthy on-disk raw metrics are: pilot 96.33%/96.76% (pre-strip-fix), fullacc 7.21%, fs_after 3.88%, plus composition-level logs (`l5.txt`, `sf5.txt`) and the Android-11 control table. Everything else is a *quoted* number in README/module.prop with no surviving raw artifact.

## 1. Measurement-round table

R = repo root `/run/media/leohearts/Data/agentwork/ifivemini-rk3288-android16`. Times: "±Nh" = host mtime relative to audit (~23:00 11-12); device wall-clock only where logged.

| # | Round | Date/time | .so variant | Scenario | Metric | Source | Trust |
|---|---|---|---|---|---|---|---|
| 1 | pilot A1 | ~23h ago (11-11 late night) | unlogged (stock/gate-era HAL; A16 GSI 11-11 + ?) | 12× shade drag (`fullaccept`-style pair) | gfxinfo SystemUI: **96.33% janky / 1025 frames** (+"slowUI thread") | `out/tmp/jankwork/pilot/A1/jank.txt:1` | number raw-on-disk → **trustworthy**; .so identity **unverifiable** (no md5 capture; `lookup_A1.txt:1`="false") |
| 2 | pilot B12 | same session | unlogged | same | **96.76% / 1044 frames** | `out/tmp/jankwork/pilot/B12/jank.txt:1` | ditto |
| 3 | l5 logcat | 11-11 20:15:48–52 (device clock) | vendor stock (HAL pid 767) | shade drag, per-frame HWC decisions | `scale_factor=5.000000 is so big` **≈107 rejections in ~4 s** (1/scene-frame); `line=1858 all match` precedes each → mix-policy → GLES | `out/tmp/jankwork/l5.txt:70-71,211-212,…,14938` | raw-on-disk → trustworthy (pre-fix evidence) |
| 4 | sf5 layer dump | 11-11 evening | same (pre-strip) | open-shade scene | **0 DEVICE / 5 CLIENT** layers: statusbar id 2000 (1536×42), taskbar id 2019 (1536×201 @ y=1847), 3× full-screen 1536×2048 | `out/tmp/jankwork/sf5.txt:1-5` | raw-on-disk → trustworthy |
| 5 | fullacc | ~19h ago (11-12 ~04:00) | strip-era build (jankwork `a602d2…` vs released `e8fbd341` not distinguishable from artifacts) | gfxinfo reset + **drag12** (12 flings, `fullaccept.sh:6`) | **round 12: 170 frames, 7.21% janky** | `out/tmp/jankwork/fullacc/jank.txt:1`, script `fullaccept.sh:4-14` | number raw-on-disk → trustworthy; .so hash **unlogged** (postboot.sh printed md5 to stdout only, `postboot.sh:5`) |
| 6 | fs_after gfxinfo | ~16h ago (11-12 morning) | unlogged (post-fix era; uptime 2.57 h boot) | one shade open (StatusBar 1 frame, NotificationShade 0) | **3.88% janky (4/103)**, legacy 6.80%; p50 11 ms p90 29 p95 32 p99 61; **Missed Vsync 1, Frame deadline missed 4, High input latency 74** | `out/tmp/jankwork/fs_after.txt:7-16,116-117` | raw-on-disk → trustworthy number; scenario/variant **inferred only** |
| 7 | t9–t12, fling.txt, trace1, pilot traces | 19–15h ago | as above | atrace gfx/sched during shade flings (fling tail shows composer@2.1 pid 801 + SystemUI `computePalette` per frame, `ndroid.systemui-1527`) | **no numeric metric saved** (gfxinfo lines went to stdout) | `out/tmp/jankwork/t9.txt:1-4`, `t12.txt`, `fling.txt:1,16` | captures real; metrics unrecoverable |
| 8 | reload_hal / so_big checks | ~19h ago | swapped mid-session (`kill` composer, bind) | shade open, logcat counts `so_big/allmatch/skipall` | **output not saved** | `out/tmp/jankwork/reload_hal.sh:17-19` | **unverifiable** |
| 9 | Android-11 control ("pre-fix behaviour class") | 11-12 (day) | stock A11 owner-built HAL `da9659f1` (`vop.max_scale=6.0`) | 4 shade flings, 12 notifications | SF missed **37 / 28 / 3**, SystemUI janky **18 / 5 / 7%** (bursts 1–3) | `docs/release-notes-2026-11-12.md:62-72` | documented table, raw captures not on host → trustworthy-as-quoted |
| 10 | GSI 11-10/11-11 era (quoted) | 11-10/11 | stock→gate-fixed `7575aed5` | pull-down interleaved | **pre-fix 76–89%**; after global-alpha+cap-6.0 fix: **82–88%, "jank did not improve"**; GLES shade-card pass **11.13 ms median/frame**; `wm size 1152×1536`: 76/79/80/82 vs 87/88/87 native; 307-frame pull-down: **0 downgrades, 445 overlay commits** | `out/release/ifive-mini4s-android16-gsi-2026-11-11/README.md:436`; dup at `…11-10/README.md:411` | quoted; underlying `reports/HwcFix1110.md`, `reports/ShadeJankTrace1110.md`, `reports/Issues1110.md` **do not exist in `reports/`** → numbers usable, breakdowns unverifiable |
| 11 | "74–86% (12 notifs) / ~20% (empty shade), GSI 11-12 build, no module" | quoted in 12g/12h | stock-in-11-12-GSI claim | single shade fling | 74–86% janky, GPU 198 MHz; empty ~20% | `release/ifive-hwc-composition-2026-11-12{g,h}.zip:README.md:26-30`; ~20% also `hwc/ab-test.sh:27-28` | **SUSPECT**: the 11-12 GSI **never booted** on the tablet (`release-notes-2026-11-12.md:73-75` "has NOT been measured on-device"; flash failed `:196-198`), and no raw capture exists. Likely restates 11-11-GSI-without-module runs; treat scenario label as wrong |
| 12 | boost A/B quote | in all 12d–12j | strip .so | identical gesture script at 198 vs 594 MHz | **76–87% @198 MHz vs 7–16% @594 MHz** | `release/…12d.zip:service.d/boot-complete.sh:4-6` (identical d→j) | quote-only; raw rounds not on disk (probably t11/t12/fling morning era) → **suspect-unverifiable**; note it matches the 6.9–7.2 post number |
| 13 | v2 module "full acceptance" | 11-12 (18h ago prop edit) | intermediate `7575aed5`/`a602d2` (sha256 in prop) | 2×12-drag | jank **6.9–7.2%** (was **84–96%**), release cadence median **16.8 ms (was 29–36)**, bg redraws 31–45→2 | `release/ifive-hwc-composition.zip:module.prop:6`; 16.8 ms also `jankwork/pfd.sh:10-11` ("measured … 16.8ms (2026-11-11)") | 7.2% corroborated by raw #5; "6.9" and cadence/redraw figures have **no raw artifact on host** (jank.txt retained only round 12) |
| 14 | 12d, 12e, 12f, 12g, 12h, 12j on-device rounds | — | each zip's own .so | — | **NONE EXIST** | zips mtimes 8h ago (d–h) / 5h ago (j), after the 12:5x brick | explicit: zero measurements per iteration |

### What each 12x iteration actually changed (from zip contents, not measurements)
- **12d** (`7298bf36…`, sha256 sidecar): bind .so + `gpubboostd`, **no** `vop.scale_*` setprop, daemon started **without supervisor**; .so 362.9 KB; **no README in zip**.
- **12e** (`5609877f…`) / **12f** (`abbfc8b3…`): add `setprop persist.vendor.hwc.vop.scale_trigger 6.5` + `scale_limit 5.5`; boot scripts of e≡f identical; .so 362.8 KB. Only the .so bytes can differ between e/f — **unverifiable on host** (binary zip members can't be string-searched here).
- **12g** (`b9d2e723…`): supervisor loop `while :; do gpubboostd; sleep 2; done`; first README (quotes "74–86%" round #11).
- **12h** (`4c348059…`): supervisor gains `rv=$?; [ "$rv" = 87 ] && break` (stop retrying when daemon gives up on `/dev/input`); README identical to g.
- **12j** (`a6fbbe5b…`, the released one, `release-notes-2026-11-12.md:11`): h's supervisor; README adds "GSI 2026-11-12+ already ship the fixed HWC … bind-mount just re-applies" + HAL reads gate props via `property_get` every evaluation (no caching → `setprop` retunes live). Its .so = **halstrip** md5 `6699bf1d15ca221f629fd99116c6bde2` (`hwc/test/README.md:10,37`).
- So the HAL functional lineage is: stock `b9fb39…` (halbase, = `vendor-changes/lib/hw/…`, unspliced `out/inputs/super.img`) → jankwork intermediate `a602d2…`/sha `7575aed5…` (base module + `vendor-patched`/`identity` stage images) → strip fix `e8fbd341…` md5 `6699bf…` (12j + GSI 11-12 vendor). `hwc/out/*.so` (`20f85d…`/`da9659f1…`) is a stale A11-style rebuild — **repo sources cannot regenerate any fixed HAL** (`lbam/scratch/ab-test-review.md` row 13).

## 2. Before / after

- **Best pre-fix evidence (same script, raw on disk):** 96.33% and 96.76% janky SystemUI (pilot, `jank.txt:1` each) with the whole shade scene GPU-composited (0/5 DEVICE layers, `sf5.txt`; every frame gate-rejected, `l5.txt`).
- **Post-fix raw:** **7.21%** (fullacc round 12) and **3.88%** (fs_after) → quoted rollup **6.9–7.2%** and boost isolation **7–16% @594 MHz vs 76–87% @198 MHz**.
- Cross-protocol pre ranges: 74–86% (suspect label), 76–89%/82–88% (11-10/11-11 README), 84–96% (module.prop). Android-11 control for the same gesture class: 5–18%.
- Net claim supportable from artifacts: **~96% → ~4–7% janky (SystemUI gfxinfo), ~13–25× reduction**, from strip-combine + bandwidth gate + GPU boost together; the boost alone is claimed to carry most of it (12/13 rows above) — but the gate/boost split is quote-only (row 12).
- Residual signal in the best raw run (fs_after.txt:14): **74/103 frames "High input latency"** despite 3.88% janky — input-latency issue not addressed by any module iteration.

## 3. Remaining gaps (never measured / unfixed)

1. **12d→12j: zero per-iteration measurements.** Device bricked before any of them were installed. No A/B round, no MISSED_DIFF anywhere on host (`MISSED_DIFF` exists only in harness sources/reviews, never in data).
2. **11-12 GSI (fix inside system image) never booted** → its built-in fix is unmeasured (`release-notes-2026-11-12.md:73-75`); the "no module" numbers in 12g/12h README misattribute to it.
3. **Boost-OFF isolation on strip .so:** phase P3 as coded is single-arm (no BASE@198, no repeat) — `ab-test-review.md` row 17; `pkill -f gpubboostd` races the 2 s supervisor restart so "boost OFF" may measure boost ON (row 22). No data.
4. **Strip .so on fresh GSI without module (P0 "default state"):** never run; harness doesn't even verify module absence (`ab-test-review.md` row 20).
5. **Taskbar-only scenario:** never measured on any build — every script is a shade-drag protocol; taskbar appears only as a layer in `sf5.txt:1`/`l5.txt` and the qualitative "~400 taskbar-strip draws / ~220 band draws" (`out/release/…11-11/README.md:413-414`). No post-fix re-count of those draws exists.
6. **Split-shade-off module + fixed HWC combined:** qualitative only ("zero in-burst full-screen launcher draws", `…11-11/README.md:423-429`); no jank% round; pilot A1/B12 (probably module A/B variants, `lookup_*.txt`="false") ran pre-strip at 96%.
7. **Post-fix atrace DEVICE/CLIENT check:** no post-strip layer-composition dump exists on disk (see §4).
8. **Whole `reports/*1110*` detail layer missing** (HwcFix1110, ShadeJankTrace1110, Issues1110) — cadence 16.8/29-36 ms, 11.13 ms GLES pass, 31-45→2 redraws, 84-96% cannot be re-derived.
9. **Non-root path:** no boost at all (`release-notes-2026-11-12.md:92`); `gpubboostd` has no source in repo and may not see adb-uinput taps (`ab-test-review.md` row 11).
10. **A/B harness itself unfixed:** silent push/bind failures, unverified same-binary risk after `kill -9 $(empty pid)` (rows 6-9), `/debug_ramdisk/su` unattested (row 14) — even when the device returns, a run of the current `hwc/ab-test.sh` cannot be trusted without review fixes 1–9. (The recreated `hwc/test/README.md:53` already contains one provenance error: the `Janky frames: 4 (3.88%)` line is in `fs_after.txt:8`, **not** `t6.txt` — t6 is pure atrace.)

## 4. DEVICE vs CLIENT composition counts (artifacts that exist)

- **Pre-fix, scene level** (`sf5.txt:1-5`, 11-11 evening): status bar layer id 2000 (display 0,0–1536,42) = **CLIENT**; task bar id 2019 (0,1847–1536,2048 / 1536×201) = **CLIENT**; wallpaper/shade/home 1536×2048 = **CLIENT** → **DEVICE 0 / CLIENT 5**.
- **Pre-fix, per-frame** (`l5.txt`, 11-11 20:15:48.369–52.363): 1 "all match"(line 1858) → "scale_factor=5.000000 is so big" → mix-policy per frame, **≈107 gate rejections in ~4 s** (≈26 fps of scene frames, every one forced to GLES). After the 3.3→6.0 gate fix the log signature "so big" must disappear (acceptance check `release/ifive-hwc-composition.zip:module.prop:6`).
- **Post-fix:** no SF layer dump or composition-type log saved anywhere on host. Only aggregate claim: 307-frame pull-down with **0 composition downgrades / 445 overlay commits** (`out/release/…2026-11-11/README.md:436`) — raw source report missing. The atrace files (t5–t12, trace1, fling, pilot traces) contain SF/composer spans only (`composer@2.1-se-801 … B|801|HWC1 prepare`, `fling.txt` tail) with no composition-type strings; `sf-decomp.py` extracts cadence/busy-names, not types.

**Bottom line for the "solved?" decision:** pre→post jank of ~96%→~4–7% is backed by raw on-disk gfxinfo, but *which* component of the fix (strip-combine vs bandwidth gate vs GPU boost) owns how much of it is quote-only; the released artifacts (GSI 11-12 + module 12j) have **never been measured as shipped**, taskbar-only and boost-isolation scenarios have zero data, and the A/B harness that was built to close exactly these gaps cannot run (device bricked) and would silently produce invalid results even if it could (`lbam/scratch/ab-test-review.md` rows 5–9, 17, 20).
## Touch driver side, checked and cleared (2026-11-12, 20:0x)

Read of `kernel/drivers/input/touchscreen/gslx680.c` + release DTS:
- Panel: GSLX680 on I2C4 @0x40, `clock-frequency = <400000>` already
  raised from the 100 kHz default (DTS comment: 44-byte frame read
  5 ms -> 2 ms), interrupt-driven (`touch-gpio`, `IRQF_TRIGGER_RISING`,
  request_irq line 1777), not polled.
- Path: hardirq disables line + `queue_work` (line 1484/1375-1390) ->
  worker reads one I2C frame and `input_report_*`/`input_sync`
  immediately (lines 891-933). No batching, no coalescing sleep.
- Therefore the 74/103 `High input latency` frames (event -> drawn
  frame start > 70 ms as defined by gfxinfo) are NOT explained by the
  touch driver's timing; they point to SystemUI-side processing
  (computePalette visible per frame in fling captures, full-window
  invalidation). T5 in `docs/jank-test-plan.md` measures this with
  `atrace input,gfx` before any further driver changes.

## Latency pre-analysis from existing atrace text (2026-11-12, 20:2x)

Source: full parses of out/tmp/jankwork/{t9,t10,t11,t12,fling}.txt and
pilot traces (job LatencyTraceParse; transcript
sessions/-tmp/2026-10-29T10-19-01-590Z_01a1872b.../LatencyTraceParse.md).
t12.txt is the only existing capture with the `input` tag enabled
(2.3 M entries; real finger on Settings, post-fix boot A).

Numbers (CLOCK_MONOTONIC, us):
- IRQ->InputReader first slice->dispatchMotionLocked: 0.78 ms
  (t12:5462->5470->5495) and 0.43 ms (:7168->7206). Driver+reader+
  dispatcher never exceed ~1 ms.
- GSLX680 touch IRQ cadence 18.2-18.3 ms -> ~55 Hz panel report
  (t12 wake pairs); fixed in vendor firmware pages, NOT a driver knob.
- eventTime->deliverInputEvent, SystemUI, post-fix shade drag (t10,
  19 samples, :14993-37739): median ~23 ms, max 48.9 ms.
- Same metric pre-fix (pilot A1/B12): median ~38 ms, outliers 77.6,
  83.1, 98.1, 107.5 ms.
- One full chain sample (t12): event->first frame queued to SF 25.8 ms,
  ->SF present 43.7 ms, ->scanout ~55-60 ms (2-3 vsyncs).
- t9 (uptime 294 s, boot I/O storm): 378 ms dispatcher backlog - boot
  transient, excluded from steady-state claims.

Interpretation (bounded): the 74/103 HIGH_INPUT_LATENCY labels in
fs_after.txt are consistent with normal 2-3-frame pipeline phase at
60 Hz vsync (AOSP flags input latency over roughly one frame; exact
cutoff [INFERENCE]), while jank stayed 4/103. No pipeline stage is
broken on the post-fix boot. Remaining unknowns need the t13 capture
(docs/jank-test-plan.md T5): no existing trace overlaps the counted
gfxinfo window (postboot.sh:9 traces 5 s, drags 20 s later).

Not doing: GSLX680 firmware frame-rate swap (would replace unverifiable
vendor panel firmware for an 18 ms gain already dwarfed by pipeline
phase; risk of ghost-touch/bricked digitiser).

## Lineage 23.2 A/B numbers, first valid round (2026-11-12 22:2x)

Same tablet, now running the 2026-11-09-lineage232 GSI (user flashed;
kernel partitions restored earlier). Protocol: burst4.sh x4 per set,
shade open/close via `input swipe` (the close swipe also swipe-DELETES
notification cards - shade settles at 2 system notifications; all rows
below share this exact scene, comparisons are apples-to-apples).

| state | HAL md5 | boost | J% per set (4 runs) | MISSED |
|---|---|---|---|---|
| clean boot, module dir disabled | b9fb3947 | daemon alive, userspace | 97.4/97.4/96.3/96.6; 100/90.9/92.1/90.2; 92.5/95.1/90.5/90.7 | 287/309/296 |
| STRIP bind + ctl.restart composer | 6699bf1d | daemon+userspace ON | 76.9/71.2/74.0/64.8; 69.2/70.6/63.6/67.9; 67.9/73.6/64.3/69.2; 74.5/63.0/66.0/66.7 | 293/171/267/265 |
| STRIP, pkill daemon + governor flipped | 6699bf1d | attempted OFF (race) | 67.9/66.7/67.9/70.4; 66.0/73.6/72.2/67.9 | 164/193 |
| BASE attempt (bind did NOT unmount, still STRIP) | 6699bf1d | ON | 0.0/75.0/55.6 (system services half-dead after pkill composer - DISCARDED) | 25/258 |

Confirmed facts:
- Fix IS working on lineage too: STRIP 63-77% vs BASE 90-100%, about
  25 points better, but nowhere near the 6.9-7.2% measured on the AOSP
  GSI in November-11 era. Scene content differs (2 vs 12-15 cards,
  opaque vs translucent shade) so the absolute levels are not
  comparable across builds; the paired BASE-vs-STRIP on the SAME
  scene is the valid number tonight.
- GPU boost shows NO measurable effect in these runs (with/without
  same 66-73%). Suspect: userspace governor left pinned by daemon, or
  Mali utilization path already saturated. Needs the T1 matrix (fixed
  ab-test.sh) not ad-hoc toggles.
- `umount` of the bound .so fails while composer holds it (Device or
  resource busy); `pkill` of composer takes SystemUI/services with it
  ("Can't find service: input" for ~2 min) - NEVER switch HAL arms
  with pkill; use module enable/disable + reboot, or umount -l then
  ctl.restart.
- `cmd notification post` fails silently WHEN CALLED FROM A ROOTED
  ADB SHELL (after `adb root`). Corrected at 22:5x: NMS logcat shows
  `NameNotFoundException: root` from Lineage
  NotificationManagerService.fixNotification (line 9023) - Lineage
  resolves the posting process NAME ("root" under rooted adbd,
  "com.android.shell" otherwise) and drops the record on lookup
  failure. NOT a reboot-state bug; the 19:19/20:0x successes and
  22:2x+ failures split exactly on whether `adb root` had been run.
  RULE: notifications and any cmd-notification work must run in
  plain (unrooted) adb shell; `adb root` only for mount/setprop work.
- inject12.sh + burst4.sh fixes made today on the lineage device:
  record counting via 'NotificationRecord(' with -e excludes (toybox
  grep BRE alternation broken), INJECTED=<total> semantics, scene
  verification notes.

## Bottleneck search on lineage (2026-11-12 22:3x, device powered off mid-run)

With STRIP HAL active (5/5 DEVICE confirmed by dumpsys SurfaceFlinger
Composition list: layers 2019 taskbar, 2040 shade, 2000 statusbar,
1 wallpaper, 0 root all flipped CLIENT->DEVICE vs BASE), jank plateaued
at 63-77% instead of the 7% level of the AOSP era. Elimination runs,
same 4-burst protocol, same scene (2 notifications):

| state                                   | J% range      | MISSED |
|---|---|---|
| GPU pinned 198 (userspace, no writer)   | 63-77         | 164-302 |
| GPU 'pinned' 594 (echo target_freq)     | 63-75         | 241-253 |  <- cur_freq during this run was NOT sampled; pinning may have silently stayed 198 (kbase re-runs its own clock logic). 'GPU clock is not the limiter' is therefore NOT established by this row - re-test with sampling (resume-jank-test.sh step 4) |
| CPU performance 1608 MHz + GPU 594      | 63-79         | 230-245 |
| vop IRQ during bursts                   | 674/12s = 56 Hz, vsync tempo healthy | - |

Conclusions from numbers, bounded:
- CPU frequency and vsync interrupting are NOT the limiter on lineage
  tonight. GPU frequency: NOT ESTABLISHED - the "pinned 594" arm never
  sampled cur_freq while running, and the later 240-sample run was done
  BEFORE pinning (all 240 @198 with the daemon broken). Whether 594 MHz
  is even reachable at runtime is now a primary open question
  (kbase devfreq + OPP table are correctly wired per offline review;
  clk parents documented GPLL-594-capable in the board dts comment).
- Remaining per-frame cost sits inside SystemUI rendering itself
  (1536x2048 shade redraws) or a path the toggles above did not touch.
- Prime suspect not yet applied: `ifive_splitshadeoff` RRO overlay
  (module dir present at /data/adb/modules/ifive_splitshadeoff/ with a
  `disable` marker AND no Magisk in the restored lineage boot, so its
  overlay apk never reached /product/overlay). In the AOSP-era 7%
  numbers the fixed HAL and splitshadeoff were both active; tonight
  only the HAL was. Next step when the tablet is back: extract
  IfiveSplitShadeOffOverlay.apk, read its target/package, bind it into
  /product/overlay, reboot, `cmd overlay enable <pkg>`, re-run the
  same 4-burst protocol.
- Device state at 22:3x: no USB enumeration, no wifi - powered off or
  battery empty after hours of max-clock tests (it was charging via
  USB per its own notification earlier). No action available from
  host; watcher loop resumes measurements when it returns.

## DMC kernel experiment: boot-fail, rolled back (2026-11-12 23:0x-23:1x)

Hypothesis from the trace breakdown (t21.txt, STRIP full-scene):
CPU/GPU/DDR wall - postAndWait up to 131 ms with frequencies pinned,
SF itself healthy (validate/commit/present p90 <= 2.4 ms), vsync from
HAL continuous at 60 Hz (onComposerHalVsync 895/15s), while SystemUI
emits only ~22.5 fps (Choreographer#doFrame intervals p50 18.3 ms but
44 gaps >50 ms). DDR had no devfreq at all: `&dmc status="disabled"`
since the first porting commit; stock A11 runs dmc enabled.

Change tested: kernel/arch/.../rk3288-ifive-mini4s.dts + 
release-build/resource-release-gsi.dts dmc -> okay, resource repacked
(9d1f678c...), written at tool LBA 0x6000 from uboot Loader, first
1 MiB readback cmp identical, then rd 3.

Result: device never reached adb (240 s), went back to Maskrom and
repeatedly dropped the session during rollback (same power-drop
pattern seen all night on large transfers) - rollback to e94a1b01
resource running with retries. [INFERENCE] dmc probe/init on this
panel's dram timing hangs the kernel before adb comes up - the stock
A11 dmc firmware differs from the GSI kernel's driver path, so the
"restores vendor behaviour" assumption did NOT hold.

Bandwidth hypothesis remains OPEN. Next kernel-side step when the
tablet is healthy again: keep dmc disabled, instead test DDR level
directly via the vendor path: boot once into Android-11 stock (the
sdcard or original partitions boot fine) and read ddr status there
(stock has dmc + rkcmdb), to learn what frequency DDR idles/boosts
at under UI load. If stock DDR also sits at the same fixed level,
the bandwidth wall is a hardware constant and residual jank must be
attacked by REDUCING DRAW WORK in lineage SystemUI (overdraw:
3782 FillRectOp / 940 AtlasTextOp per 15 s burst), not by clocks.

Artifacts: out/dmc-experiment/ (resource-dmc.img kept OUT of any
release, README documents the failed run; do not flash it again
without a plan for serial capture during boot).

## Fix-HAL reconstructed from source (2026-11-13 02:4x)

The lost fix source was recovered as a working reconstruction:
- Disassembly evidence (rev-hwc/ANALYSIS.md): fix vs stock .so differ in
  mix_policy gate + MatchPlanes tail; match_process +2282 B is clang
  inlining, not new logic.
- Patch applied to hwc/src-a16/hwc_rockchip.cpp (4 edits):
  hwc_get_float_property helper (property_get+atof, no caching);
  literal 4.5 -> persist.vendor.hwc.vop.scale_trigger (default 6.5);
  two literals 3.3 -> persist.vendor.hwc.vop.scale_limit (default 5.5);
  both merge-fail log strings -> fixed binary's new format
  "fail match after band merge (%d,%d),bAllMatch=%d scale_factor=%f limit=%f".
  MatchPlanes global-alpha rule already present in src-a16 (source was
  ahead of the stock binary on that point).
- Rebuilt: /run/media/leohearts/Data/agentwork/lbam/scratch/rev-hwc/
  build-src-2/hwcomposer.rk30board.so md5 127b1134bd139e1b599a6d19529ace55,
  370496 B. Behavior-string check vs shipped fix (6699bf1d): 7/7 strings
  match (both props, new merge-fail format, global-alpha msg, "is so
  big", old "too big,fail match (" absent in both, max_scale absent in
  both). Not byte-identical (line numbers/clang build-id) - that is fine;
  the point was to own the source again.
- Kernel side also rebuilt with the mali polling fix:
  out/kernel-gsi-release/kernel.img sha a51a0208... (mali_devfreq.c now
  reads polling-ms from DTB; dts value 10 ms finally applies). Resource
  unchanged needed: release DTB already carries gpu props (verified set
  equality with fresh kernel dtb).

On-device queue when tablet returns (in order):
1. flash kernel.img at 0xE000 + readback cmp + rd 3 (one command each,
   coordinates and retry flow proven tonight; v7 covers worst case).
2. hwc/pipeline-measure.sh "before" run on old behavior is NOT possible
   after flashing - so first measure NEW kernel: trans_stat counters
   increase + cur_freq reaches 594 during burst WITHOUT gpubboostd
   (kill it first) -> if yes, devfreq path fixed, drop the hack.
3. A/B the reconstructed .so (127b1134) vs shipped (6699bf1d) via
   hwc/ab-test.sh - expected equal behavior; any difference is a bug
   in my reconstruction worth finding.
4. T1-T6 from docs/jank-test-plan.md on whichever .so wins.

## CORRECTION: the "mali polling fix" was wrong-driver dead code (2026-11-13 04:4x)

Earlier tonight I added `of_property_read_u32(np, "polling-ms", ...)` to
`kernel/drivers/gpu/arm/mali400/mali/linux/mali_devfreq.c` and built a
kernel.img (a51a0208) claiming it fixed GPU devfreq never boosting. That
was WRONG and I am retracting it:
- This SoC's GPU is Mali-T764 (Midgard). The bound driver is kbase
  (mali_kbase_core_linux.c of_match has arm,malit7xx/arm,mali-midgard);
  mali400 matches only arm,mali400/mali-450/mali-470 and never binds the
  ffa30000.gpu node. So the edited code is dead on this hardware.
- kbase's OWN devfreq (backend/gpu/mali_kbase_devfreq.c:352) already reads
  polling-ms, and the board dts &gpu already sets polling-ms=<10>,
  upthreshold=<25>, downdifferential=<15> (rk3288-ifive-mini4s.dts ~857-864).
  Those have been live all along. 100 ms sampling was never the cause.
- The mali400 edit was reverted (git checkout; kernel/ tree clean). The
  a51a0208 kernel.img is release + dead edit and MUST NOT be flashed as a
  "fix". The GPU-stuck-at-198-under-load observation stands and is now an
  OPEN measurement, not a fixed thing.
The real unresolved question (needs the device, see queue): with kbase +
MALI_DEVFREQ=y + upthreshold=25 already in effect, why does cur_freq stay
198 MHz during drags, and why did an explicit `echo 594000000 > target_freq`
+ userspace governor also stay 198? Board dts comment says T764 594 MHz is
reachable only via GPLL and the stock 200/300/420/500 OPPs are NOT
reachable - so this may be a clock-parent/OPP-table problem, not a
governor-threshold one. Next: on the fixed kernel boot, read
/sys/class/devfreq/ffa30000.gpu/{trans_stat,load,available_frequencies} and
/sys/kernel/debug/clk/clk_summary (sclk_gpu/aclk_gpu parents) during a drag.

## Reconstruction equivalence: full string-set diff (2026-11-13 03:2x)

clean strings (printable>=8, LC_ALL=C sort) reconstructed vs shipped fix:
2372 vs 2373 lines. Differences: only 2 libc++ template symbols in the
shipped binary (`__tree...erase`, `vector...__emplace_back_slow_path`)
absent from the rebuild - compiler inlining/codegen artifacts, not
logic (same finding as ANALYSIS.md point 2). No behavior string appears
in one and not the other. Combined with the GUARD-passing chunktest
package (d3a55fb9...) and the FlashChunk3 resume/chunk transcript
(wl 0xe000/e400/e800 + RESUME: skipping + --fresh), all host-side work
is verified; the queue ahead is purely on-device once power returns.

## postAndWait distribution: GPU wait is NOT the 63% cause (2026-11-13 05:0x)

Parsed all 497 SystemUI(4335) postAndWait slices in t21.txt (STRIP full-scene,
15 s): p50 2.5 ms, p90 12.0 ms, p99 47.8 ms, max 172.9 ms; only 18/497 (3.6%)
exceed one 16.6 ms frame, only 5/497 exceed 40 ms.
Correction of an earlier claim: I cited "postAndWait up to 131 ms" as if it
were the mechanism; the distribution shows that is an extreme tail, not the
norm. So neither GPU core clock (already shown insensitive when pinned) nor
GPU submit-wait explains 63% janky. T8 (triple buffering) priority LOWERED -
worth one cheap toggle+measure, not a main bet.
Remaining main suspect, needs per-frame data not aggregate: CPU-side frame
pacing / VSync phase (doFrame interval p50 18.3 ms during animation but 44
gaps >50 ms, 17 >100 ms between/around gestures). The decisive tool is
gfxinfo `framestats` (per-frame AppDrawTime/IoWait/Workload timelines) on a
live burst - queued in resume-jank-test.sh step 4 + T8 toggle.

## Offline verification of the GPU clock path (2026-11-13, no device)
- kbase devfreq IS compiled (out/.../midgard/backend/gpu/{mali_kbase_devfreq,mali_kbase_pm_metrics}.o) and its busy accounting is called from the job driver (mali_kbase_jm_rb.c:639, jm_hw.c:1258) - utilization is NOT structurally zero (unlike the Mali400 assumption).
- OPP table is correct: 198/297/384/594 all reachable via CPLL(384)/GPLL(594) per board dts; 594@1.25V under vdd_gpu 1.5V ceiling. So a boost request CAN be satisfied by the clock tree - the "OPP unreachable" fear from the dts comment applies only to the deleted 200/300/420/500 entries.
- Allocator `android.hardware.graphics.allocator@4.0-impl-midgard.so` (the real bound allocator) has full AFBC negotiation strings, so T7 is not blocked on allocator support - only on runtime usage-bit negotiation.

## RECON gate equivalence: property-literal check (2026-11-13 05:0x)
Scanned raw bytes of the four HAL variants for the gate float constants and
the two property strings (6.5/5.5 are vmov.f32-immediates so never appear as
pool bytes; 3.3 does):
| variant | 3.3f literal | scale_trigger str | scale_limit str |
|---|---|---|---|
| STOCK (b9fb39/rebuild 20f85d) | 1 | 0 | 0 |
| FIXED  (6699bf1d)             | 0 | 1 | 1 |
| RECON  (127b1134)             | 0 | 1 | 1 |
| AFBC   (553b2751)             | 0 | 1 | 1 |
So the stock->fix gate change (delete the hardcoded 3.3 accept-literal, read
persist.vendor.hwc.vop.scale_trigger/scale_limit live) is exactly reproduced
in RECON: RECON's 3.3f count (0) and both property-string counts (1 each)
match FIXED and are the opposite of STOCK. Strongest equivalence available
short of running it. Remaining differences (match_process 1976 vs 2260 size)
are clang inlining of the local MatchPlane, not different decisions. Final
proof is on-device RECON-vs-FIXED A/B (queued todo).

## match_process delta anatomy (2026-11-13 05:2x) - the one thing RECON might miss
Disassembly of match_process itself (FIXED @0x49c3d size 2260, STOCK @0x49c61
size 1976): property_get calls inside = 0 and 0 (so not a property-reading
change); self-name bl = 2 and 2; total bl 37 vs 33; DrmCompositionPlane
emplace_back_slow_path calls 4 vs 3 (+1 in FIXED). So the +284 B reduces to
"one more composition-plane vector push + a few small calls" - consistent
BOTH with MatchPlane-inlining and with the strip-combine building one extra
merged-plane candidate. If on-device RECON(127b1134) vs FIXED(6699bf1d) A/B
shows a behavior difference, this extra plane-push site is the first thing to
chase (re-diff match_process with the PLT map from rev-hwc/plt2_fix.json to
name those 4 unresolved bl targets).

## What SystemUI threads wait on inside the >60ms frame gaps (2026-11-13 05:3x)

Parsed t21.txt gap windows with corrected atrace line regexes (earlier
"0 events" readings were parser bugs, now re-verified: the 1153ms window
contains 3973 sched_switch lines - the system is BUSY, not idle).
sched_blocked_reason stacks for tgid 4335 in that one window:
  26 worker_thread        (workqueue waits, function-level only)
  18 rk3x_i2c_xfer        (an i2c read on a SystemUI thread - which device unknown)
   5 kbase_pm_wait_for_reset (GPU power-on reset wait in kbase)
   5 rockchip_drm_atomic_helper_wait_for_vblanks
   6 mmc_wait_for_req_done / mmc_go_idle  (eMMC re-init sequence DURING the UI gap)
Wakes issued: composer@2.1-se 46x, RenderThread 20x, mali-hist-dump 26x.

Evidence strength: counts are small (5-26 samples in 1.15 s) - these are
CANDIDATE mechanisms, not proven causes. But together they fit one story:
kbase cycles GPU power during animation pauses, and every resume pays
pm_wait_for_reset; that would explain WHY pinning clocks did not change
jank (clock is not the wait; power transitions are). Also mmc_go_idle
mid-session is abnormal (card re-init traffic) and deserves its own look.

AGGREGATED over all 31 gap windows (30 had samples; ~800 blocked events):
  423 worker_thread   138 rk3x_i2c_xfer   86 rcu_gp_kthread
  42 mmc_wait_for_req_done   36 wait_for_vblanks   34 do_page_fault
  23 kbase_pm_wait_for_reset  11 mmc_go_idle   14 vm_munmap  7 vm_mmap_pgoff
CORRECTION: the single-window read above overweighted GPU power-reset; across
all windows it is only 23/800. Honest aggregate: NO single dominant blocker -
the jank gaps are filled with scattered kernel work (workqueue + i2c + RCU
grace periods + mmc I/O + page faults + mmap churn). Points at CPU-side
scheduling + I/O + memory pressure thrash on a weak 4-core A17, NOT
composition (cleared) and NOT one GPU power transition (too rare).
Next measurement must be profiler-grade, not more atrace grepping. Device
has /system/bin/simpleperf (verified in system.img inode 603; NO `perf`):
  adb shell "simpleperf record -a --duration 12 -f 1000 -o /data/local/tmp/p.out &"
  # start burst5 while recording, then:
  adb shell "cat /proc/minor_faults; cat /proc/vmstat | grep -E 'pgmajfault|pswpin'"
  adb pull /data/local/tmp/p.out; simpleperf report -i p.out --sort comm,dso,symbol
Goal: real hot stacks during the gaps + minor/major fault rate to test the
page-fault/mmap-churn component of the aggregate.

Device-side experiments when powered (additions to queue):
1. GPU power transitions: count resets before/during/after burst5 via
   /sys/kernel/debug/mali0/ (gpu_memory_used, gpu_utilisation, policy) -
   if kbase sleep/wake cycles correlate with >60ms doFrame gaps, the fix
   is extending kbase's power-off delay (config/dts knob in
   mali_kbase_config_rk.c), a real GPU-pipeline change.
2. Identify the i2c waiter: trace rk3x_i2c with function tracer during
   burst (which adapter/address).
3. mmc_go_idle during UI: capture /sys/kernel/debug/mmc0/clk + block
   stats around a burst; if runtime PM is gating the host, disable it
   for mmc0 in dts.

## Boot-loop root cause, second half (2026-11-13 05:4x): wrong kernel written
Hash comparison of the two release packages' images:
  lineage232 kernel  e1226114...   | AOSP-11-12 kernel 52e91ab2...  (DIFFER)
  ramdisk both 59b84a0a / resource both e94a1b01                    (same)
At 2026-11-12 18:56 I "restored five partitions" from the AOSP-11-12 package
while the device's super was the LINEAGE install (user flashed lineage232
that evening). resource+ramdisk were identical files (harmless), but
kernel 52e91ab2 is NOT the lineage boot kernel e1226114 -> wrong init/VENDOR
boot config for the lineage system -> boot loop after rd 3, on top of the
later dmc resource experiment. My 18:56 "restore" was itself a partial
mismatch I did not check against what was actually installed.
recovery-v7 upgraded to content-hash checks (res_ok vs e94a1b01, krn_ok vs
lineage e1226114 from out/lineage-rescue/kernel.img - extracted 2026-11-13
from the lineage zip) and writes the LINEAGE kernel. Magic-byte checks alone
were blind to both mistakes (both kernels start KRNL, both resources RSCE).
What the device needs when a session window opens: 0x6000<-e94a1b01 resource
(the only mismatch). The kernel claim above ("wrong kernel written 18:56") is
superseded by the 2026-11-13 06:0x timeline correction: the user's ~22:0x
lineage flash overwrote kernel+resource before the dmc experiment, so the
current loop has the single cause = dmc resource; evening A/B data stands. v7 does exactly
that automatically; jank-chain waits downstream.

## Protocol confounder found + toolbox completed (2026-11-13 06:0x)
Cross-era gap (lineage STRIP ~73% vs AOSP-era 6.9-7.2%) was NOT
protocol-matched: AOSP numbers used SWIPE-open drags (fullaccept.sh
`input swipe 768 10 768 800 1400`, physics/velocity animation), while
2026-11-12's lineage runs used `cmd statusbar expand-notifications`
(programmatic animation path). Same-protocol BASE-vs-STRIP comparisons
stand; cross-build absolute numbers did not. Fixes now automated:
- hwc/test/burst6.sh: fullaccept-identical SWIPE open + SAFE close
  (cmd statusbar collapse, no card deletion) + per-round inject + N>=12
  assert. ab-test.sh gained a protocol-bridge pass (A3c/A1c burst6) -
  yields gesture contribution per arm AND the AOSP-era comparability
  check in one run.
- resume-jank-test.sh step 0d re-arms the splitshadeoff RRO (bind +
  framework restart + `cmd overlay list` verification), or logs an
  explicit non-comparability warning. It never silently changes scenes.
- hwc/analyze-run.py <run-dir>: one table per run (J%, N stability,
  top cur_freq histogram, MISSED, diag GLES/fail-match counts) plus the
  pre-registered rule verdicts (A1<=A3-30; GPU-never-above-300MHz while
  busy -> kbase/clock path; GPU-held-high-but-janky -> content/composition).
  Self-tested against synthetic arms before shipping.
