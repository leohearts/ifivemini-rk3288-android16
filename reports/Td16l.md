# Td16l: build24 stripped HWC on td16k, result: FAILED, reverted to td16k

- Stripped build24 HWC: `hwc/out2/hwcomposer.rk30board.stripped.so`, 547888 B, sha `cd2b0470...b1ab4b1`. Vendor slot is 134 blocks, so no growth was needed.
- `gsi/new/super-td16l.img` = td16k super with only the vendor extent (sector 2949120, 272384 sectors) replaced by `scratch/td16l/vendor-l.img`. Changed range 2949122..3221454 only. lpdump is identical to td16k. Sidecar verified.
- Flashed system-only (`--fullcmp`, no meta/udhead, /data not wiped). rc=0, rd rc=0. Log: `runs/fbfix/td16l-flash.log`.
- Boot: HWC loads (hwc-drm-two active). Composition fails: 339x `Vop3288: no plane for layer 3/4 (1536x2048)`, `TryAssignPlane crtc is NULL`. DRM state shows all planes `crtc=(null)`, fb=0, even with display ON. HWC does not bind a CRTC/plane.
- Per the assignment (HWC not composing), td16k super was re-flashed (rc=0, rd rc=0). Device boots; no `no plane` errors on td16k.
- Not done: the gsi16 zip was not rebuilt (its trigger was a PASS). `runs/fbfix/td16l_wake.png` was captured but not visually verified.
- Next: the CRTC/plane binding path in `drm/` for build24 (soc_id 0x3288 forcing) needs investigation before retrying.
