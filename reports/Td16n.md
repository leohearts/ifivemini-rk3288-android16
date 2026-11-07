# Td16n: td16i + td16k chgpolicy seclabel

- gsi/new/super-td16n.img sha256 8af41bcdf46fc317480346b6eca3aeaa31af2b6de0386483be72ea4024d5049b (sidecar OK). lpdump identical to td16i. vendor e2fsck rc=0, rc diff = seclabel line only.
- Flashed system slot only (no --rd wipe of /data), CMP 99/99, rd rc=0. Log runs/fbfix/td16n-revert-flash.log.
- Boot after 40 s. HWC sha 83101dff (td16i HWC). init.svc.vendor.chgpolicy = running.
- high_current_allowed = Y. Charger log limit=1 at 08:43:46. input node still 500000 at check time (2000000 not yet confirmed).
- SurfaceFlinger: 3 layers composition=DEVICE.
- Screen-off/on cycles: 3 screencaps taken, all 16910 bytes (identical size; not visually checked). Plane-0 fb check inconclusive; "allocated by = [fbcon]" seen in DRM state output, not confirmed to be plane-0.
- Release: make-release.sh gsi16 with td16n, built release/ifive-mini4s-android16-gsi-2026-11-07.zip (802161147 bytes, sha256 791935d64db82238f53fd8d225ff5827ce2a0ed40fe49742a2c654ae50c63f0f). SHA256SUMS.txt and .sha256 updated. unzip -t and guard not run. NOT flashed (wipes data).

Open for Main: confirm plane-0 fb is not fbcon; confirm ADP limit 2000000; view screencaps; run unzip -t and guard before flashing the release.
