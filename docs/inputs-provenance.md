# out/inputs - provenance for release builds

Files here are the base inputs consumed by `release-build/make-release.sh`
(usage documented in that script's header). As of 2026-11-12:

| file | bytes | sha256 | what it is |
|---|---|---|---|
| super.img | 1650458624 | 4a6d059ef79b0c05ebc8b6d1b01ecba3dd31c591613f9e14523111eeccb718af | base GSI super: system = TrebleDroid a64_bvS (original download kept at out/super-work/system-td-arm32_binder64-vanilla.img.xz, 581,313,652 B; identity-patched copies at out/super-work/identity/), vendor = Tinker Board A11 vendor + vendor-changes/. **Unspliced**: the HAL inside is the old halbase (64-byte prefix search: halbase hit 1, halstrip hit 0, probed 2026-11-12); make-release.sh splices VENDOR_SO into its copy of this file at packaging time |
| ramdisk.img | 871346 | 59b84a0a4250c0934b528d9f0be86879cf5455dd6bf061c4596496af494bac29 | KRNL-packed boot ramdisk (release kernel config era) |
| metadata.img | 16777216 | 74e576de794b719ea825655368c95033aa72a181e62d1ae51f59d25fc1a56887 | empty formatted ext4, 16 MiB |
| userdata-head-zero.img | 1048576 | 30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58 | 1 MiB of zeros (clears the userdata superblock so init re-creates /data; skipped by flash.sh --keep-userdata) |
| rkdeveloptool | 138552 | 6d123c9a04bb181f5e9fca528260c6bbd4a8dc31868ffa9bf43850998a85b39a | bundled host tool (also shipped in tools/ of every release) |

Exact invocation that produced the published 2026-11-12 package
(kernel+resource from the repo build tree, HAL from the spliced vendor):

    VENDOR_SO=hwc/test/halstrip.so \
    ./release-build/make-release.sh out/inputs 2026-11-12

Result: release zip 803,810,273 B, sha256
f6b8b02d70bb36e561ada51ce264a548ad9e14f99a96808382707782b382d00a
(verified: guard-release.py OK, flash.sh --dry-run rc=0, unzip -tq clean,
two disk copies at -c OK; see docs/release-notes-2026-11-12.md).

out/inputs-20261110/ is the same file set as used for the 11-10
release, with a different super.img (07309e6b43ed39af... vs 4a6d059e...
here; the byte-level reason for the difference has not been analysed).
The 12:55 official build read from one of these two directories; the
exact invocation line was not logged (the later Data/rk-tc/inputs copy
mentioned in earlier notes no longer exists).


2026-11-13 package (ifive-mini4s-android16-gsi-2026-11-13.zip, sha256
05e3534c...): super/metadata/ramdisk/userdata-head-zero taken from the
retained build directory out/release/ifive-mini4s-android16-gsi-2026-
11-12/images (the Data/rk-tc/inputs directory was deleted externally
before this build). Verified chain: 11-12 super sha256 22ffdea7... ==
11-13 package super 22ffdea7...; both differ from the 11-10 release
zip super (4270e0d4...). The device under all 2026-11-13 measurements
runs the 22ffdea7 super set, so package == measured system. New
kernel.img 0efd778d... (CMA 128 MB config, kbase reset-return patch)
== the kernel image flashed and measured on the device today.
