# iFive mini 4S — Android 16

**LineageOS 23.2 on a 2015 RK3288 tablet that shipped with Android 6.**

RK3288, 2 GB RAM, Mali-T760, a 1536x2048 panel. The system is the LineageOS 23.2 GSI (arm32_binder64). The vendor partition is borrowed from the ASUS Tinker Board's Android 11, another RK3288 board.

## Screen*shot*s

<img height="300px" alt="PXL_20261108_175240621 jpg" src="https://github.com/user-attachments/assets/6c9ac10f-92d0-43e6-826b-8f162be20d14" />
<img height="300px" alt="PXL_20261108_175035032 jpg" src="https://github.com/user-attachments/assets/14219f6f-d90c-48e2-b879-8fb2313e87eb" />

## Install

You need a Linux x86_64 PC. `rkdeveloptool` is in the package.

1. Download `ifive-mini4s-android16-gsi-<date>-lineage232.zip` from [Releases](https://github.com/leohearts/ifivemini-rk3288-android16/releases), unzip, `sha256sum -c SHA256SUMS`.
2. Power the tablet off. Hold Volume Down and plug in USB.
3. Still on the stock Android 6? `./restore.sh`.
   The stock partition table is too small for Android 16, so this one writes a new table first.
4. Already on a build from here? `./flash.sh --yes`.
   Add `--keep-userdata` to keep your apps and data.

The first boot takes a few minutes and prints kernel text on the screen. That's normal.

Root: write `ifive-mini4s-android16-boot-magisk-v31.img` from the same release with `./tools/rkdeveloptool wl 0x16000 <file>`, then install the Magisk 31.0 app.

Bricked it? The package README covers an erased partition table and a completely blank eMMC.

## What's different from just flashing a GSI

These are the parts that make it boot on this tablet, and then drop fewer frames.

| What | Where | Result |
|---|---|---|
| Linux 4.19 with drivers for this board: touch, Wi-Fi, audio, camera, charging, sensors | `kernel/` | it boots, and the hardware works |
| DDR runs at 456 MHz instead of the loader's 396 MHz | kernel + `init.rk3288.rc` | shade animation jank 42% → 34% |
| RK3288 timer as tick broadcast, so high-resolution timers exist at all | device tree | SurfaceFlinger missed frames 423-733 → 0-44 per test |
| HWC rotates the landscape wallpaper with RGA instead of handing the whole screen to the GPU | `hwc/` | landscape app drawer jank 68% → 44% |
| HWC keeps unchanged bottom layers composed when there are more layers than display windows | `hwc/` | landscape shade jank 72% → 47% |
| HWC checks every layer before two of them share a display window | `hwc/` | no more vertical stripes, no more black screen after screen off/on |
| Three framebuffers instead of two | `vendor-changes/build.prop` | recents opened from an app jank 78% → 43% |
| Power HAL, charging policy, the tablet's own name in `build.prop` | `vendor-changes/` | |
| Flash scripts that write in small verified pieces and resume after a dropped USB | `release-build/` | |

## Not perfect

- The landscape app drawer still drops a lot of frames. Launcher3 clips every themed icon on the CPU, every frame, because Skia turns off GPU path rendering on Mali-T. Turning off themed icons, or picking the circle icon shape, takes it down to about 20%.
- Rarely, the tablet hard hangs. The cause is still unknown. The kernel keeps a log in the `kpanic` partition; `scripts/parse-logdump.py` reads it.

## Building

Linux x86_64. On Fedora:

```sh
sudo dnf install -y python3 zip unzip dtc bc bison flex lz4 openssl-devel \
    gcc-arm-linux-gnu binutils-arm-linux-gnu android-tools e2fsprogs xz
```

On Debian/Ubuntu, `apt install python3 zip unzip device-tree-compiler bc bison flex lz4 libssl-dev gcc-arm-linux-gnueabi android-sdk-libsparse-utils e2fsprogs xz-utils`, set `CROSS_COMPILE=arm-linux-gnueabi-`, and build `lpmake`/`lpunpack` from AOSP `system/extras/partition_tools`.

The HWC also needs Android NDK r25 (`NDK=`, default `~/Android/Sdk/ndk/25.0.8775105`) and the VNDK-30 headers from the `vndk30.tar.gz` release asset, unpacked into `hwc/hdr/vndk30`.

```sh
./build-kernel.sh                         # out/kernel-gsi-release/kernel.img
./release-build/build-resource.sh         # release-build/resource-release-gsi.img
(cd hwc && ./build.sh)                    # vendor-changes/lib/hw/hwcomposer.rk30board.so

./build-android-images.sh <lineage-23.2-arm32_binder64-system.img[.xz]> inputs
./release-build/make-release.sh inputs <date>
scripts/make-magisk-boot.sh inputs/ramdisk.img Magisk-v31.0.apk boot-magisk-v31.img
```

`build-android-images.sh` takes the vendor and odm images from `inputs/super.img` or from the first zip in `release/`, so put a release zip there first.

## Layout

- `kernel/`, `kernel-configs/`: the kernel and its release / debug configs
- `hwc/`: the patched Rockchip HWC1 and its build; `hwc/test/` has the jank measurements
- `vendor-changes/`: every file this project changes in the Tinker Board vendor image
- `release-build/`: packaging, flash and rescue scripts, the device tree, the stock loader
- `scripts/`: image and Magisk helpers
- `stock-backup/`: the stock partition table and bootloader, for the rescue data
- `docs/`: release notes
