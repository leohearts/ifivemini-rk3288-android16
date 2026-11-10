# iFive mini 4S (RK3288) — Android 16 port

Android 16 (TrebleDroid GSI) on the iFive mini 4S tablet: RK3288, 2 GB RAM, Mali-T760, 1536x2048 dual-DSI, Ricoh RC5T619 PMIC. Stock firmware was Android 6; the vendor image comes from the ASUS Tinker Board (RK3288) Android 11 firmware (fingerprint `asus/WW_Tinker_Board:11/RQ3A.210705.001`, chakaponden build 2022-11-06), not from stock.

The flashable package is on the Releases page: `ifive-mini4s-android16-gsi-<date>.zip` (latest release). Unzip, put the tablet into loader mode (`rkdeveloptool ld` answers `Loader`; an eMMC with no bootloader comes up as Maskrom instead, and that step needs RKDevTool or AFPTool on Windows - see the release README), run `bash restore.sh` (bundled rkdeveloptool, Linux x86_64, needs libusb-1.0). It wipes /data; the first boot takes about 5 minutes and shows kernel text on the panel before Android starts. `flash.sh --keep-userdata` replaces the system partitions without touching /data. `ifive-mini4s-android16-boot-magisk-v31.img`, published next to the zip, replaces the boot partition with a Magisk-patched one.

## Release assets
- `ifive-mini4s-android16-gsi-<date>.zip` + `.sha256` — the flashable package (super with the Android 16 GSI + patched Tinker Board vendor, release kernel, release resource, loader, `flash.sh`, `restore.sh`, `write-loader-head.sh`, bundled rkdeveloptool).
- `ifive-mini4s-android16-boot-magisk-v31.img` + `.sha256` — optional replacement for the boot partition (tool LBA 0x16000) with Magisk 31.0 patched in; built by `scripts/make-magisk-boot.sh`.
- `ifive-no-phh-su.zip` — Magisk module for tablets using that boot image: replaces the GSI's `/system/etc/init/su.rc` and `/system/bin/phh-su` with empty files, because the phh-su daemon it starts mounts itself over Magisk's su binaries. Built by `scripts/make-no-phh-su-module.sh`; see `scripts/magisk-install-data.sh` for the whole setup.
- `ifive-tracefs-perms.zip` — Magisk module for tablets whose `/vendor` predates the `chmod 0755 /sys/kernel/tracing` line in `init.rockchip.rc`: without it the directory stays `0700`, every renderer fork aborts on `trace_marker`, and no web page draws. Built by `scripts/make-tracefs-module.sh`.
- `stock-backup.tar.gz` — raw dump of the original Android 6 partitions (gz, sha256-verified; userdata and cache not included).
- `vndk30.tar.gz` — prebuilt VNDK-30 link libraries used by `hwc/build.sh`.

## Usage

- Download `ifive-mini4s-android16-gsi-<date>.zip`, unzip, `sha256sum -c <file>.sha256`
- `bash restore.sh` (or `bash flash.sh`)
- reboot

## Known issues
- Rare hard hang (screen freezes, USB gone); root cause not found. The release kernel writes a periodic dmesg dump to the kpanic partition for post-mortem.
- Native HWC2 port (drmhwc2) does not initialise on this VOP; the release uses the patched HWC1 through hwc2on1adapter.
- tracefs at `/sys/kernel/tracing` stays `drwx------` on this tablet, so an app zygote aborts when a renderer fork re-opens `trace_marker`: every Chromium/WebView app draws a black page. Repaired in `/vendor/etc/init/hw/init.rockchip.rc` (`chmod 0755`, post-fs-data) by `scripts/patch-vendor.sh`; `scripts/make-tracefs-module.sh` ships it as a Magisk module for older `/vendor`.
- `Settings.Global.restricted_networking_mode` was found set to 1, which firewalls every uid without `CONNECTIVITY_USE_RESTRICTED_NETWORKS`; user apps then get no default network from `ConnectivityService`, a browser reports `Failed to read DnsConfig` and fails every domain, while bionic-resolving apps keep working. Nothing on the tablet writes the key and its origin is unknown. Fix: `adb shell settings put global restricted_networking_mode 0` (survives reboot, no browser setting involved).

## Screen*shot*s

<img height="300px" alt="PXL_20261108_175240621 jpg" src="https://github.com/user-attachments/assets/6c9ac10f-92d0-43e6-826b-8f162be20d14" />
<img height="300px" alt="PXL_20261108_175035032 jpg" src="https://github.com/user-attachments/assets/14219f6f-d90c-48e2-b879-8fb2313e87eb" />


## Layout
- `kernel/` — Linux 4.19 tree with all board changes (touch, bcmdhd Wi-Fi, audio, camera, RC5T619 charging policy + JEITA, lsm330, `rk_wdt_backstop` watchdog/logdump driver). Git history of this tree was lost; the tree is complete.
- `kernel-configs/` — `gsi-release.config` (the release kernel, BPF_JIT_ALWAYS_ON=y), `dev.config` (debug: watchdog, logdump).
- `hwc/` — Rockchip drm_hwcomposer 0.66: `src005` base, `src-a16` patched, `hwc-ifive.patch` (skip-layer mix policy + fence fix), `build.sh` (NDK r25), `checkso.py`, headers (`hdr/vndk30` prebuilt libs are a release asset).
- `vendor-changes/` — files changed inside the Tinker Board vendor image: `init.rk3288.rc` (charging service), `init.rockchip.rc` (adds the `chmod 0755 /sys/kernel/tracing` on the post-fs-data trigger that keeps app renderer forks alive), `chgpolicy.sh`, Rockchip Power HAL + manifest, patched HWC `.so`.
- `release-build/` — packaging (`make-release.sh`, `guard-release.py`, `make-manifest.py`, `make-flash.py`, `flash.sh.src`, `README-gsi.md.tmpl`) and the rescue part (`make-restore.py`, `restore-full.sh.src`, `write-loader-head.sh.src`, `derive-layout.py`, `boards/ifive-mini4s.json`); the release DTS and resource image (`resource-release-gsi.dts`, `.img`, rebuilt by `build-resource.sh`); `tools/` (`mkkrnl.py`, `resource_tool`, `dtc`); `loader/RK3288UbootLoader_V2.30.10.bin`. The bundled `tools/rkdeveloptool` is copied into the package from the inputs directory at build time.
- `stock-backup/` — raw dump of the original Android 6 firmware, tracked in git (21 files, 709 MB): `bootloader-8M.bin` (eMMC sectors 0x0000..0x1FFF: idblock, `u-boot.itb`, the 8 loader-area parameter copies), `p1..p12-*.img.gz` per partition, `parameter-decoded.txt` (decoded parameter, the `tool LBA = raw − 0x2000` rule with its correction log), `backup.log`, `roundtrip.txt` (every partition read back and compared). `make-restore.py` derives `devices/<board>/{head-4M.bin, head-8M.bin, parameter-p1.img, parameter-loader.img}` from here, which is why a release's `head8_sha256` equals the sha256 of `bootloader-8M.bin`.
- `scripts/` — image build helpers used by `build-android-images.sh`: `patch-vendor.sh` (debugfs writes of `vendor-changes/`, with a byte-for-byte read-back check), `patch-identity.sh` (build.prop identity/fingerprint), `build-super.sh` (`lpmake`); the Magisk setup pair `make-magisk-boot.sh` (Magisk-patched boot partition) and `magisk-install-data.sh` (the /data-side steps that finish that install), which together install the modules built by `make-no-phh-su-module.sh` and `make-tracefs-module.sh`; plus the developer flashing helpers and the kpanic ring parser (`parse-logdump.py`).
- `reports/` — `FINAL-REPORT-2026-11-07.md` (Chinese, full write-up) and working notes.


## Building

Requirements: Linux x86_64, `python3`, `zip`/`unzip`, `dtc`, `bc`, `bison`, `flex`, `lz4`, OpenSSL headers, an arm cross compiler, plus the Android image tools `simg2img` `lpmake` `lpunpack` and the ext2 tools `debugfs` `e2fsck`.

```sh
# Fedora (lines below were run on fc45; android-tools provides lpmake/lpunpack/simg2img)
sudo dnf install -y python3 zip unzip dtc bc bison flex lz4 openssl-devel \
    gcc-arm-linux-gnu binutils-arm-linux-gnu android-tools e2fsprogs xz curl
# Debian / Ubuntu (set CROSS_COMPILE=arm-linux-gnueabi-)
sudo apt-get install -y python3 zip unzip device-tree-compiler bc bison flex lz4 \
    libssl-dev gcc-arm-linux-gnueabi android-sdk-libsparse-utils e2fsprogs xz-utils curl
```

On Debian/Ubuntu the package set above does not include `lpmake`/`lpunpack`; build them from AOSP `system/extras/partition_tools` (not verified on a Debian box). `build-android-images.sh` prints which tools it could not find before doing any work.

### Step 1: build kernel, device tree, and hardware composer

```sh
./build-kernel.sh                          # -> out/kernel-gsi-release/kernel.img
./release-build/build-resource.sh          # -> release-build/resource-release-gsi.img (device tree + logos)
cd hwc && ./build.sh && cd ..              # -> vendor-changes/lib/hw/hwcomposer.rk30board.so
```

### Step 2: build the Android images

```sh
./build-android-images.sh inputs
```

That single command downloads the TrebleDroid Android 16 `arm32_binder64` GSI
(`system-td-arm32_binder64-vanilla.img.xz`, HTTP 200 checked on 2026-11-08), reads
`vendor.img` and `odm.img` out of a reference `super.img` (searched in this order:
`inputs/super.img`, `out/release/ifive-mini4s-android16-gsi-rescue/images/super.img`,
the first zip in `release/`), applies `vendor-changes/` onto the vendor image, and
writes `inputs/{super,metadata,userdata-head-zero,ramdisk}.img`.
Intermediate files stay in `out/super-work/`; delete that folder to force a stage to redo.
`rkdeveloptool` is copied into the inputs directory from the previous package (or from PATH),
so the zip always bundles the binary that was used on this tablet.

Checked on 2026-11-08 by rebuilding into a scratch directory: the `system` and `odm` images this
produces are byte-identical to the ones inside the released `images/super.img`, and the patched
`vendor` holds the same 1042 files with the same modes, owners and SELinux labels (the image
bytes still differ, because rewriting a file moves its blocks and updates its timestamps).
`lpdump` of the new and the released `super.img` is identical.

The two stages are separate scripts, so you can also run them one at a time:

- `scripts/patch-vendor.sh <in.img> <out.img>` -- `debugfs` writes for
  `bin/chgpolicy.sh`, `bin/hw/android.hardware.power-service.rockchip`,
  `lib/hw/hwcomposer.rk30board.so`, `etc/init/hw/init.rk3288.rc`, `etc/vintf/manifest.xml`,
  each with the SELinux label and file mode the release expects, then `e2fsck -fn`.
- `scripts/build-super.sh <system> <vendor> <odm> <out>` -- `lpmake` with this board's
  layout: super name `system`, group `rockchip_dynamic_partitions`, device size
  1650458624 B, metadata 65536 x2, all three partitions readonly.

### Step 3: package the release zip

```sh
./release-build/make-release.sh inputs     # -> release/ifive-mini4s-android16-gsi-<date>.zip
```

`<inputs>` holds `super.img`, `ramdisk.img`, `metadata.img`, `userdata-head-zero.img` and an optional `rkdeveloptool`; the release zip contains the same files for reference.
`make-release.sh` runs `mkkrnl.py verify` on the kernel and ramdisk, runs `guard-release.py` against the partition layout, and checks the zip with `unzip -t`.
