# LoaderRecov: RK3288 MaskROM loader recovery (2026-11-07)

## Result
- Primary (stock, verified): `release/build/loader/RK3288UbootLoader_V2.30.10.bin`
  - 399694 bytes, magic `BOOT`
  - sha256 `f1dcc699049dd0450c2b4d19de93af368233901d278df6d0a1628efbf1ad90cb`
  - Source: `runs/rel06e/a16-unpack/ifive-mini4s-android16-gsi-2026-11-06e/loader/RK3288UbootLoader_V2.30.10.bin`
  - Matches the sha prefix in the assignment and that run's `SHA256SUMS`.
  - Sidecar: `release/build/loader/RK3288UbootLoader_V2.30.10.bin.sha256`.
- Fallback (public rkbin, built here, NOT the tablet's stock image): `release/build/loader/rk3288_loader_v1.12.263.bin`
  - 209230 bytes, magic `BOOT`, sha256 `760291431e25b35d3d89c0c31f3607bcba2e72ebb386c4aef878458ece7d348e`
  - Built with `boot_merger` 1.38 from `RKBOOT/RK3288MINIALL.ini` (DDR `rk3288_ddr_400MHz_v1.12`, usbplug/miniloader `v2.63`).
  - Provenance and hashes in `release/build/loader/rk3288_loader_v1.12.263.bin.SOURCE`.
  - Copy also at `release/build/loader/rkbin/`.
  - NOT tested on hardware. Not run through `rkdeveloptool db`.

## rkbin sources (github.com/rockchip-linux/rkbin, master at fetch time)
| file | sha256 |
|---|---|
| bin/rk32/rk3288_ddr_400MHz_v1.12.bin | 6e9241e09aa6a12be37df5088e0efa1554f8ae6827939925b1aeba5b2e433d55 |
| bin/rk32/rk3288_miniloader_v2.63.bin | af23cd7259d4fb06965b3d661525ce0aff8c29c0fef0d3c8af227f50e228f92b |
| bin/rk32/rk3288_usbplug_v2.63.bin | 5e36a42499c4f9568234f076214d70c5e9cd047171a2262ad85c746cd76da743 |
| tools/boot_merger | f8e1a2d01bc475e9571ab0aec00e4cca3d85bbd4587f3873970560443a237d0c |

All HTTP 200.

## Scan (bins under 2 MiB across Data, $HOME, /tmp; BOOT/LDR magic)
- Hits: rel06e stock copy; `release/build/loader/` (stock copy); `release/build/loader/` and `loader/rkbin/` (rkbin build).
- Dangling `release/build/dryrun/tstage/loader/...` is a symlink into the deleted `rk3288-port-tmp`. Not a file. Ignore.
- No other copy found.

## Script edits (repointed off deleted `release/stage/loader`)
- `runs/wdt/wdt.sh:34`: `$R/release/stage/loader/...` → `$R/release/build/loader/RK3288UbootLoader_V2.30.10.bin`
- `release/build/make-release.sh:49`: `LOADER_SRC=/run/media/leohearts/Data/rk3288-port-tmp/.../p7.512k.bin.dump/...` → `LOADER_SRC=$R/release/build/loader/RK3288UbootLoader_V2.30.10.bin`
- `release/build/make-release.sh:62` (`cp $LOADER_SRC ...`) unchanged.
- `release/build/flash.sh.src:36` uses a relative path; unchanged.
- Historical `release/build/dryrun/*` outputs left as-is.

## (c) eMMC note
- `rk3288-backup/bootloader-8M.bin` (+ .gz) is a raw dump of the first 8 MiB of eMMC. The idblock sits at sector 64 in RK idb format (DDR + usbplug/miniloader).
- `boot_merger` cannot rebuild a `.bin` from it directly. Recovering a usable `.bin` from it needs a separate extraction step. Not attempted.
