# Hwc2Build report

## Build21 (linked, superseded)
- Compiled 36 objects. Output sha256 `96fb444b…90e64` (prefix only; full hash not recorded).
- Used dynamic tinyxml2 stub. Superseded by Build22.

## Build22 (linked, superseded)
- Switched to static tinyxml2 (`zz_tinyxml2.o`), replacing the `libtinyxml2.so` stub. Output sha256 `afc30344…a8216e9bc6` (prefix only).
- Superseded by Build24: link libs were not yet restored at this point.

## Build23 (blocked at link)
- Compile: completed. Link failed (`clang-14`, exit 1): `unable to find library -l:libbase.so`, `-l:libhidlbase.so`, `-l:libgralloctypes.so`, `-l:android.hardware.graphics.mapper@4.0.so`.
- Cause: the vendor/GSI lib directories the link searches were missing from the workspace.
- No output hash for build23. `hwc/out2/hwcomposer.rk30board.stripped.so` is left over from an earlier build and must not be cited as build23.
- FbconWake fix was not applied at this point (applied later, see below).

## Build24 (link succeeded)
- Link libs: extracted from `gsi/new/super-td16k.img` via `lpunpack` (`scratch/linklibs/unpacked/`). `hwc/vendorlib/` holds `libdrm.so`, `librga.so`, `libsync_vendor.so` (from vendor.img). `hwc/gsilib/` holds `libcutils`, `libutils`, `liblog`, `libui`, `libhardware`, `libbase`, `libhidlbase`, `libgralloctypes`, `android.hardware.graphics.mapper@4.0`, `libc++` (from system.img). `VENDOR_LIB` in `build-hwc2.sh` now points at `hwc/vendorlib`.
- Caveat: the GSI libs carry Android 36 ELF notes, not Android 11. Runtime ABI against the SDK 30 vendor is unverified.
- Compile: 0 errors. Output `hwc/out2/hwcomposer.rk30board.so`, 843008 bytes, sha256 `6a92cf5c11f3f5ccb1a4b1248c3e7db171071963d3fa38aaf2f97793bfb23d73`.
- `checkso.py`: `unresolved: 0`. NEEDED: libcutils libdrm liblog libui libutils libsync_vendor librga libhidlbase libgralloctypes android.hardware.graphics.mapper@4.0 libc++ libc libm libdl. The vendor baseline `super2/.../hw/hwcomposer.rk30board.so` no longer exists, so the NEEDED/undef diff vs vendor was skipped. `checkso.py` now tolerates that.
- Build22 sha (`afc30344…`) is superseded by Build24.

## FbconWake fix (applied, not yet verified on device)
- `drm/drmcrtc.cpp`: `#elif defined(RK3288)` branch forces `soc_id_=0x3288` on 4.4/4.19 when SOC_ID is missing (confirmed in `git diff`).
- `rockchip/platform/common/platform.cpp`: `case 0x3288:` registers `Vop3288` and `Hwc3288`.
- `Android.mk`: `ifneq ($(filter rk3288,…))` adds `LOCAL_CPPFLAGS += -DRK3288=1` (confirmed by read-back). `build-hwc2.sh` already passes `-DRK3288=1`.
- Not yet verified on device: `TryAssignPlane` success, `plane-0` leaving fbcon, `init_success_=0` gone. The open question from the report still applies: `runs/fbfix/fbfix_wake.png` shows the Android lock screen, and `fbfix_fixed.png` and `fbfix_now.png` are byte-identical. A direct panel check is needed.
