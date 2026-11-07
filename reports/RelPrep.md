# RelPrep: make-release.sh audit, gsi16 dry check (2026-11-07)
## Inputs (R=/run/media/leohearts/Data/rk3288-a11)
- gsi16 SUPER gsi/new/super-td16i.img (sidecar ok); swap-in var: td16j.img (sidecar ok, sha ok). Script still points at td16i; change in make-release.sh gsi16 case.
- gsi16 kernel work-rl5/kernel-release-rl5bj.krnl: exists, sidecar ok. Script line correct; mkkrnl.py verify NOT runnable (/tmp/rk3288-port/scripts/mkkrnl.py missing).
- resource release/build/resource-release-gsi.img: exists, sidecar ok.
- gsi16 SRC scratch/acc6/ifive-mini4s-android16-gsi-2026-11-06: only images/ramdisk.img survives. No system/vendor/flash.sh -> package tree NOT buildable.
- gsi12 SUPER gsi/super-gsi13.img: MISSING. gsi12 SRC: only ramdisk.img. NOT buildable.
- a11: super2/super18f/super18f.img MISSING; out/mk-ramdisk.krnl MISSING; loader in /run/media/.../rk3288-port-tmp (deleted) MISSING; mkkrnl.py MISSING. NOT buildable.
- gsi/metadata-16M.img, gsi/zero-1M.img, release/build/flash.sh.src, guard-release.py, tools/{resource_tool,dtc}: present (no sidecars on the .img pair; not required by script).
- Scripts did not reference any w7 tree; no gsi/w7 found.

## Dry guard (gsi16, td16j + resource-release-gsi.img), no zip made
- super td16j 1650458624 B <= system 3072M: OK. SUPER_LBA 0x92000 OK.
- FAIL: flash.sh.src META_LBA=0x392000 (A11 layout, 1834M) vs GSI resource needs 0x692000 (3368M). The gsi path must ship a GSI-specific flash.sh (none exists in the GSI tree); make-release.sh copies $SRC/ which has no flash.sh, so it would fail anyway.
- lpdump td16i vs td16j: group max 1649410048 B both, unchanged; vendor 271992 -> 272384 sectors (+392 = 196 KiB); odm/system unchanged; no overlap.

## Needed for gsi16
1. GSI flash.sh with META_LBA=0x692000, UD_LBA per resource (3448M -> 0x6B8000 check via guard), SUPER 0x92000.
2. Full GSI package tree (system/vendor/... images + flash.sh) for scratch/acc6/...android16-gsi-2026-11-06 — not on disk.
3. mkkrnl.py restored for kernel verify.
## a11 / gsi12: NOT buildable. Need super18f (a11) / super-gsi13 (gsi12) rebuilt, out/mk-ramdisk.krnl, loader, and gsi12 package tree.
