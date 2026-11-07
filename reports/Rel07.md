# Rel07: acceptance of ifive-mini4s-android16-gsi-2026-11-07.zip

## Fix (done per Main)
- release/build/flash.sh.src: guard now uses SYSTEM_SECTORS per LAYOUT (gsi=0x600000, a11=0x300000). Previously 0x300000 for both.
- Rebuilt with `make-release.sh gsi16`: GUARD OK (super 1650458624 B <= system 3072M), unzip -t OK, sha256 50c0efa4ee925d5b129b6db78dbc12f9a530ac4e6d84e698221bebfafe2ed688.
- The package checksum file is SHA256SUMS (inside zip). Build script writes that name, not SHA256SUMS.txt.

## Acceptance (from the new zip)
- Extracted; `sha256sum -c SHA256SUMS` OK.
- Maskrom via reset_loader; Loader 2207:320a seen.
- `flash.sh --yes`: all chunks CMP OK, FLASH COMPLETE, FLASH_EXIT=0. Log runs/rel07/flash.log. Flash plus readback took 240 s wall.
- First boot after wipe: adb device at ~466 s; sys.boot_completed=1 at 478 s from reset.
- Build: 16 (BP2A.250605.031.A3/250617), userdebug/test-keys.
- Brightness set to 20 (was 102). Home key sent after dismissing shade; focus result not captured.
- Battery temp raw 393 (39.3 C). ADP input_current_limit 500000 (both reads).
- Not checked / not captured: accelerometer (i2c denied), /proc/cmdline (denied), HWC hash, SurfaceFlinger layer count, wifi state, audio devices, visual touch check.

## Notes
- Earlier flash attempt (exit 3) wrote nothing; this flash was the first write with the fixed guard.
- scratch/rel07 deleted after check.
