# Status 2026-11-07 (rebuilt 15:10 after the reports directory was lost in the cleanup)

## Loss
- 14:40 cleanup of /run/media/leohearts/Data/rk3288-port-tmp removed rk3288-port/ (reports + scripts). The /tmp/rk3288-port/reports symlink pointed
  into it. All earlier *.md reports (HANDOFF, RUNNER-RULES, Perf16, Hwc16, HwcSrc-2, HwcBuild, Td16g/h/j, Hwc2Build/Link/Eval, Cyc1, RingClass, ...)
  are gone. Filesystem is btrfs (discard=async): `btrfs restore` needs root and is unlikely after TRIM. Agent transcripts (history://<Name>) still
  hold most of the content.

## Tablet
- Booted Android 16 GSI, super td16i (HWC1 + fence fix c0eea98, sha 83101dff), release kernel kernel-release-rl5bj, release resource, brightness 20.

## Done today
- Hardware watchdog verified under a hard hang (all CPUs IRQ-off): hardhang=1 -> adb dead -> reset within ~10-16 s -> maskrom (loader flag) -> rd -> boot.
  CRU_GLB_RST_ST 0x00 before / 0x22 after (bit5 snd_glb_wdt_rst_st). Kernel rl5hh, cmdline rkwdt=1 rkwdt_loader=1.
- Off-mode charging: reboot -p with charger -> no USB, panel dark 90 s -> no Android boot. Pass.
- Hang hunt (runs/huntdbg): 6 first-boot cycles, kernels rl5bk (JIT) / rl5bk3 (JIT+BPF call fix) / rl5bk2 (interpreter) x resources fb1500p5
  (pvtm voltage columns) / fb1500p5v (L0 pinned, no regulator-ramp-delay): ALL BOOTED. No real hang reproduced with the debug kernel.
  Earlier "hangs" re-classified from the kpanic ring: only 11-06 23:23 A12 (ring stops 86.68 s, init starting netd/wificond) is a ring-backed real hang;
  every fbdbg/huntdbg HANG whose ring exists shows boot_completed (host adb server wedge, "no permissions" until adb kill-server -> runs/driver/adbfix.sh).
  Release-boot hangs (11-06 07:06/07:36/19:50, 11-04 A11) have no ring (RK_LOGDUMP off) -> unknown.
- Closed leads: BPF JIT (no BPF-to-BPF calls in any loader's programs); A17 errata (CPU is Cortex-A12 r0p1 MIDR 410fc0d1, A12 errata on).
- A/B warm boot (runs/ab16): td16i 20%/11% janky p50 25/21 ms, later 5% p50 23; td16g (no fence fix) 50%/56% p50 44/48. First-boot numbers are noise.
- HWC2 port: android_hardware_rockchip_hwcomposer_drmhwc2 lineage-23.2 (0ac4d603) + new rk3288 platform (Vop3288/Hwc3288, VOP1 planes 55-65),
  stubs for RGA buffer import/baseparameter, tinyxml2 static, old librga API. Build script hwc/build-hwc2.sh, output hwc/out2/hwcomposer.rk30board.so
  (build22 afc30344; stripped 15866447 in the image), checkso unresolved 0. Super gsi/new/super-td16j.img (d83b3474; vendor grown +196 KiB).
  On device: boots 51 s, loads natively ("HWC2-1.5.165", no hwc2on1adapter), all layers DEVICE, rotation/screen-off/screenshots OK (Hwc2Eval).
- CPU per rendered frame (runs/hwc2t/cpu-td16j.txt vs cpu-td16i.txt, median of 3, ~780 frames, Settings swipe):
  composer 0.86 ms (HWC2) vs 4.15 ms (HWC1+adapter); SF 3.98 vs 4.28; system non-idle 21.2 vs 23.3 ms/frame. Jank same ballpark.
- Host incidents: 09:40 two scripts flashed at once (my pkill missed a child) -> loader wedged; 10:16 killing the leftover flashX mid-write wedged it again
  (owner power-cycled 11:09); 12:00 systemd-oomd killed desktop apps + the device chain (tmpfs /tmp had 4.3 G from a scout). Fixes: single driver +
  flock runs/device.lock, chain runs as user unit rk3288-driver4 (ManagedOOMPreference=avoid), /tmp cleaned.
- Data cleanup: 50 G -> 112 G free; rk3288-a11 12 G. resource_tool/dtc now in release/build/tools/; build-res-release.sh/guard-release.py updated.

## Key paths
- R=/run/media/leohearts/Data/rk3288-a11; kernel ksrc-touch (chg-cur); kbuild-rl5 (dev) / kbuild-rl5-release (A11) / kbuild-rl5b-release (GSI) / kbuild-rl5b-dbg.
- Supers: gsi/new/super-td16i.img (A16 HWC1 fence fix + chg switch), super-td16j.img (A16 HWC2), super-td16g.img (A16 HWC1 ab3afb5).
- Kernels work-rl5: kernel-release-rl5bj (GSI release, logdump), kernel-release-rl5j (A11 release), rl5bj (dev), kernel-dbg-rl5bk* (debug), rl5hh (WDT test).
- Resources work-rl2: res-gsi-fb1500p5(v) (test, 1500 s deadline, kpanic 5 s), res-gsi-rel1500p, res-gsi-t300, res-relt-dev300; release/build/resource-release*.img.
- Flash: gsi/flashX-gsi.sh --system <super> --fullcmp (maskrom via `adb root; echo 1 > /sys/module/rk_wdt_backstop/parameters/reset_loader`), kernel/res/ramdisk via
  gsi/flashX.sh --kernel --res --ramdisk --rd (ramdisk: scratch/acc6/*/images/ramdisk.img). rkdeveloptool /tmp/rkdev/usr/bin (copy of release/build/rktool).
  Tool LBA = kernel sector - 0x2000. adb -s RK3288IFIVE01 only. Device lock runs/device.lock (flock -n 9).
- Measurement: runs/ab16/after-nolock.sh (jank), runs/hwc2t/cpu.sh <tag> (CPU/frame). Keyguard: wm dismiss-keyguard + swipe up.

## Open
- HWC2 soak (reboots, rotation, video, long idle) before it becomes the A16 release vendor.
- Release packages: rebuild A16 (td16j if soak passes else td16i) + A11/A12 with rl5j/rl5bj; make-release.sh references release/build inputs.
- Hard hang root cause: no new evidence; only reproduces on release-config boots so far (no logdump). Next: release kernel with RK_LOGDUMP (rl5bj has it) soak.

## 15:40 update
- Soak2 on td16j: 3 reboots (boot_completed each), screen off/on, 20 min idle (composer/SF pids unchanged), 0 SF/HWC fatal lines. Rotation verified by
  screencap (landscape launcher renders; earlier black captures were taken while dozing). Video: media.player reports playing, screencap of the video
  layer is black (capture of the YUV overlay), panel content NOT verified (webcam no longer aimed at the panel). Open: eyeball video playback once.
- Recovered after the report loss: stock loader release/build/loader/RK3288UbootLoader_V2.30.10.bin (sha f1dcc699... byte-exact from runs/rel06e),
  mkkrnl.py rewritten at release/build/tools/mkkrnl.py (rkcrc poly 0x04C10DB7; verified byte-identical repack).
- Release: release/ifive-mini4s-android16-gsi-2026-11-07.zip (b4684ca4...; super td16j HWC2, kernel rl5bj, GSI flash.sh with META 0x692000/UD 0x6ba000,
  guard OK). A11/A12 packages NOT rebuildable: their supers (super18f, super-gsi13) and the A12 system source were deleted in today's cleanup;
  rebuilding needs the A11 vendor from rk3288-backup (p10-system etc.) and a fresh GSI 12 image.

## 16:08 final state
- Tablet: A16 release ifive-mini4s-android16-gsi-2026-11-07.zip (sha 87b6fd4b...; super td16k = HWC2 + chgpolicy seclabel fix, kernel rl5bj, release
  resource, stock loader in the package). Flashed via the package's flash.sh --yes; first boot 5 min; brightness 20; home screen verified by screenshot.
- Checks on the release boot: cmdline rkwdt=0 no rkdeadline; HWC sha 15866447 (HWC2-1.5.165), CLIENT 0; touch/Settings ok; wifi scan 15 lines;
  speaker present; accelerometer 0x67 + events; chgpolicy running, high_current_allowed Y, ADP limit 500000 -> 2000000 after boot; logcat F/ 0.
- Fixes found by the acceptance: flash.sh GSI system-slot guard (0x300000 -> 0x600000 sectors); vendor.chgpolicy had no seclabel (init refused the
  domain transition) -> td16k.
- Open: video playback on HWC2 only verified by media.player state (screencap of the overlay is black); hard-hang root cause (no reproduction today);
  A11/A12 packages not rebuildable until their supers are re-made.

## 17:10 correction + final state
- HWC2 (td16j/td16k) was NOT working correctly: init_success_=0 ('TryAssignPlane fail'), plane-0 kept the fbcon fb, SetPowerMode skipped ->
  after screen off/on the panel showed the fbcon console (owner report). The CPU numbers measured on it are therefore not a valid comparison.
  build24 (soc_id 0x3288 + Hwc3288 stage) -> 'no plane for layer', all planes crtc=NULL; reverted. Root cause open (Hwc2Crtc.md: BindDpyRes path).
- Release now: release/ifive-mini4s-android16-gsi-2026-11-07.zip (sha 791935d6...), super td16n = HWC1 fence fix (83101dff) + chgpolicy seclabel fix.
  Flashed with its flash.sh; first boot adb +282 s, boot_completed +314 s; chgpolicy running, ADP 2000000; rkwdt=0, no rkdeadline;
  screen off/on x3 shows Android, fbcon fb 70 not on any plane; brightness 20. Device left on the lock screen (first boot, no lock set).
