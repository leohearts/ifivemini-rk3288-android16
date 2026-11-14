# iFive mini 4S (RK3288) — Android 16 port

LineageOS 23.2 (Android 16 GSI, arm32_binder64) on the iFive mini 4S tablet: RK3288, 2 GB RAM, Mali-T760, 1536x2048 dual-DSI, Ricoh RC5T619 PMIC. The stock firmware was Android 6; the vendor partition comes from the ASUS Tinker Board (RK3288) Android 11 firmware (`asus/WW_Tinker_Board:11/RQ3A.210705.001`, chakaponden build 2022-11-06).

## Release assets
- `ifive-mini4s-android16-gsi-<date>-lineage232.zip` + `.sha256`: the flashable package (super, kernel, resource, boot ramdisk, loader, per-board rescue data, `flash.sh`, `restore.sh`, `write-loader-head.sh`, bundled `rkdeveloptool`). Its `README.md` is the flashing guide.
- `ifive-mini4s-android16-boot-magisk-v31.img` + `.sha256`: the boot partition with Magisk 31.0, written at tool LBA 0x16000.
- `vndk30.tar.gz`: VNDK-30 link libraries used by `hwc/build.sh`.

## Usage
1. Unzip the package, `sha256sum -c SHA256SUMS`.
2. Put the tablet in download mode: power it off, hold Volume Down and plug in the USB cable.
3. A tablet on the stock Android 6 firmware, or a wiped one: `./restore.sh`. It writes the GSI partition table first; the stock table gives `system` 1536 MiB, too small for this super image.
4. A tablet already running a package from this repository: `./flash.sh --yes` (`--keep-userdata` keeps `/data`).

## Screenshots

<img height="300px" alt="PXL_20261108_175240621 jpg" src="https://github.com/user-attachments/assets/6c9ac10f-92d0-43e6-826b-8f162be20d14" />
<img height="300px" alt="PXL_20261108_175035032 jpg" src="https://github.com/user-attachments/assets/14219f6f-d90c-48e2-b879-8fb2313e87eb" />

## Layout
- `kernel/`: Linux 4.19 tree with the board changes (touch, bcmdhd Wi-Fi, audio, camera, RC5T619 charging policy + JEITA, lsm330, RK3288 DDR frequency driver, `rk_wdt_backstop` watchdog/log dump).
- `kernel-configs/`: `gsi-release.config` (release kernel), `dev.config` (debug kernel with watchdog and log dump).
- `hwc/`: Rockchip drm_hwcomposer 0.66 for HWC1, patched (`src-a16`), `build.sh` (NDK r25), `checkso.py`, headers and link libraries; `hwc/test/` holds the frame-drop measurements.
- `vendor-changes/`: files replaced in the Tinker Board vendor image: `init.rk3288.rc`, `chgpolicy.sh`, Rockchip Power HAL + VINTF manifest, HWC `.so`, `build.prop`.
- `release-build/`: packaging (`make-release.sh`, `guard-release.py`, `flash.sh.src`, `restore-full.sh.src`, `write-loader-head.sh.src`), release DTS and resource image, stock loader, board rescue definitions, `mkkrnl.py`, `resource_tool`, `dtc`, `rkdeveloptool`.
- `scripts/`: image build helpers (`patch-vendor.sh`, `patch-identity.sh`, `build-super.sh`), Magisk (`make-magisk-boot.sh`, `magisk-install-data.sh`), `parse-logdump.py` (kpanic log dump reader), `restore-symlinks.py`.
- `stock-backup/`: the stock p1 parameter partition and the first 8 MiB of the eMMC (bootloader), used for the rescue data in the package.
- `docs/`: release notes.


## Changes for this tablet
Kernel (Linux 4.19):
- DDR frequency driver ported from the ChromeOS 4.19 RK3288 DMC; the memory runs at 456 MHz after boot instead of the loader's 396 MHz. Notification-shade janky frames 42-43% -> 34%.
- RK3288 timer enabled as tick broadcast device, so high-resolution timers work. SurfaceFlinger missed frames per 72 s test 423-733 -> 0-44.
- 128 MiB CMA and the Mali power-on reset fix.
- Board drivers: touch, bcmdhd Wi-Fi, audio, camera, RC5T619 charging policy + JEITA, lsm330, watchdog with a kernel log dump to `kpanic`.

Display composition (Rockchip HWC1, `hwc/src-a16`):
- Landscape wallpaper rotated once by RGA and shown on a VOP window. Landscape app drawer: GPU-composed frames 383 -> 0, janky frames 68-71% -> 44-47%.
- Unchanged bottom layers go into the client target when layers outnumber VOP windows. Landscape shade janky frames 72-74% -> 47-50%.
- Status bar and task bar in one VOP window, with every layer of a window group checked for shared scanlines (this fixed vertical stripes and a black panel after screen off/on).
- Per-frame TEST_ONLY commit removed; framebuffers cached by gralloc buffer id; debug strings built only when logging.

Vendor partition (`vendor-changes/`):
- `ro.surface_flinger.max_frame_buffer_acquired_buffers=3`. Recents opened from an app: janky frames 78-84% -> 43-47%.
- Rockchip Power HAL, charging policy service (`persist.vendor.chg.boost`), 456 MHz DDR switch in `init.rk3288.rc`.
- `build.prop` identity: iFive mini 4S.

Flashing: `flash.sh` and `restore.sh` write in verified pieces, resume an interrupted flash, and restore a tablet with an erased partition table or a blank eMMC.


## Building

Requirements: Linux x86_64, `python3`, `zip`/`unzip`, `dtc`, `bc`, `bison`, `flex`, `lz4`, OpenSSL headers, an ARM cross compiler, `simg2img`, `lpmake`, `lpunpack`, `debugfs`, `e2fsck`.

```sh
# Fedora (android-tools provides lpmake/lpunpack/simg2img)
sudo dnf install -y python3 zip unzip dtc bc bison flex lz4 openssl-devel \
    gcc-arm-linux-gnu binutils-arm-linux-gnu android-tools e2fsprogs xz
# Debian / Ubuntu (set CROSS_COMPILE=arm-linux-gnueabi-; lpmake/lpunpack come from AOSP system/extras/partition_tools)
sudo apt-get install -y python3 zip unzip device-tree-compiler bc bison flex lz4 \
    libssl-dev gcc-arm-linux-gnueabi android-sdk-libsparse-utils e2fsprogs xz-utils
```

### 1. Kernel, device tree, HWC

```sh
./build-kernel.sh                          # -> out/kernel-gsi-release/kernel.img
./release-build/build-resource.sh          # -> release-build/resource-release-gsi.img
cd hwc && ./build.sh && cd ..              # -> vendor-changes/lib/hw/hwcomposer.rk30board.so
```

### 2. Android images

```sh
./build-android-images.sh <lineage-23.2-gsi-arm32_binder64-system.img[.xz]> inputs
```

The script takes the LineageOS GSI system image, reads `vendor.img` and `odm.img` from a reference `super.img` (`inputs/super.img`, or `images/super.img` of the first zip in `release/`), writes `vendor-changes/` into the vendor image (`scripts/patch-vendor.sh`), writes the tablet identity into system and vendor (`scripts/patch-identity.sh`), packs `inputs/super.img` (`scripts/build-super.sh`: group `rockchip_dynamic_partitions`, device size 2037186560 B, metadata 65536 x2) and fills `inputs/{metadata,userdata-head-zero,ramdisk}.img`. Intermediate files are in `out/super-work/`.

### 3. Package

```sh
./release-build/make-release.sh inputs <date>
scripts/make-magisk-boot.sh inputs/ramdisk.img Magisk-v31.0.apk boot-magisk-v31.img
```

`make-release.sh` copies `vendor-changes/` into the vendor region of `super.img`, checks every vendor file against `vendor-changes/`, runs `mkkrnl.py verify` on the kernel and ramdisk, `guard-release.py` on the partition layout, and `unzip -t` on the zip.
