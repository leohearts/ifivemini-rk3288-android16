# Measurements on 2026-11-10 (device serial/adb id `RK3288IFIVE01`)

All commands below were run on this tablet with the current Android 16 GSI release flashed.
Nothing here writes a partition. Two device settings were changed, both reversible, listed at the end.

## 1. Browser resolves no name at all, other apps keep working

**Root cause: `Settings.Global.restricted_networking_mode = 1`.** This is Android 12+ restricted
networking mode (`NetworkPolicyManagerService.isRestrictedModeEnabled()` reads that key): every uid
that does not hold `CONNECTIVITY_USE_RESTRICTED_NETWORKS` is firewalled. Observed state before the
change:

```
dumpsys netpolicy            Restricted networking mode: true
                             UID=10040 policy=262144 (REJECT_ALL)   (and 10041, 10046, 10051, ... )
                             UID=10045 policy=4 (ALLOW_METERED_BACKGROUND)     <- whitelisted
per-uid line for the browser's uid 10132:
  state={procState=TOP,seq=...,cap=--------I}
  blocked_state={blocked=RESTRICTED_MODE|APP_BACKGROUND,allowed=NONE,effective=RESTRICTED_MODE|APP_BACKGROUND}
same lines for uid 1000/1001/1002/1073: allowed=RESTRICTED_MODE_PERMISSIONS, effective=NONE
settings list global         restricted_networking_mode=1
                             uids_allowed_on_restricted_networks=(empty)
```

`262144` is `RULE_REJECT_ALL` and `4` is `RULE_ALLOW_METERED_BACKGROUND`, so the labels in the dump
are self-consistent. 201 uid entries carried `RESTRICTED` in `effective` and 162 had `NONE`: the
blocked group is exactly the third-party apps.

Chromium then reports no resolver at all - `logcat` shows `Failed to read DnsConfig` and every
navigation fails immediately with `ERR_NAME_NOT_RESOLVED`. Apps that resolve through bionic's
resolver (which asks netd, not `ConnectivityManager`) are unaffected, so the fault looks
browser-specific.

**Fix**, one command, nothing in the browser touched:

```sh
adb shell settings put global restricted_networking_mode 0
```

**Verified after the fix** (identical protocol: force-stop Cromite, launch, open the site, screenshot):

| | before | after |
|---|---|---|
| `https://example.org` | `ERR_NAME_NOT_RESOLVED` | page drawn, six languages of body text |
| `https://github.com` | `ERR_NAME_NOT_RESOLVED` | signed-in home page, images drawn |
| `Failed to read DnsConfig` | on every navigation | 0 occurrences over the three-site run |
| per-uid `effective` for 10132 | `RESTRICTED_MODE` | `APP_BACKGROUND` only (while backgrounded) |
| after a reboot | - | key still `0`, `Restricted networking mode: false`, so no boot script is needed |

**What is proven and what is not.** Proven by before/after on the real browser process: the key at
1 blocks it, the key at 0 unblocks it. Not proven: which exact framework call inside Chromium
returns nothing. A helper process launched as `app_process` under uid 10132 returned
`ConnectivityManager.getActiveNetwork() -> null` at `procState=TOP` (7 samples, 1 s to 25 s after a
cold start, window focus on `org.cromite.cromite/com.google.android.apps.chrome.Main`) while
uid 0, 1000, 2000 and 10094 all returned network 100 - but that same helper still returned null
after the fix while the browser already worked, so the helper is not a faithful model of an app
process and its null is `[INFERENCE]` only.

**Who set the key to 1: not found.** No match for the name in `/data/adb/service.d`,
`/data/adb/post-fs-data.d`, `/data/adb/service`, `/data/adb/boards.d`, `/data/adb/modules`,
`/system/bin`, `/system/xbin`, `/system_ext/bin`, `/vendor/bin`, `/odm/bin`, `/system/etc`,
`/system_ext/etc`, `/vendor/etc`, `/odm/etc`. `settings_global.xml` is ABX (binary), so it cannot be
grep'd as text; read the values with `settings list global` instead.

**Third test site.** `dromaius.com` (a name from my own notes) has no address record anywhere, so it
is not usable as a browser test target: `dig A/AAAA` empty with a SOA present, and
`https://dns.google/resolve?name=dromaius.com&type=A` and the Cloudflare equivalent both return
`Status: 0` with no `Answer`; `.org/.io/.dev/.me/.xyz/.cn` are `Status: 3` (NXDOMAIN). The device
agrees through libc: `ping: unknown host dromaius.com` at the same moment `ping example.org`
resolved to 172.66.157.237. Substituted with the site from the GitHub profile,
`https://leohearts.com`, which draws fully.

## 2. Where the pull-down shade time goes (measured; no fix available from this repository)

Reproducible measurement, run twice with the same result: 12 pull-down/close cycles driven by
`input swipe 768 12 768 950 350` + `input swipe 768 950 768 12 250`, counters read from
`dumpsys gfxinfo com.android.systemui` before and after each burst.

```
run 1: new frames 297, new janky 261  -> 87.9%
run 2: new frames 336, new janky 302  -> 89%
frame budget: FrameInterval 16.76 ms (median/mean/p90 identical -> a steady 60 Hz panel,
              renderFrameRate 60.000004, 1536x2048 @240 dpi)
```

`framestats` over 236 frames of the same gesture, medians of adjacent timestamp columns:

```
HandleInputStart -> AnimationStart            5.3 ms
AnimationStart   -> PerformTraversalsStart     3.4 ms
PerformTraversalsStart -> DrawStart            7.6 ms
DrawStart -> SyncQueued (main thread -> render thread queue)
SyncQueued -> SyncStart                        4.4 ms
SyncStart -> IssueDrawCommandsStart            0.5 ms
IssueDrawCommandsStart -> SwapBuffers          5.0 ms
SwapBuffers -> FrameCompleted                 25.5 ms   (p90 90.4 ms)
DequeueBufferDuration                        0.05 ms median, 9.7 ms p90, 63.6 ms max
QueueBufferDuration                          0.84 ms median
HandleInputStart -> CommandSubmissionCompleted 35.5 ms median  = 2.1 frame budgets on the app side alone
```

Per-core load during the burst: `cpu0 30.2% cpu1 30.7% cpu2 29.0% cpu3 37.0%`, iowait ~0.
SystemUI thread CPU over the same burst (from `/proc/<pid>/task/*/stat` deltas):

```
main thread (ndroid.systemui)  8150 ms  -> ~25 ms CPU per frame, over one core
RenderThread                   3110 ms  -> ~10 ms per frame
HeapTaskDaemon                 2620 ms  (GC during the gesture)
mali-mem-purge  + mali-cmar-backe 1480 ms
```

So it is one thread (SystemUI's main thread) over the 16.76 ms budget, not total CPU: a single
saturated core reads as ~25-30% of four cores, which is what was measured. The GPU is not the
limiter: raising it changed nothing - `min_freq` 198 MHz -> 594 MHz gave 87% -> 87% janky, and
`governor=performance` gave 84% (`/sys/class/devfreq/ffa30000.gpu`, governor default
`simple_ondemand`, available 594/384/297/198 MHz, no sysfs tunables for that governor, and no
`devfreq` writer anywhere in `/vendor/etc/init` or `/vendor/bin`). `sysui_tint_based_fog_effect_enabled=0`
changed nothing either (89% -> 88%), although that test cannot prove SystemUI reads the key.
All of these were reverted; the device was left at `governor=simple_ondemand`,
`min_freq=198000000`, and the fog key back to `null`.

**Interleaved repeat of the one candidate that looked promising.** The first single run of
`debug.sf.auto_latch_unsignaled=1` showed 71%, below a control of 89%, which is exactly the kind of
difference a run-to-run spread of this size can invent. Repeated with the order C T C T C T and a
SurfaceFlinger restart before every cycle (each run is a fresh counter set):

```
control (unset): 88%  84%  67%      mean 79.7%   main thread 24/20/20 ms per frame
latch=1        : 83%  87%  84%      mean 84.7%   main thread 17/23/23 ms per frame
```

The treated mean is not better than the control mean, and the two ranges overlap. **No effect** - the
71% was noise. Same verdict for the GPU and the fog key.

**The one thing that does move the number: fewer pixels per frame.** Applied with the override
verified first (`wm size` printing `Override size: 1152x1536`, `wm density` printing
`Override density: 180`, `dumpsys window displays` showing `cur=1152x1536`):

```
native 1536x2048/240 : 87% (W0)  88% (W3)  87% (S3)      <- brackets before and after
reduced 1152x1536/180: 76%  79%  80%  82%                <- 76 and 79 from the earlier run
```

Four treated samples all below three control samples, about eight points. So the per-frame pixel
count times the main-thread cost is the mechanism, which is what the framestats breakdown said.
It does not come close to fixing the gesture (still >75% janky) and it softens the panel, so nothing
in the release enables it; `wm size reset` and `wm density reset` undo it, and the tablet was left at
`Physical size: 1536x2048 / Physical density: 240` (verified at the end of the run).

**Why this release cannot fix it.** The cost is in SystemUI, and SystemUI ships inside the prebuilt
TrebleDroid GSI: this repository builds the kernel, the device tree, the vendor partition and the
packaging only. The remaining lever on the app side would be the notification list itself
(`NotificationShade` held 423 views and 441 kB of render nodes during these runs), which is the
user's data, not a port defect.

## 3. Release package 2026-11-10: what was checked

Rebuilt from `out/super-work/system.img` (which contains `BP2A.250605.031.A3`, the same build as the
published release; `out/inputs/super.img` and the published `2026-11-08` `images/super.img` have the
same sha256 `4a6d059ef79b0c05...`, so the base is the one already shipped):

```
./build-android-images.sh out/inputs-20261110     (SYSTEM_IMG_LOCAL=.../pre-20261110/system.img)
./release-build/make-release.sh out/inputs-20261110 2026-11-10
```

- `super.img` grew from 1650458624 B to 1664905216 B. Not a mystery: `scripts/build-super.sh:34`
  computes `system + vendor + odm + 16 MiB` (= 1508233216 + 139259904 + 634880 + 16777216), and the
  comment at lines 31-33 records why the slack is 16 MiB and not 1 MiB (`Not enough space on device
  for partition odm`). Partition contents are unchanged in size.
- `guard-release.py`: 40 checks, `GUARD OK`, exit 0 - including every `*_LBA` and `*_MAX` agreeing
  with the layout derived from the device tree in `images/resource.img` plus the parameter structure,
  `head-4M.bin` carrying the `RK32` tag at byte offset 0x8800, `parameter-p1.img` holding 4 PARM
  structures at 0x0/0x100000/0x200000/0x300000, `parameter-loader.img` holding 8 at 512 KiB spacing,
  and `head-8M.bin` being byte-identical to the first 4 MiB of `head-4M.bin`.
- `sha256sum -c SHA256SUMS` inside the package: 13/13 OK. `unzip -tq` on the zip: no errors.
  Final artifact: 803811637 B, sha256
  `a77ec2c6b680d9c7ede9a338bffd94077b9807fb239cc1846b18120fca34bb1e`, matching the sidecar file.
  (Packaged once before the shade entry joined the README - that intermediate zip was
  `7db3d3a5f365c26f32208aee42d167fda6375a91b7e13f9904c2b7b06271224b`, 803810749 B - then rebuilt;
  the sha above is the one that ships.)
- The README inside the package: 418 lines, no unsubstituted `{{ }}`, contains the pull-down shade
  entry and the `restricted_networking_mode` entry.
- `images/kernel.img` byte-identical to `out/kernel-gsi-release/kernel.img`; `mkkrnl.py verify`
  reports `KRNL payload 9147768 bytes crc ok`; same for `ramdisk.img` (871334 B crc ok).
- `images/resource.img` byte-identical to `release-build/resource-release-gsi.img` (built by
  `release-build/build-resource.sh`).
- **New in this package:** `lpunpack` of the packed `super.img` -> `vendor.img` ->
  `/etc/init/hw/init.rockchip.rc` is 4036 B, byte-identical to `vendor-changes/etc/init/hw/init.rockchip.rc`,
  and contains `chmod 0755 /sys/kernel/tracing`. The published 2026-11-08 package did not have that
  line in `/vendor` (the file was there - it is a stock vendor file - only the `chmod` was missing),
  which is why the Magisk module `ifive-tracefs-perms` was needed on this tablet.
- `restore.sh --plan --board ifive-mini4s` (touches no device) prints the derived write map; every
  row satisfies `raw = tool + 0x2000`, matching `stock-backup/parameter-decoded.txt`:

```
parameter-loader.img  tool 0x00000  raw 0x02000  4194304 B
parameter-p1.img      tool 0x02000  raw 0x04000  4194304 B
images/resource.img   tool 0x06000  raw 0x08000 16777216 B
images/kernel.img     tool 0x0e000  raw 0x10000  9147780 B
images/ramdisk.img    tool 0x16000  raw 0x18000   871346 B   (boot partition, KRNL container)
images/super.img      tool 0x92000  raw 0x94000 1664905216 B (system partition)
images/metadata.img   tool 0x692000 raw 0x694000 16777216 B
userdata-head-zero    tool 0x6ba000 raw 0x6bc000  1048576 B
```

- `restore.sh` has exactly one `wl` call site (line 441), refuses when the device tree and the
  parameter structure disagree (line 234), refuses when `device.json`'s `p1_lba` does not match the
  parameter structure read from the tablet (lines 246-247), requires each parameter image to start
  with `PARM` (line 300), read-back-compares every write, and does not reset the tablet.
  `write-loader-head.sh` refuses in Maskrom (line 120) and establishes the LBA base by reading the
  region back rather than guessing (line 127 ff).
- The loader area (raw 0x0000..0x1FFF) is below tool LBA 0 and no `rkdeveloptool` LBA command can
  reach it; `devices/ifive-mini4s/head-4M.bin` + `write-loader-head.sh` cover it, and the
  Maskrom -> Loader step still needs RKDevTool/AFPTool on Windows because `rkdeveloptool db` failed
  here three times on 2026-10-29 (recorded in the release README).
- `head-8M.bin` sha256 `9292f5a365048591f3e18413617846b4ec4798565124e02adc6d27ce52fb2e9e` equals the
  sha256 of `stock-backup/bootloader-8M.bin`, so the rescue data is the real stock dump.
- `ifive-mini4s-android16-boot-magisk-v31.img` (sha256 `004d4b4581c8b24d...`) is unchanged because
  `images/ramdisk.img` is byte-identical to the one the 2026-11-08 release shipped.

## 4. Device settings changed today

| key | was | now | revert |
|---|---|---|---|
| `global restricted_networking_mode` | 1 | 0 | `settings put global restricted_networking_mode 1` |
| `secure ui_night_mode` | 2 | 1 (light, via `cmd uimode night no`) | `cmd uimode night yes` |
| `secure sysui_tint_based_fog_effect_enabled` | unset | unset (`settings delete`, read back `null`) | - |

GPU devfreq and all `debug.sf.*` properties were returned to their original values, checked by
reading them back at the end of each test script. No partition was written; one reboot was done.
