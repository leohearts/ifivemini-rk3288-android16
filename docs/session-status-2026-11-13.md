# Session status — render-jank task, 2026-11-13 ~05:50

Single task: fix the notification-shade/taskbar render jank on iFive mini
4S (ML5RRJ6M5C) via HWC/GPU pipeline optimization. This file is the
handoff snapshot: what's true, what's broken, what's ready.

## Device state right now
- Running lineage 23.2 (package `ifive-mini4s-android16-gsi-2026-11-09-lineage232`, user-flashed 2026-11-12 ~22:0x). /data intact, never touched by me.
- Currently boot-looping. Single cause: resource@0x6000 = my dmc experiment image (9d1f678c, flashed 23:05) which hangs this board's boot.
- CORRECTION to the 05:4x note in docs/jank-audit (which claimed a second cause, my 18:56 AOSP-kernel write): timeline check shows the user flashed lineage AFTER that write, overwriting kernel+resource with the lineage set - the wrong kernel was already gone when the loop started, and all of 2026-11-12 evening's A/B numbers ran on the correct lineage kernel. The dmc resource is the whole story.
- Maskrom enumerates (USB 2207:320a) but the BootROM refuses download sessions (battery deeply discharged; ~30 failed attempts 23:13->05:47, most instant-reject).
- Recovery automation: out/recovery-v7.sh (service, 15 s retry loop). On a session it: content-hash checks p1@0x2000, resource@0x6000 (vs e94a1b01), kernel@0xE000 (vs out/lineage-rescue/kernel.img e1226114), ramdisk@0x16000, misc@0x4000; rewrites only mismatches; resets when all five verify. Idempotent across dropped sessions.
- Test automation: out/resume-jank-test.sh under service `jank-chain` (loops forever): waits for booted adb, pushes assets, then runs GPU frequency/clk measurement (NO flashing) -> hwc/pipeline-measure.sh (incl. T8 triple-buffer toggle) -> hwc/ab-test.sh full matrix.

## What is already proven (real numbers, on-device)
- The shipped fix HAL (halstrip, 6699bf1d) works at the composition level on lineage: dumpsys SurfaceFlinger shows all 4 scene layers (statusbar 2000, taskbar 2019, shade 2040, wallpaper 1) flip CLIENT->DEVICE.
- Same-scene A/B (fixed protocol burst5, N=14 notifications constant): BASE ~92% janky vs STRIP ~73% janky. The fix helps ~19 pts but does not reach the 6.9-7.2% level measured on the AOSP GSI.
- Ruled out for the residual: SF composition time (p90 <= 2.4 ms), vsync IRQ tempo (56 Hz), GPU submit-wait (postAndWait p50 2.5 ms; only 18/497 over one frame), CPU+GPU pinned-max clocks (no change - but note: that experiment never sampled actual cur_freq while pinned; being re-tested properly).
- Kernel devfreq config audit: bound driver is kbase/Midgard; dts polling-ms=10/upthreshold=25/downdifferential=15 ARE live (my earlier "dead config" claim was about mali400, which never binds - retracted, edit reverted). OPP 198/297/384/594 all reachable via CPLL/GPLL.
- Gap-window analysis (31 windows in t21.txt): blocked reasons are spread (workqueue 423, i2c 138, RCU 86, mmc 42, vblank 36, page-fault 34, kbase_pm_wait_for_reset 23) - no single lock; points to CPU scheduling/IO/memory churn, to be confirmed with simpleperf on device.

## Assets ready (host)
- hwc/test/: halbase.so b9fb3947 (stock), halstrip.so 6699bf1d (shipped fix), halrecon.so 127b1134 (my rebuild from patched src-a16 - gate equivalence proven by string-set + property-literal + vcmp.s18,s20 checks; runtime equivalence = RECON arm in ab-test.sh), halafbc.so 553b2751 (T7 experiment: same source + USE_AFBC_LAYER=1; vendor allocator has AFBC negotiation strings, runtime buffer flags TBD on device).
- out/lineage-rescue/: kernel e1226114 + identical copies of resource/ramdisk/misc from the lineage package (rescue set).
- hwc/gpubboostd.c + GPUBBOOSTD.md (daemon reconstructed from binary strings, compiles under NDK r25) - likely RETIRED once kbase devfreq measurement says clocks rise by themselves.
- docs/jank-test-plan.md T1-T8 + Protocol; docs/jank-audit-2026-11-12.md = full measurement history incl. tonight's corrections; docs/release-notes-2026-11-12.md = release/coordinate history.

## Decisions waiting on data
1. If measured cur_freq stays 198 MHz during drags -> real kernel fix is in the kbase power/clock path (candidates: kbase_pm_wait_for_reset transitions during bursts - extend power-off delay; GPLL parent switch latency).
2. If cur_freq rises but jank stays ~70% -> next HAL iteration on src-a16 (plane assignment for the scroll case + T7 AFBC).
3. RECON arm decides whether we formally retire "no-source HAL".

## match_process mystery: RESOLVED as merge-then-erase (2026-11-13 06:2x)
PLT fully decoded (pltnames.json: 939/937 stubs named; __tree::erase and
the extra emplace instantiation identified). Register-proven conclusion:
FIXED match_process, before MatchPlanes, copies the successor singleton
group's only layer into the current group's vector (0x4a324/26, end-ptr
bump 0x4a32c), pushes via vector emplace (0x59310), and erases the source
map node (0x59320) - adjacent singletons pair into one multi-area group.
That IS the strip-combine. 0x4a22e-0x4a286 = its debug log loop (level 3).
RECON (127b1134) lacks this step - RECON arm on-device is PREDICTED worse
than FIXED; port recipe (pairing-guard decode pending) recorded in
rev-hwc/ANALYSIS.md end section.

## Not done / forbidden
- No git commit/push (awaiting approval). GitHub release untouched. No partition writes until v7's automated hashes; no /data changes anywhere. All on-device steps in the queue are adb/system-level only (bind mount, setprop, service call, simpleperf).


## Afternoon session (2026-11-13 ~14:00-19:30, device rebooted once for NMS stall)
Final measured state on the stock-HAL config (6699bf1d bound via module, now
shipped INSIDE vendor.img of the 2026-11-13 package; CMA-128 kernel):
 - warm plateau: Janky ~19-23% (was BASE 92.7% cold / 46-76% CMA64),
   SF missed 18-86/round, allocation stalls 836ms -> 0.
 - frequency A/B: auto med 20.8 vs pin594 med 19.5 (6 interleaved rounds,
   cur_freq 82-90/90 sampled) -> GPU clock NEUTRAL at plateau.
 - RenderThread core sampling: uniform across 0-3 -> bind-to-bigcore idea
   rejected.
 - dma-fence census (warm window): mali job fences p50 8.68ms p90 15.1;
   composer@2.1-se sw_sync p50 28.2ms = vendor retire semantics at
   next-vsync (correct). BASE-era mali p50 was 96.9ms -> the day's
   pipeline work cut job completion 11x.
 - waitForever truth: host is SystemUI's hwui "GPU completion" worker,
   waiting on mali fences (real raster work of full-screen 1536x2048
   surfaces), NOT HWC release fences. release-at-commit plan WITHDRAWN
   before coding (vsync-proximity test 6/46 failed).
 - THREE self-corrections recorded (ANALYSIS.md "CORRECTION" blocks):
   (1) "0 GLES fallback" was HAL-side only; (2) dumpsys hwc composition=
   CLIENT = SF request state, HAL prepare logs show all-match/overlay;
   (3) no SF-side GLES composition in the plateau at all (SF-side
   eglSwapBuffers=0), and no 33ms skip bimodality (present gaps single
   peak 16.6ms) -> SF is not skipping commits; the ~20% = app producing
   30ms frames at the hardware limit of full-screen draws.
 - Backpressure A/B (debug.sf.enable_gl_backpressure true vs false,
   framework-cycle protocol) RUNNING at session cut; harness lessons:
   SF/system restarts kill the notification shade scene (fix: framework
   restart + fresh inject; NEVER am force-stop SystemUI with notifications
   bound - it stalls NotificationManagerService until reboot).
Package: release/ifive-mini4s-android16-gsi-2026-11-13.zip (804019212 B,
sha256 05e3534c...); kernel.img sha 0efd778d... == device-measured build;
package vendor HAL md5 6699bf1d... == measured file (no module needed).
restore.sh --plan verified offline: write map raw LBAs match the stock
backup notes (parameter_loader@0x2000, resource@0x8000, kernel@0x10000,
system@0x94000, metadata@0x694000, userdata@0x6bc000), chunked writes
read back and compare, loader area (0x0..0x1FFF) honestly delegated to
write-loader-head.sh.
Still awaiting user approval: git commit/push, GitHub release publish.


## Window-definition correction (same evening, after the 19-23 entry)
`Janky frames: N%` from gfxinfo covers ALL frames in the measured
window, and burst5.sh windows (0.7/1.4/0.7 s padding) include cheap
idle frames that dilute the percentage. The tight-window variant
burst5b.sh (ping-spaced) counts mostly animation frames. On the SAME
device+scene the afternoon-era burst5.sh itself now reads 82-95, so
the "plateau 19-23%" figure was a dilution artifact, not a device
state; true drawer-animation jank is ~85-95 under both HALs so far.
Still-valid same-window comparisons: BASE-era allocation stall 836ms
-> 0 (kernel CMA), GPU job completion 96.9ms -> 8.68ms p50 (dma-fence
census BASE vs shipped config), pure device-plane composition confirmed
by HAL logs. Final arbitration of "strip HAL vs base HAL" under one
definition: bg_59 (BASE/修复版/BASE2 alternating, tight windows).


## Evening re-evaluation under the single definition (tight windows)
Three-arm alternating A/B on one boot, n=20 animations/arm, same
device state: BASE(b9fb39) med 88.6 | FIXED(6699) med 90.2 | BASE2
med 88.8 -> repeat control 0.2pt = noise; HAL choice does not change
this scene's frame rate (reason: 6699's status/task-bar plane pairing
only helps when layers exceed planes; this scene uses 4).
AFBC: halafbc.so bound and verified in place; HAL verbose log prints
`iFbdcSupport = 0` - the VOP side has no AFBC read path here. Dead.
Vulkan hwui backend: device advertises vulkan 1.1 (surprise); test
queued via post-fs-data resetprop after a recovery reboot (the first
attempt used `ctl.restart zygote`, which killed system_server -
framework restarts must use `stop; start` or reboot).
Super-version note: the DEVICE's live super is the 11-10 pre-splice
build (native vendor HAL b9fb39); the 11-13 PACKAGE super already
embeds 6699 (debugfs-proven) - package correct, no action required;
afternoon 6699-era numbers came from the bind mount, same bytes.


## Incident: wrong super flashed (2026-11-13 ~22:4x) and rollback
- I wrote the 2026-11-13 AOSP package super.img (22ffdea7) to tool LBA
  0x92000 while the device ran Lineage 23.2 (user-flashed 11-12, /data
  created by Lineage). Result: old-system boot animation, no boot.
- Cause: did not check line 8 of this file before writing; no full
  backup of the device super was taken (only the 4-byte gDla probe).
- Rollback: super.img from ifive-mini4s-android16-gsi-2026-11-09-lineage232
  (sha256 6f7fbfe1..., 2037186560 B) written at 0x92000 from Loader mode
  after a gDla probe at 0x92008; head/tail 64-sector readback compared.
  No other partition touched (/data, metadata, parameter, resource).
  Kernel stays the package CMA128 kernel (0efd778d), which ran Lineage
  all day.
- Rule from now on: before any partition write, dump the current
  partition in full, and confirm the image belongs to the same system
  that created /data.


## Late evening: why every layer was GLES-composed, and the fix
- Cause: the vendor-native HAL in the Lineage 23.2 super (b9fb39) rejects
  the shade scene in mix_policy ("vop band with is too big ... (3,4),
  scale_factor=4.878906", then "go to GPU GLES at line=3065", 52x in one
  expand/collapse), so SurfaceFlinger composes all 5 layers with GLES.
- The Magisk module ifive-hwc-composition (12j) bind-mounts the fixed HAL
  (6699) at post-fs-data, but vendor.hwcomposer-2-1 is `class hal
  animation` and is already running (~17.8 s after kernel start) when the
  mount happens. /proc/<composer>/maps showed the vendor inode, so the
  fixed HAL was never used after a normal boot. Its service.d/ script is
  not run by Magisk (no service.sh) and gpubboostd is mode 0644.
- Fix applied on the tablet: 6699 spliced into the vendor partition of the
  Lineage super (release-build/splice-vendor.sh; only tool LBA 0x413800,
  271992 sectors written; device region read back equal to the original
  before writing, and equal to the new image after). After a plain boot
  the composer maps the vendor file with md5 6699bf1d, all 5 shade layers
  are composition=DEVICE, VOP error interrupts 0.
- Measured (burst5b, J = janky %): stock HAL same boot ~93 (79-98);
  6699 native after boot ~59-67; after framework restart 56-73; after
  composer restart 56-76. One earlier reading of ~30 was not reproduced.
- Remaining cost is SystemUI CPU work at 1608 MHz: UI thread traversal
  ~21 ms/frame, RenderThread ~17 ms/frame (Skia + GL driver). Pipeline
  waits are small: dequeueBuffer p50 0.08 ms, waitForBufferRelease 7x.
  GPU frequency is not the limit (pinned 594 MHz: no improvement).
- Correction: hwui cannot use Vulkan on this tablet. With skiavk the
  RenderThread aborts: "physDeviceProperties.apiVersion <
  VK_MAKE_VERSION(1, 1, 0)" (Mali driver reports Vulkan 1.0). The
  afternoon "Vulkan arm" only showed libvulkan.so mapped; it ran GL.
- splice-vendor.sh now writes the SELinux label NUL-terminated (30 bytes,
  same as Android image tools). The old 29-byte form also parses
  (kernel/security/selinux/ss/services.c:1512 kmemdup_nul).


## After the vendor fix: what was measured and ruled out (2026-11-14 00:xx)
All on Lineage 23.2 with 6699 native in vendor, 5 shade layers DEVICE.
- Per-frame split (gfxinfo framestats, 53 frames, 30 past deadline): the
  UI thread is the longest stage in 27 of the 30 late frames. Frames come
  every 2 vsyncs (IntendedVsync gap p50 33.5 ms). Vsync->HandleInputStart
  p50 5.8 ms, animation callbacks 4.6 ms, measure/layout 5.4 ms; RT issue
  8.7 ms; GPU after swap 16.2 ms. dequeueBuffer p50 0.05 ms.
- GPU clock: pinned 297 MHz -> frame p50 93 ms (GPU work scales with the
  GPU clock); pinned 594 MHz -> no gain over default devfreq. GPU power
  policy always_on vs coarse_demand: no difference. GPU utilisation in one
  in-animation sample: 64 % at 594 MHz.
- DDR runs at dpll 396 MHz. The dmc node is disabled and the RK3288 dmc
  driver needs OP-TEE SIP DRAM calls; there is no /dev/tee*, so DDR DVFS
  is not available on this tablet. Not attempted.
- RT placement: SurfaceFlinger and composer (SCHED_FIFO) preempt the
  SystemUI UI thread for ~490 ms per 8 s. Ported the MediaTek patch
  "sched/rt: avoid contend with CFS task" (LKML 2019-08-28) into
  kernel/sched/rt.c, flashed it (kernel partition backed up first): UI
  preemption fell to 407 ms, J did not improve -> reverted on device and
  in source.
- composer CPU: ~2.6 s per 18 s burst. Profile of a source build of the
  same HAL: vsync callback path 10.8 %, per-frame buffer import/free and
  gralloc4 metadata ~17 %, debug-string building with logging off ~4.5 %,
  binder 11.8 %. Not changed: all SF+composer preemption is < 2 ms per
  frame at 30 fps, and removing 83 ms of it did not move J.
- Remaining cost is SystemUI's own work on the UI thread and RenderThread
  (plus GC: HeapTaskDaemon ~1 s and JIT ~0.7 s per 18 s burst).
- Note: simpleperf cpu-clock on this kernel records about one sample per
  7 ms of run time (tick-limited); use schedstat for run-time totals.
