# hwc/test - frame-drop measurements on the tablet

Host-side scripts; they drive the tablet over adb with `input` gestures and read
`dumpsys gfxinfo` / `dumpsys SurfaceFlinger --timestats`.

| script | what it measures |
|---|---|
| `real3.sh <outdir> <rounds>` | portrait recents, landscape app drawer, landscape notification shade: janky frames per scene, SurfaceFlinger missed and GPU-composed frames |
| `recset.sh <tag> <rounds>` | recents opened from Settings (rounded live tile): janky frames per round |
| `release-check.sh <outdir>` | acceptance run for a flashed package: build, kernel, HAL md5, Magisk, DDR rate, framebuffer count, tick broadcast device, tombstones, IOMMU faults, then `real3.sh` 8 rounds and `recset.sh` 3 rounds |

Run `release-check.sh` right after a boot, with the screen unlocked. Compare two HALs in the
same boot by bind-mounting the test `.so` over `/vendor/lib/hw/hwcomposer.rk30board.so` and
restarting `vendor.hwcomposer-2-1` and `surfaceflinger` before each arm.
