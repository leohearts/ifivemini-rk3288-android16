# iFive mini 4S - Android 16 GSI release 2026-11-22 (LineageOS 23.2, Linux 6.1)

Changes since 2026-11-15-r3. The system (LineageOS 23.2 GSI, build 2026-06-20) and the boot ramdisk are the same; the kernel moves from 4.19 to 6.1. Tested on one tablet with `/data` kept.

## Kernel 6.1
- Rockchip `develop-6.1` (6.1.172) with this board's device tree and drivers carried over from the 4.19 port: touch (gslX680), PMIC, charger and fuel gauge (RC5T619), audio (RT5616), Wi-Fi (AP6255, rkwifi `bcmdhd` rebuilt for 6.1), front and back cameras (GC2145 on CIF, OV8856 on the ISP), video decode and encode (MPP), RGA, Mali-T760 (midgard r18p0), DDR frequency switching and deep sleep.
- 6.1 has no ION. The gralloc 4.0 allocator and mapper are rebuilt from the Rockchip `android14-rockchip` midgard gralloc and allocate from dma-buf heaps (`/dev/dma_heap/system`, `system-uncached`).
- ART uses the CMC garbage collector (6.1 has `userfaultfd`). The Java heap reserves 1x its size instead of 2x: YouTube's address space went from 2771 MiB to 2083 MiB, and it no longer aborts on a GPU allocation.
- CPU frequency: `cpufreq-dt` with the `schedutil` governor, 126-1608 MHz (6.1 has no `interactive` governor).
- GPU frequency: 100-600 MHz. The GPU thermal zone has a 60 °C switch-on trip and a 1200 mW budget; without them the thermal governor held the GPU at 100 MHz at 35 °C.
- DDR: 456 MHz with the screen on, 396 MHz with it off. A rate change that misses every vblank right after the screen turns on is retried once a second, up to 10 times.
- `adb reboot loader` reaches Loader mode: the PMIC re-power is skipped for reboots with a mode, because it cleared the boot-mode register.
- The release `resource.img` is now built from the kernel's device tree.

## Fixes found while porting
- Accelerometer (LSM330): the output data rate is written on every enable; with a read-modify-write it stayed at 0 and auto-rotation stopped.
- Speaker and microphone: the RT5616 default playback and capture routing set up at probe.
- Back camera: 5-6 ms wait after the OV8856 soft reset.
- SELinux labels for the 6.1 sysfs names (`ff0d0000.mmc` instead of `ff0d0000.dwmmc`, and four wakeup sources).

## Checked on the tablet
SELinux enforcing; no crashes or kernel oops; display, HWC (all layers in device composition) and screenshots; touch, power key and accelerometer; battery 95 % charging at 4.07 V; Wi-Fi off/on and ping; Bluetooth on/off; audio playback and recording; front and back camera preview; 1080p H.264 hardware decode and screen recording; deep sleep 3/3 rounds with memory intact; two reboots, each about 90 s to a connected Wi-Fi.

## Known issues
- Upgrading from a 4.19 build with `--keep-userdata`: apps can lose access to files they made in `Android/data` (Obtainium shows an empty app list, App Manager shows negative sizes). 4.19 had sdcardfs, which left those files owned by `media_rw`; 6.1 has none. Either wipe data, or run `scripts/fixup-app-dirs.sh` from this repository once with root (needs a vendor image built after this release, which carries the tool).
- The tablet hung or rebooted a few times on 6.1 (twice a kernel oops on an idle CPU, other times no log). The cause is not known yet.
- Once, Wi-Fi did not turn on for a whole boot (`mmc2: tried to HW reset card, got error -2`). It has not come back; a reboot fixed it. The kernel now logs which check rejected the card.
- Launcher swipes still drop about 10 % of frames, about the same as on 4.19.

## Files
- `ifive-mini4s-android16-gsi-2026-11-22-lineage232.zip`: the full package (flash.sh, restore.sh, images, loader, README).
- `ifive-mini4s-android16-boot-magisk-v31.img`: optional Magisk 31.0 boot image. The boot ramdisk is unchanged from r3, so this is the r3 file.
- `ifive-mini4s-launcher3-icon-cache.apk`: Launcher3 with cached themed icons, unchanged from r3.
