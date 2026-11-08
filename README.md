# iFive mini 4S (RK3288) — Android 16 port

Android 16 (TrebleDroid GSI) on the iFive mini 4S tablet: RK3288, 2 GB RAM, Mali-T760, 1536x2048 dual-DSI, Ricoh RC5T619 PMIC. Stock firmware was Android 6; the vendor image comes from the ASUS Tinker Board (RK3288) Android 11 firmware (fingerprint `asus/WW_Tinker_Board:11/RQ3A.210705.001`, chakaponden build 2022-11-06), not from stock.

The flashable package is on the Releases page: `ifive-mini4s-android16-gsi-rescue.zip`. Unzip, put the tablet into loader (maskrom), run `bash restore.sh` (bundled rkdeveloptool, Linux x86_64, needs libusb-1.0). It wipes /data; the first boot takes about 5 minutes and shows kernel text on the panel before Android starts.

## Release assets
- `ifive-mini4s-android16-gsi-rescue.zip` — the package (super td16n, kernel rl5bj, release resource, loader, flash.sh, rkdeveloptool).
- `stock-backup.tar` — raw dump of the original Android 6 partitions (gz, sha256-verified; userdata and cache not included).
- `hwc-hdr-vndk30.tar.zst` — prebuilt VNDK-30 link libraries used by `hwc/build.sh`.

## Usage

- Download `ifive-mini4s-android16-gsi-rescue.zip`
- bash restore.sh
- reboot

## Known issues
- Rare hard hang (screen freezes, USB gone); root cause not found. The release kernel writes a periodic dmesg dump to the kpanic partition for post-mortem.
- Native HWC2 port (drmhwc2) does not initialise on this VOP; the release uses the patched HWC1 through hwc2on1adapter.

## Screen*shot*s

<img height="300px" alt="PXL_20261108_175240621 jpg" src="https://github.com/user-attachments/assets/6c9ac10f-92d0-43e6-826b-8f162be20d14" />
<img height="300px" alt="PXL_20261108_175035032 jpg" src="https://github.com/user-attachments/assets/14219f6f-d90c-48e2-b879-8fb2313e87eb" />


## Layout
- `kernel/` — Linux 4.19 tree with all board changes (touch, bcmdhd Wi-Fi, audio, camera, RC5T619 charging policy + JEITA, lsm330, `rk_wdt_backstop` watchdog/logdump driver). Git history of this tree was lost; the tree is complete.
- `kernel-configs/` — `gsi-release.config` (the release kernel, BPF_JIT_ALWAYS_ON=y), `dev.config` (debug: watchdog, logdump).
- `hwc/` — Rockchip drm_hwcomposer 0.66: `src005` base, `src-a16` patched, `hwc-ifive.patch` (skip-layer mix policy + fence fix), `build.sh` (NDK r25), `checkso.py`, headers (`hdr/vndk30` prebuilt libs are a release asset).
- `vendor-changes/` — files changed inside the Tinker Board vendor image: `init.rk3288.rc` (charging service), `chgpolicy.sh`, Rockchip Power HAL + manifest, patched HWC `.so`.
- `release-build/` — packaging (`make-release.sh`, `guard-release.py`, `flash.sh.src`), release DTS and resource images, stock loader, `mkkrnl.py`, `resource_tool`, `dtc`, rkdeveloptool src.rpm.
- `scripts/` — developer flashing helpers and the kpanic ring parser.
- `reports/` — `FINAL-REPORT-2026-11-07.md` (Chinese, full write-up) and working notes.


## Building

Requirements: Linux x86_64, `python3`, `zip`/`unzip`, `dtc`, `bc`, `bison`, `flex`, `lz4`, `libssl-dev`, and an arm cross compiler. Fedora: `gcc-arm-linux-gnu` + `binutils-arm-linux-gnu` (default `CROSS_COMPILE=arm-linux-gnu-`); Debian: `gcc-arm-linux-gnueabi` (set `CROSS_COMPILE=arm-linux-gnueabi-`).

### Source components

```sh
./build-kernel.sh                          # -> out/kernel-gsi-release/kernel.img
./release-build/build-resource.sh          # -> release-build/resource-release-gsi.img (device tree + logos)
cd hwc && ./build.sh && cd ..              # -> vendor-changes/lib/hw/hwcomposer.rk30board.so
```

### Android system images (super.img)

The flash package requires a `super.img` containing `system`, `vendor`, and `odm` partitions:

#### Step 1: Obtain System Image (GSI)
Download the TrebleDroid Android 16 vanilla GSI (`arm32_binder64` / `a64`):
```sh
mkdir -p work && cd work
curl -sL -C - -o system.img.xz https://github.com/TrebleDroid/treble_experimentations/releases/download/ci-20250617/system-td-arm32_binder64-vanilla.img.xz
unxz system.img.xz
# If the uncompressed image is sparse, convert to raw:
simg2img system.img system.raw.img && mv system.raw.img system.img || true
cd ..
```

#### Step 2: Extract Vendor and ODM
Extract `vendor.img` and `odm.img` from the ASUS Tinker Board Android 11 firmware (or unpack an existing release `super.img`):
```sh
# Unpacking from an existing super.img:
lpunpack <path-to-super.img> work/unpacked/
```

#### Step 3: Patch Vendor Image
Apply hardware composer, power HAL, and battery charging policies from `vendor-changes/` into `vendor.img`:
```sh
./scripts/patch-vendor.sh work/unpacked/vendor.img work/vendor-patched.img
```

#### Step 4: Pack `super.img`
Generate `super.img` using `scripts/build-super.sh`:
```sh
./scripts/build-super.sh \
  work/system.img \
  work/vendor-patched.img \
  work/unpacked/odm.img \
  inputs/super.img
```
`<inputs>` holds `super.img`, `ramdisk.img`, `metadata.img`, `userdata-head-zero.img` and an optional `rkdeveloptool`; the release zip contains the same files for reference.
`make-release.sh` runs `mkkrnl.py verify` on the kernel and ramdisk, runs `guard-release.py` against the partition layout, and checks the zip with `unzip -t`.
