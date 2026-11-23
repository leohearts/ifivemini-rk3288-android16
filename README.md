# iFive mini 4S — Android 16

**LineageOS 23.2 on a 2015 RK3288 tablet that shipped with Android 6.**

RK3288, 2 GB RAM, Mali-T760, a 1536x2048 panel. The system is the LineageOS 23.2 GSI (arm32_binder64). The vendor partition is borrowed from the ASUS Tinker Board's Android 11, another RK3288 board.

## Screen*shot*s

<img height="300px" alt="PXL_20261108_175240621 jpg" src="https://github.com/user-attachments/assets/6c9ac10f-92d0-43e6-826b-8f162be20d14" />
<img height="300px" alt="PXL_20261108_175035032 jpg" src="https://github.com/user-attachments/assets/14219f6f-d90c-48e2-b879-8fb2313e87eb" />

## Install

You need a Linux x86_64 PC. `rkdeveloptool` is in the package.

**Files** (from [Releases](https://github.com/leohearts/ifivemini-rk3288-android16/releases))
- `ifive-mini4s-android16-gsi-<date>-lineage232.zip`: the full package (flash.sh, restore.sh, images, loader, README).
- `ifive-mini4s-android16-boot-magisk-v31.img`: optional Magisk 31.0 boot partition.
- `ifive-mini4s-launcher3-icon-cache.apk`: optional Launcher3 with cached themed icons (smoother app drawer).

**Flash** (unzip, power off, hold Volume Down, plug in USB)
```sh
sha256sum -c SHA256SUMS
sudo bash restore.sh               # stock Android 6 or wiped tablet
# or
sudo bash flash.sh --yes --keep-userdata   # from an earlier build here
```

The first boot takes a few minutes and prints kernel text on the screen. That's normal.

**Optional**

- Fix launcher lag
```bash
adb install -r ifive-mini4s-launcher3-icon-cache.apk
```

- Magisk
```sh
./tools/rkdeveloptool wl 0x16000 ifive-mini4s-android16-boot-magisk-v31.img && ./tools/rkdeveloptool rd
# after it boots, from a clone of this repository (uses adb root), then reboot:
scripts/magisk-install-data.sh Magisk-v31.0.apk
```

- coming from a 4.19 build (2026-11-15-r3 or older) with --keep-userdata, once, with root:
```
scripts/fixup-app-dirs.sh
```

Bricked it? The package README covers an erased partition table and a completely blank eMMC.

## What's different from just flashing a GSI

These are the parts that make it boot on this tablet, and then drop fewer frames. Each line: what changed, then what you get. The folder where it lives is in brackets.

### Kernel and hardware

- **Linux 6.1** (Rockchip `develop-6.1`) with drivers for this board: touch, Wi-Fi, audio, cameras, charging, sensors [`kernel/`]. Up to release 2026-11-15-r3 the kernel was 4.19.
- **Wi-Fi**: the Rockchip `bcmdhd` driver built for 6.1 as a module, installed into the vendor partition [`kernel/`, `vendor-changes/`]. Connects to WPA3 5 GHz networks.
- **Audio**: the RT5616 codec gets the same default speaker and microphone routing as on 4.19 [`kernel/`]. Before, recordings were silent.
- **Cameras**: front (GC2145) and back (OV8856) cameras work through the Rockchip CIF and ISP drivers [`kernel/`].
- **Charging**: input limit policy in the `rn5t618` driver, on by default [`kernel/`, `vendor-changes/`]. On a wall charger the input goes from 500 mA to 2 A once boot completes, while the charge is under 95% and the SoC under 70 °C. The battery temperature steps it down to 1 A at 40 °C and 500 mA at 45 °C. iFive settings (or `persist.vendor.chg.boost` `on`/`off`) overrides it.
- **Backlight**: lowest level is duty 61, the lowest value the panel still lights at [device tree]. The brightness slider goes lower without the screen turning off.
- **Hangs leave a log**: a CPU stuck for 10-20 s makes the kernel panic, the tablet reboots in 5 s and the log stays in `/sys/fs/pstore` [kernel config].

### Speed and battery

- **CPU frequency**: `cpufreq-dt` with the `schedutil` governor, 126-1608 MHz [kernel config, `vendor-changes/`].
- **GPU frequency**: 100-600 MHz, with a 60 °C thermal switch-on point and a 1200 mW budget [device tree]. Without them the GPU stayed at 100 MHz.
- **DDR**: 456 MHz instead of the loader's 396 MHz while the screen is on, 396 MHz while it is off [kernel, `init.rk3288.rc`]. Shade animation jank 42% → 34%.
- **Timers**: RK3288 timer as tick broadcast, so high-resolution timers exist at all [device tree]. SurfaceFlinger missed frames 423-733 → 0-44 per test.
- **Deep sleep**: logic power domain, PLLs and the 24 MHz clock off, DDR in self-refresh (the stock firmware's `ARMOFF_LOGDP` mode; code from the ChromeOS veyron kernel) [`kernel/arch/arm/mach-rockchip/`]. Before, suspend only turned the CPUs off.
- **Deep Doze** without a significant-motion sensor: a vendor overlay sets `config_autoPowerModeUseMotionSensor` to false [`overlays/deep-doze/`, `vendor-changes/`]. Unplugged, the tablet reaches deep Doze about 2.5 minutes after the screen goes off.
- **No CEC wakelock**: `ro.hdmi.device_type` removed (the Tinker Board vendor declared a CEC playback box) [`vendor-changes/build.prop`]. `HdmiCecLocalDevicePlayback` no longer keeps the tablet awake.
- **Rockchip Power HAL** (`android.hardware.power-service.rockchip`) [`vendor-changes/`]. Android finds `IPower`; before, SurfaceFlinger started later.

### Graphics and display

- **dma-buf heaps instead of ION**: gralloc 4.0 rebuilt from the Rockchip `android14-rockchip` midgard gralloc [`gralloc/`, `vendor-changes/`]. 6.1 has no ION; SurfaceFlinger, the GPU, the cameras and the video codecs share buffers through `/dev/dma_heap/`.
- **HWC** (hardware composer) [`hwc/`]:
  - rotates the landscape wallpaper with RGA instead of handing the whole screen to the GPU: landscape app drawer jank 68% → 44%.
  - keeps unchanged bottom layers composed when there are more layers than display windows: landscape shade jank 72% → 47%.
  - checks every layer before two of them share a display window: no more vertical stripes, no black screen after screen off/on.
  - leaves frames that SurfaceFlinger composed on the GPU alone: grayscale, night light and extra dim stay on.
- **Three framebuffers** instead of two [`vendor-changes/build.prop`]. Recents opened from an app: jank 78% → 43%.

### Android system

- **ART uses the CMC garbage collector** (6.1 has `userfaultfd`) [kernel config]. The Java heap reserves 1x its size instead of 2x: YouTube's address space 2771 MiB → 2083 MiB, and it no longer aborts on a GPU allocation.
- **fuse-bpf**, ported from android14-6.1 [`kernel/`]. `Android/data` and `Android/obb` go straight to the disk instead of through the FUSE daemon.
- **SELinux enforcing** [device tree, `vendor-changes/`]. Wi-Fi, charging, display, audio and cameras work with it on.
- **`adb root` under enforcing**: AOSP's userdebug rule `permissive su`, which the GSI leaves out [`scripts/patch-identity.sh`]. Before, adbd exited and adb was gone until reboot.
- **Lock screen**: software gatekeeper and keymaster instead of the Rockchip OP-TEE ones (the board has no TEE) [`gatekeeper/`, `keymaster/`, `vendor-changes/`]. A PIN, pattern or password can be set and unlocked; before, a PIN could be set but never verified.
- **Quota on `/data`**: the GSI's fs_mgr turned it off on every boot because the tablet has no file encryption (TrebleDroid patch 0015) [`scripts/patch-fsmgr-quota.py`, `scripts/patch-identity.sh`]. Apps such as Recorder can create their `Android/data` folder.
- **vold reads the vendor fstab** (`androidboot.fstab_suffix=rk30board.emmc`) [device tree bootargs]. Quota, reserved space and the microSD slot are known to vold.
- **Name**: "iFive mini 4S" in `build.prop` [`vendor-changes/`, `scripts/patch-identity.sh`].
- **iFive settings** on the Settings home page (System card): deep Doze, kernel deep sleep, DDR frequency (456/396 MHz), charger input, and a link to phh's TrebleDroid settings, whose own entry is hidden [`apps/ifive-settings/`, `vendor-changes/`]. Each takes effect at once except deep Doze (after a reboot).

### Flashing

- **Scripts that write in small verified pieces** [`release-build/`]. A dropped USB connection resumes instead of starting over.
- **`scripts/fixup-app-dirs.sh`**: after upgrading from 4.19 with data kept, asks Android (vold `fixupAppDir`) to give `Android/data` files back to their apps.

## Not perfect

- The landscape app drawer drops about 65% of its frames with the stock Launcher3: it clips every themed icon on the CPU, every frame (Skia turns off GPU path rendering on Mali-T). The Launcher3 from the release brings it to 12-17%.
- The landscape notification shade drops about half of its frames. Most of each slow frame is SystemUI's own work on its UI thread.
- The battery level comes from the PMIC's fuel gauge. The device tree also lists a CW2015 gauge, but nothing answers at its address on this board; the node stays because the loader uses it for off-mode charging.
- The tablet hangs or reboots now and then on 6.1, cause not known yet. The kernel panics on a soft or hard lockup. After a kernel panic the tablet reboots in 5 s and the log is in `/sys/fs/pstore` (`dmesg-ramoops-*`, `console-ramoops-0`) until the next panic; read it with root, e.g. `adb shell su -c 'cat /sys/fs/pstore/dmesg-ramoops-*'`.
- Once, Wi-Fi failed to turn on for a whole boot (`mmc2: tried to HW reset card, got error -2`). It has not come back since; the kernel logs which check rejected the card if it does.
- The first DDR rate change after the screen turns on sometimes misses every vblank; the driver retries it a second later.

## Building

The system is the unofficial LineageOS 23.2 a64 GSI by [Lost-Entrepreneur439](https://github.com/Lost-Entrepreneur439/LineageOS-a64_gsi), build 2026-06-20.

Linux x86_64. Clone with [git-lfs](https://git-lfs.com) installed: the stock bootloader files in `stock-backup/` are LFS objects.

Fedora:

```sh
sudo dnf install -y git-lfs python3 zip unzip dtc bc bison flex lz4 openssl-devel \
    gcc-arm-linux-gnu binutils-arm-linux-gnu android-tools e2fsprogs xz
```

Debian/Ubuntu: `apt install git-lfs python3 zip unzip device-tree-compiler bc bison flex lz4 libssl-dev gcc-arm-linux-gnueabi android-sdk-libsparse-utils e2fsprogs xz-utils`, set `CROSS_COMPILE=arm-linux-gnueabi-`, and build `lpmake`/`lpunpack` from AOSP `system/extras/partition_tools`.

The HWC needs Android NDK r25 (set `NDK=`; default `~/Android/Sdk/ndk/25.0.8775105`) and the VNDK-30 headers:

```sh
curl -LO https://github.com/leohearts/ifivemini-rk3288-android16/releases/download/init/vndk30.tar.gz
tar xzf vndk30.tar.gz -C hwc/hdr
```

Then:

```sh
./build-kernel.sh                         # out/kernel-gsi-6.1/kernel.img, vendor-changes/lib/modules/bcmdhd.ko
./release-build/build-resource.sh         # release-build/resource-release-gsi.img
(cd hwc && ./build.sh)                    # hwc/out/hwcomposer.rk30board.so
cp hwc/out/hwcomposer.rk30board.so vendor-changes/lib/hw/

curl -LO https://github.com/Lost-Entrepreneur439/LineageOS-a64_gsi/releases/download/2026-06-20/lineage-23.2-20260620-a64-bvN.tar.xz
./build-android-images.sh lineage-23.2-20260620-a64-bvN.tar.xz <release.zip>
./release-build/make-release.sh inputs <date>
scripts/make-magisk-boot.sh inputs/ramdisk.img Magisk-v31.0.apk boot-magisk-v31.img
```

The gatekeeper and keymaster services in `vendor-changes/bin/hw/` are built with the same NDK from an AOSP 16 source tree (any LineageOS 23.2 checkout that has been built once, for the generated HIDL headers in `out/`) and a few libraries pulled from the tablet:

```sh
mkdir libs && for l in liblog libbinder_ndk; do adb pull /system/lib/$l.so libs/; done
for l in android.hardware.keymaster@4.0 libhidlbase libutils libcutils libbase libcrypto libc++; do
    adb pull /apex/com.android.vndk.v30/lib/$l.so libs/; done
adb shell su -c "cat /vendor/lib/libkeymaster4support.so" > libs/libkeymaster4support.so
gatekeeper/build.sh <aosp-tree> libs      # vendor-changes/bin/hw/android.hardware.gatekeeper-service.ifive
keymaster/build.sh <aosp-tree> libs       # vendor-changes/bin/hw/android.hardware.keymaster@4.0-service.ifive
```

The gralloc 4.0 allocator and mapper in `vendor-changes/lib/hw/` allocate from dma-buf heaps (`/dev/dma_heap/system`, `system-uncached`) instead of ION, which the 6.1 kernel does not have. They are built from the Rockchip `android14-rockchip` midgard gralloc (cloned and pinned by the script) with the VNDK-30 headers from `hwc/hdr/vndk30`, and link only against libraries the vendor partition already has:

```sh
gralloc/pull-libs.sh libs-gralloc         # adb pull of the VNDK v30 / LLNDK libraries and the original vendor gralloc
gralloc/build.sh <aosp-tree> libs-gralloc # vendor-changes/lib/hw/android.hardware.graphics.{allocator,mapper}@4.0-impl-midgard.so
```

The vendor `android.hardware.graphics.allocator@4.0-service` loads the new library unchanged (same file names, passthrough lookup by the `-impl` prefix).

The deep Doze overlay and the iFive settings app need the Android SDK (build-tools 36.1.0, platforms/android-36) and a JDK:

```sh
overlays/build.sh                         # vendor-changes/overlay/DeepDoze.apk
apps/ifive-settings/build.sh              # vendor-changes/priv-app/IfiveSettings/IfiveSettings.apk
```

`build-android-images.sh` takes vendor, odm, the boot ramdisk and `rkdeveloptool` from a release zip of this project, puts in the GSI system and `vendor-changes/`, and writes everything to `inputs/`. The zip ends up in `release/`.

The Wi-Fi driver is the Rockchip rkwifi `bcmdhd` of the 6.1 tree, built as a module (`CONFIG_AP6XXX=m`): it loads the firmware from `/vendor/etc/firmware` when it is inserted, and `/vendor` is not mounted yet when the SDIO card is probed at boot. `build-kernel.sh` builds it with the kernel and stages the stripped `bcmdhd.ko` in `vendor-changes/lib/modules/` (git-ignored); `scripts/patch-vendor.sh` writes it to `/vendor/lib/modules/`, where the vendor Wi-Fi HAL inserts it. It has to come from the same build as `kernel.img`: with a different vermagic or different symbol CRCs the insmod fails with `disagrees about version of symbol module_layout`. The old `bcmdhd.ko` from the 4.19 vendor partition cannot be used on 6.1.

## Layout

- `kernel/`, `kernel-configs/`: the kernel and its release / debug configs
- `hwc/`: the patched Rockchip HWC1 and its build; `hwc/test/` has the jank measurements
- `gatekeeper/`, `keymaster/`: build scripts for the software gatekeeper and keymaster services (the board has no TEE)
- `gralloc/`: build script, tablet library puller and patch for the dma-heap gralloc 4.0 allocator and mapper
- `launcher3/`: build script for the Launcher3 with cached themed icons
- `overlays/`, `apps/ifive-settings/`: the deep Doze overlay and the iFive settings app, installed in the vendor image
- `vendor-changes/`: every file this project changes in the Tinker Board vendor image
- `release-build/`: packaging, flash and rescue scripts, the device tree, the stock loader
- `scripts/`: image and Magisk helpers
- `stock-backup/`: the stock partition table and bootloader, for the rescue data
- `docs/`: release notes; `docs/tradeoffs.md` lists settings that cost something
