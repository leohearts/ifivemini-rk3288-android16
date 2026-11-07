# Hwc2Crtc: plane→CRTC binding with soc_id 0x3288 forced (build24)

## Status
Root cause narrowed, not confirmed. No source edit made. No `.so` rebuilt (no change to build).

## Binding path (verified by reading source)
- Planes get `current_crtc_` only in `Hwc3288::assignPlaneByPossibleCrtcs` (`rockchip/platform/rk3288/drmhwc3288.cpp:50-51`), via `set_current_crtc(crtc_mask, display_id)`. The mask test is full-subset (`:50`).
- `Hwc3288::TryAssignPlane` (`drmhwc3288.cpp:62-74`) only logs `crtc is NULL` (`:69`) and then calls the same assign function.
- `TryAssignPlane` has exactly two callers in `drm/drmdevice.cpp`:
  - `BindDpyRes` line 1940, after CheckConnectorState (1921), FindAvailableCrtc (1928), and BindConnectorAndCrtc (1934). Each of those returns early on error, so TryAssignPlane is skipped.
  - `ReleaseDpyRes` line 2022, after `ReleaseDpyResByNormal` has set the CRTC display to -1 (`:2191`) and reset plane groups (`:2204`, `drmplane.h:119-124`). The `crtc is NULL` lines come from here and are expected.
- Frame-time `Vop3288::MatchLayer` (`drmvop3288.cpp:53`) skips every group with `!(current_crtc_ & crtc_bit)`. That yields `no plane for layer` (339x, Td16l.md:6) when the groups are zero.

So: after a release, the groups are zero. They are re-set only by a successful power-on `BindDpyRes` (`drmhwctwo.cpp:2565`). `SetPowerMode` ignores that failure. Build24 shows display ON with all planes `crtc=(null)`, which points to power-on `BindDpyRes` failing before line 1940.

## Candidate early returns on power-on (not yet proven)
- `CheckConnectorState` (`drmdevice.cpp:1423-1432`): connector not `DRM_MODE_CONNECTED`.
- `FindAvailableCrtc` (`:1437-1470`): ByFirst needs `can_bind` (`drmcrtc.cpp:438-440`) and encoder `possible_crtcs`.
- `BindConnectorAndCrtc` (`:1622-1745`): `-EINVAL` at 1641 if `current_mode().id()==0`; atomic commit failure at 1719-1723.

## Discriminating evidence still missing
The build24 raw log is not in `runs/` or `/tmp/rk3288-port`. `grep` for `Bind Connector-id|Failed to commit pset|current-id is invalid|crtc is NULL|no plane for layer` found only build22 `fbfix` logs and `hwc16` strings. The first failing line after power-on identifies the branch:
- `display-id=0 connector state is disconnected` → CheckConnectorState
- `Failed to find display-id=0 CRTC`/`connected-no-crtc` → FindAvailableCrtc
- `display-id=0 conn-id=… current-id=0 is invalid` or `Failed to commit pset ret=…` → BindConnectorAndCrtc

## Checks for Main (device, after next flash)
1. `logcat -d | grep -E "Bind Connector-id|Failed to commit pset|current-id=0|connector state is disconnected|connected-no-crtc|TryAssignPlane"` — the first failure after `SetPowerMode` ON names the branch.
2. `getprop vendor.hwc.device.display-0` after power-on: `connected-no-crtc` means FindAvailableCrtc failed; `…:connected` means bind succeeded and the planner step failed.

## Not a root cause
- Planner selection (`platform.cpp:32-34, 67-69`): soc 0x3288 registers Vop3288/Hwc3288 correctly.
- The mask test differs from RK3399 (`drmhwc3399.cpp:59`, overlap vs. subset). Overlay planes report `possible_crtcs=1<<0` (`rockchip_drm_vop.c:4420-4425`), so the subset test passes them. Not the cause for overlays.
- soc_id force (`drm/drmcrtc.cpp:162-166`) is needed and kept.

## Suggested fix once the branch is known
Only the failing branch needs a change. Likely candidates: connector mode id 0 after PowerDown (fix mode refresh before bind), or CRTC not reclaimed (`can_bind`/`possible_crtcs`). Do not add a planner-side fallback; it would hide the bind failure.
