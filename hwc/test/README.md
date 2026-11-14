# hwc/test — A/B harness inputs

Device-side inputs consumed by `hwc/ab-test.sh` (pushed to `/data/local/tmp`).
Recreated 2026-11-12 after the original `hwc/test/` directory was lost; every
file below is byte-identical to a documented, still-existing source.

| file | md5 | role | source of these exact bytes |
|---|---|---|---|
| `halbase.so` | `b9fb394791788ec527945989baa959da` | stock, **unmodified** Rockchip HAL — the BASE arm of the A/B (`bind halbase.so`) | `vendor-changes/lib/hw/hwcomposer.rk30board.so`, which is the HAL inside the unspliced base super `out/inputs/super.img` (docs/inputs-provenance.md line 8: "the HAL inside is the old halbase"; verified today: `lpunpack` that super → `debugfs dump /lib/hw/hwcomposer.rk30board.so` → md5 `b9fb39…`) |
| `halstrip.so` | `6699bf1d15ca221f629fd99116c6bde2` | the **FIXED** strip-combine build (status bar + task bar share one VOP plane group) — the STRIP arm (`bind halstrip.so`) | `unzip -p release/ifive-hwc-composition-2026-11-12j.zip hwcomposer.rk30board.so`; `cmp`-identical to the HAL dumped out of the live-device super backup `/run/media/leohearts/Data/agentwork/lbam/supout/vendor.img` (`debugfs dump /lib/hw/hwcomposer.rk30board.so`, same ext4 UUID `64b0e109-…` as the packaged vendor) |
| `burst4.sh` | (text) | opens the shade 4x, prints `J=<jank%>` per burst and `MISSED_DIFF=<n>` (SurfaceFlinger missed-frame delta); harness greps `MISSED_DIFF\|^J=` | reconstructed; idioms (shade `input swipe 768 10 768 800 1400`, `dumpsys gfxinfo com.android.systemui reset`, `cmd statusbar collapse`) copied from the proven on-device predecessors `out/tmp/jankwork/{fullaccept,reload_hal,postboot}.sh` |
| `inject12.sh` | (text) | posts 12 notifications, prints `INJECTED=<actual count delta>`; harness requires ≥ 12 (`exit 4` otherwise) | reconstructed; primary post method string-verified in the GSI (see below) |
| `README.md` | (text) | this file | — |

## Why the vendor.img .so is halstrip, not halbase

The task brief assumed the extracted `supout/vendor.img` carries the stock HAL.
It does **not**: that image is the vendor partition of the **2026-11-12 GSI**,
which `release-build/make-release.sh` shipped with the fix already spliced in
(`docs/inputs-provenance.md`: `VENDOR_SO=hwc/test/halstrip.so
./release-build/make-release.sh out/inputs 2026-11-12`). The dump of that
vendor.img is byte-identical to the 12j module HAL (`6699bf…`), so it pins
halstrip. The true stock HAL is pinned independently by the **unspliced** base
super (`out/inputs/super.img`, sha256 `4a6d059e…`): its vendor contains
`b9fb39…`, which equals `vendor-changes/lib/hw/hwcomposer.rk30board.so` — the
same file `hwc/checkso.py` uses as the "vendor original" baseline. Same file
also sits in the untouched `out/super-work/vendor.img` and
`out/super-work/unpacked/vendor.img`; only the patched/identity stages
(`out/super-work/vendor-patched.img`, `out/super-work/identity/vendor.img`,
`out/tmp/jankwork/vendor.ext`) carry the intermediate jankwork build `a602d2…`.

## Full candidate .so ledger (measured 2026-11-12)

| md5 | file | identification |
|---|---|---|
| `b9fb394791788ec527945989baa959da` | `vendor-changes/lib/hw/hwcomposer.rk30board.so` | **halbase** (unmodified stock) |
| `6699bf1d15ca221f629fd99116c6bde2` | 12j zip / `lbam/supout/vendor.img` HAL | **halstrip** (fixed, released in GSI 11-12 + module 12j) |
| `a602d212de42466f5b157e5b03cbd554` | `out/tmp/jankwork/hwcomposer.rk30board.so` | intermediate jankwork-era build (in `vendor-patched`/`identity` stage images); not an A/B arm |
| `20f85d11a19738f6fe75a7c64623bfdb` | `hwc/out/hwcomposer.rk30board.so` | local `hwc/build.sh` output from 07:40, 370800 B, differs from 12j (371496 B) in 324775 bytes — older rebuild, NOT the released strip |
| `127b1134bd139e1b599a6d19529ace55` | `hwc/test/halrecon.so` | **halrecon** - strip-combine reimplemented from disassembly on src-a16, rebuilt (371K, 7/7 behavior strings + gate regs `vcmp.f32 s18,s20` match halstrip; diffs only in codegen/inlining). Evidence: lbam/scratch/rev-hwc/ANALYSIS.md |
| `553b27510629649761be2c863f17f578` | `hwc/test/halafbc.so` | **halafbc** - same patched source + `-DUSE_AFBC_LAYER=1` (372576 B; new strings "to set DRM_FORMAT_MOD_ARM_AFBC", is_afbc path). T7 experiment arm, NOT yet device-verified |

## Command availability audit (Android 16 GSI, system.img of 2026-11-12)

Confirmed by string/architecture evidence from the image (dumped via
`debugfs`, no root used):

- `dumpsys SurfaceFlinger` literal `Total missed frame count: ` — in `/system/bin/surfaceflinger`.
- `cmd notification post [flags] <tag> <text>` — help block (incl. `-t/-i/-S` flags) in `/system/framework/services.jar` dex; `notification` registered as cmd service.
- `expand-notifications` — string in services.jar (`com.android.server.statusbar.StatusBarShellCommand`); `cmd statusbar collapse` furthermore proven on-device by `out/tmp/jankwork/reload_hal.sh`.
- `/system/bin/{sh,dumpsys,input,cmd,atrace,logcat,am,settings,getprop}` exist; system image is 32-bit ARM (`/system/lib`, no `/system/lib64`).

Confirmed by prior on-device captures in `out/tmp/jankwork/`:

- `dumpsys gfxinfo com.android.systemui` line `Janky frames: 4 (3.88%)` (capture `out/tmp/jankwork/fs_after.txt:8`; t6.txt is pure atrace, it does not contain gfxinfo) and the `reset` verb (`fullaccept.sh`).
- top-edge `input swipe 768 10 768 800 1400` / reverse (`fullaccept.sh`, ran successfully — see `fullacc/jank.txt`).

Could NOT confirm, with the substitute used:

- **Reset of the SF missed-frame counter**: no reset verb exists in the SF
  binary (counter clears only when SF restarts). Used before/after delta →
  `MISSED_DIFF` instead.
- **The exact per-notification line format of `dumpsys notification` on this
  build** (only the section string `Active notifications: ` was found).
  `inject12.sh` prefers a numeric summary on that line, falls back to counting
  `Notification Record` lines (older format, unconfirmed here); if neither
  matches it prints `INJECTED=0` and the harness safely halts.
- **Pre-A15 positional `cmd notification post <tag|NULL> <id> <channel> <pkg>`**:
  absent from this services.jar — wired only as a secondary fallback branch
  (runs just if the A16 form returns non-zero).
- `cmd statusbar expand-notifications` was not exercised on-device (only
  `collapse` was); `burst4.sh` falls back to the proven swipe gesture whenever
  the cmd exits non-zero.

## Running the full matrix (device online)

```
cd /run/media/leohearts/Data/agentwork/ifivemini-rk3288-android16
MOD=ifive-hwc-composition-2026-11-12j.zip ./hwc/ab-test.sh
```

`ab-test.sh` pushes these inputs to `/data/local/tmp`, phase 0 checks a fresh
boot, phase 1 installs the module (`MOD=`, default 12j), phases 2–3 A/B
`halbase.so` vs `halstrip.so` with boost ON, phase 3 isolates `halstrip.so` at
a forced 198 MHz. Requires `adb` + `/debug_ramdisk/su` (Magisk in the GSI).

The `.so` inputs are large binaries and stay untracked (`.gitignore`); only
the scripts and this file are in git.

## Harness discipline (2026-11-13 evening, five dead A/B rounds to learn it)

- `burst5b.sh` / `inject12b.sh` are the loop-free variants (owner rule: no
  while/sleep scripts on the host or the device). burst5b spaces the
  expand/collapse animation with `ping -c N` because `cmd statusbar
  expand-notifications` RETURNS BEFORE THE ANIMATION FINISHES - without
  spacing every round collapses at ~3 frames and all numbers are garbage.
- `cmd notification post` MUST run at uid 2000. Under `adb root` NMS looks
  up package "root", throws NameNotFoundException in fixNotification, and
  silently drops every post while still printing "posting for user 0".
  Pattern: adb root only for setprop/stop/start, adb unroot, then inject.
- After any SF or framework restart the shade scene is dead: re-run
  WAKEUP + `wm dismiss-keyguard` + inject and gate on INJECTED>=12 AND
  a manual-swipe frame count > 5 before trusting any measurement.
- gfxinfo `reset` inside a per-round script means a cumulative read after
  the loop only shows the LAST round - collect the printed `J=` lines.

