# iFive mini 4S — Android 16 GSI release 2026-11-15 (LineageOS 23.2)

Assets:
- `ifive-mini4s-android16-gsi-2026-11-15-lineage232.zip` — the full package (flash.sh, restore.sh,
  write-loader-head.sh, rescue data), generic boot ramdisk, no Magisk.
- `ifive-mini4s-android16-boot-magisk-v31.img` (+ `.sha256`) — optional Magisk 31.0 boot partition,
  written instead of `images/ramdisk.img` at tool LBA `0x16000` (see "Magisk root" in the package
  README).

Built from a clean checkout of branch `release-2026-11-15-r2`:

```sh
./build-kernel.sh gsi-release
SYSTEM_NAME="LineageOS 23.2 GSI, 23.2-20260620-VANILLA-EXT4-GSI" \
  release-build/make-release.sh <inputs-lineage> 2026-11-15-lineage232
scripts/make-magisk-boot.sh <inputs-lineage>/ramdisk.img Magisk-v31.0.apk ifive-mini4s-android16-boot-magisk-v31.img
```

Inputs: the LineageOS 23.2 super of the 2026-11-09 package (2037186560 B), its ramdisk
(sha256 `59b84a0a...`), Magisk 31.0 (APK sha256 `2c8a488b...`). The Magisk image (sha256
`004d4b45...`) is byte-identical to the one published with the 2026-11-08 release. The vendor
region of super carries `vendor-changes/`; the guard checks every file of it inside the packaged
image. `release-build/resource-release-gsi.img` rebuilt from its DTS is byte-identical to the
committed one; the HAL rebuilt from `hwc/src-a16` is byte-identical to
`vendor-changes/lib/hw/hwcomposer.rk30board.so` (md5 `9d36db12`).

## What changed since commit 97321b36

One commit per change, in this order: chunked/resumable flashing, vendor-changes + Magisk
packaging, 128 MiB CMA + Mali reset fix, DDR frequency driver (456 MHz after boot), RK3288
timer as tick broadcast device, seven HWC changes (status bar + task bar in one VOP window,
framebuffer cache, debug strings only when logging, no per-frame TEST_ONLY commit, no plane
for alpha-0 layers, RGA pre-rotation of one RGB layer with reuse, mix-down of unchanged bottom
layers), three client-target buffers. Each commit message carries its own A/B measurement.

## Acceptance (same tablet, `/data` kept, flashed with `flash.sh --keep-userdata`)

Base = package built from commit 97321b36 with the same LineageOS super. Both base and this
release were measured with the Magisk boot partition above written (the release package with
the generic ramdisk was flashed and booted separately, see below).
Both measured by `hwc/test/release-check.sh` right after a boot, two runs each, no
composer/SurfaceFlinger restart. Janky = launcher3/systemui gfxinfo janky frames.

| Scene | Base | This release |
|---|---|---|
| Gallery launch + HOME, 5 times: janky / SF missed | 48.1%, 41.8% / 479, 455 | 33.4%, 35.7% / 371, 384 |
| Portrait recents, 8 rounds: janky / SF missed | 23.5%, 21.9% / 54, 236 | 20.3%, 20.9% / 0, 47 |
| Landscape app drawer, 8 rounds: janky | 88.2%, 85.5% | 66.3%, 69.3% |
| — GPU-composed frames / SF missed | 318, 319 / 382, 386 | 0, 0 / 14, 2 |
| Landscape notification shade, 8 rounds: janky | 82.6%, 82.7% | 53.4%, 53.7% |
| — GPU-composed frames / SF missed | 404, 400 / 513, 487 | 0, 0 / 79, 105 |
| Recents opened from Settings, 3 rounds x 2 | 84.6-87.8%, 78.9-85.7% | 25.5-32.9%, 23.0-29.6% |

The release package itself (generic ramdisk) was flashed with `flash.sh --yes --keep-userdata`
and booted: HAL `9d36db12`, DDR 456 MHz, no Magisk. Writing the Magisk image afterwards with
`tools/rkdeveloptool wl 0x16000` (read back and compared) gave a boot with `su -c id` answering
`uid=0(root) ... context=u:r:magisk:s0` and `magisk -v` 31.0.

Device state measured on this release: kernel 4.19 built 2026-11-15, HAL `9d36db12`,
DDR 456 MHz, `ro.surface_flinger.max_frame_buffer_acquired_buffers=3`, broadcast device
`rk_timer`, Magisk 31.0 with `su` working. During both runs and after a screen off/on: no IOMMU
page fault, no HWC commit failure, no new tombstone or crash-buffer FATAL.

## Known remaining jank

The landscape app drawer still drops about two thirds of its frames: launcher3 clips every
themed icon to the "7-sided cookie" shape on the CPU (Skia disables GPU path rendering on
Mali-T) and uploads it each frame. Measured: circle shape 77% -> 20%, themed icons off
73% -> 19%. The fix belongs in launcher3, not in this package.
