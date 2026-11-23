# iFive mini 4S - Android 16 GSI release 2026-11-23 (LineageOS 23.2, Linux 6.1)

Changes since 2026-11-22. Same system (LineageOS 23.2 GSI, build 2026-06-20) and boot ramdisk.

## Kernel
- fuse-bpf, ported from android14-6.1: Android/data and Android/obb go straight to the lower filesystem instead of through the FUSE daemon (`ro.fuse.bpf.is_running=true`).
- A soft or hard lockup now panics the kernel; the tablet reboots in 5 s and the log stays in `/sys/fs/pstore` (`dmesg-ramoops-*`, `console-ramoops-0`).
- Settings left over from bring-up are undone: the gyroscope is enabled again, USB OTG is back to `otg` role switching, and the kernel no longer rewrites the `kpanic` partition every 2 s (about 11 GB of eMMC writes a day on 2026-11-22).
- Bring-up debug code removed (checkpoint probes, decompressor watchdog, backstop watchdog, `rk_logdump`).

## Upgrading from 4.19 with `--keep-userdata`
4.19 had sdcardfs and left files in `Android/data` owned by `media_rw`; on 6.1 apps cannot open them (Obtainium shows an empty list, App Manager negative sizes). Run `scripts/fixup-app-dirs.sh` from the repository once with root, or wipe data.

## Checked on the tablet
Flashed with the package's `flash.sh --yes --keep-userdata`, every write read back OK. Boots enforcing with data kept; fuse-bpf running; Wi-Fi connects and pings; battery 97 % charging; gyroscope listed; no crashes in the crash log.

## Known issues
- The tablet hangs or reboots now and then on 6.1, cause not known yet (now leaves a pstore log).
- Once, Wi-Fi failed to turn on for a whole boot; a reboot fixed it.
- Landscape launcher swipes still drop about 10 % of frames, as on 4.19.

## Files
- `ifive-mini4s-android16-gsi-2026-11-23-lineage232.zip`: the full package (flash.sh, restore.sh, images, loader, README).
- `ifive-mini4s-android16-boot-magisk-v31.img`: optional Magisk 31.0 boot image; unchanged from r3 (same ramdisk).
- `ifive-mini4s-launcher3-icon-cache.apk`: Launcher3 with cached themed icons, unchanged.
