# Android 16 GSI for iFive mini 4S — release 2026-11-12

Flash guide: `README.md` inside the zip (also the package's Contents
section). Checksums: `SHA256SUMS` (verified by the flash script itself).

## Files

| file | sha256 |
|---|---|
| `ifive-mini4s-android16-gsi-2026-11-12.zip` (803,810,273 B) | `f6b8b02d70bb36e561ada51ce264a548ad9e14f99a96808382707782b382d00a` |
| `ifive-hwc-composition-2026-11-12j.zip` (Magisk module, 406,760 B) | `a6fbbe5bdc68f4b1d9d9d00c3948d4c67ebab65388eace052c0e576002917bdf` |
| `ifive-mini4s-android16-boot-magisk-v31.img` (1,006,611 B, optional rooted boot partition, built by `scripts/make-magisk-boot.sh` from Magisk APK `2c8a488b…`; KRNL CRC verified, not yet tested on the tablet) | `004d4b4581c8b24d22328cb877e8c951adade8995ee62a36c708f8c9987f90d4` |
| `ifive-no-phh-su.zip` (2,105 B, needed for the Magisk install steps in the package README) | `e7e3b9e1d4d282fed59dcabe5172f3b8b8e08bfa0db0fe869581cae3be01922d` |

This 11-12 zip was rebuilt twice before publication and the copies were
never sent anywhere. First rebuild: the `flash.sh`/`restore.sh`/
`write-loader-head.sh` of the first copy made their scratch directories
under `/tmp`, which fails on a host where `/tmp` is read-only. Second
rebuild: the package README gained the missing guidance on which
`--lba-base` to pass to `write-loader-head.sh` on a blank tablet.
kernel/ramdisk/resource/metadata are the same files throughout; super.img
holds the same e8fbd341 HAL and the same block maps in every copy - the
pipeline reproduces the hand-built super to within 12 bytes of ext4 inode
timestamps (`cmp -l`), so supers can differ only in the splice moment.

## What changed since 2026-11-08

- **HWC fix for notification-shade jank is now inside the system image.**
  The status bar and taskbar used to block each other's hardware
  composition (a vendor `combine_layer` ordering assumption), forcing
  the whole scene into GPU composition. Patched HWC combines them into
  one VOP plane (`lib/hw/hwcomposer.rk30board.so`, sha256 prefix
  `e8fbd341`; vendor partition otherwise unchanged).
- **Composition bandwidth gate tuned for this panel, active without
  root**: defaults are `scale_trigger=6.5`, `scale_limit=5.5` — the
  values measured on this 1536x2048 panel (UI scenes sum 3.4-5.0; the
  old 1080p reference values 4.5/3.3 rejected every merged scene here).
  Advanced tuning via `persist.vendor.hwc.vop.scale_trigger` /
  `scale_limit` (setprop needs root; not required for the fix to work).
- **New rescue tooling in the package**: `restore.sh` restores a fully
  wiped eMMC (writes the loader-area parameter copies, resource, kernel,
  boot, super, metadata, userdata head — the `--plan` flag prints every
  address first), `write-loader-head.sh` restores the first 4 MiB
  (idbloader + u-boot) which normal tool LBAs cannot reach. Rescue data
  per board under `devices/` (byte-identical to the board dumps).
- Kernel `#2 SMP PREEMPT Thu Nov 12 07:56:59 +08 2026`: rebuilt from the
  same driver tree as the 11-08 package's kernel (`#1 ... Nov 7
  17:41:17`), which already carried the VOP GLOBAL_ALPHA attach. The
  two images differ in 8.8 M of 9.1 M bytes; no commit under
  `kernel/drivers/` landed between the two build times (the only .c
  change was `scripts/extract-cert.c`, a build-time tool that is not
  part of the kernel image), but the build-time .config is not recorded
  in either package, so the byte difference is not fully explained by
  this repo's history. Devfreq device-tree values verified on the
  running tablet in `/proc/device-tree` (polling-ms=0xa,
  upthreshold=0x19, downdifferential=0xf). `resource.img` is
  byte-identical to 11-08.

## Control measurement on the stock Android 11 system (2026-11-12)

The tablet currently runs its original Tinker Board Android 11 system
(HAL sha256 da9659f1..., an owner-built copy using `vop.max_scale=6.0`),
so the fixed GSI itself could not be measured without touching /data.
Recorded as a baseline for the same gestures on the same panel, non-root:

| run (4 shade flings, 12 notifications posted) | SF missed frames | SystemUI janky % |
|---|---|---|
| burst 1 | 37 | 18 |
| burst 2 | 28 | 5 |
| burst 3 | 3 | 7 |

This is the pre-fix behaviour class (GPU composition of the shade scene).
The 11-12 GSI's built-in fix has NOT been measured on-device yet; the
A/B matrix run against it is still open.

## GPU boost (rooted devices, module zip)

The Mali 400 never leaves its 198 MHz floor with the stock
`simple_ondemand` governor (its utilisation counter stays 0), which is
the other half of the shade-jank story. The Magisk module adds a
touch-driven boost daemon (594 MHz while touching, floor 2 s after).
Install via Magisk; on this 11-12 build the module's bind-mounted HWC
and its `setprop` lines only re-assert what the system already has -
the boost daemon is the part that adds something new. (The two
`persist.vendor.hwc.vop.*` properties are still useful there as live
tuning knobs: the HAL reads them via `property_get` at each gate
evaluation, so `setprop` retunes without a reboot.)

## Known caveats

- No GPU boost for non-rooted installs (the daemon needs root; there is
  no way to carry it inside a GSI without modifying vendor init/sepolicy).
- The GPU governor is switched to `userspace` by the module; if
  `gpubboostd` cannot open `/dev/input` it restores `simple_ondemand`
  and stops.

## LBA coordinate system of the bundled rkdeveloptool (2026-11-12, on-device)

Fact chain measured today with the bundled 1.47 tool in Loader state:
- rl 0x6000 -> file starts with "RSCE" (resource magic; the resource
  partition starts at absolute 0x8000) -> tool number = absolute - 0x2000.
- rl 0x18000 -> zeros (absolute 0x1A000 = middle of boot partition,
  consistent; absolute 0x18000 = boot header with ANDROID! magic,
  which was NOT found).
- wl 0xE000 + rl 0xE000 of the 2026-11-11 kernel read back identical.
flash.sh / flash.sh.src use these data-region numbers and match
restore.sh; they were NOT wrong. The stock-backup note ("wl = absolute")
describes raw `dd`/Windows offset tools. Both rkdeveloptool builds take
the same numbering: system 1.32 with loader/rk3288_loader_v1.12.263.bin
wrote a 4 KiB pattern at 0xE000 and read it back at 0xE000, and wrote
resource.img at 0x6000 with full-16MiB sha256 match; `ppt` on the same
session prints the parameter table (uboot 0x2000, misc 0x4000, resource
0x6000, kernel 0xE000, boot 0x16000) in exactly these numbers.

Mistakes made today and their fixes (kept as record):
- run-on-device.sh "corrected" addresses to absolute -> the 12-region
  backup was shifted 4 MiB (all files invalid, moved to
  a11-backup-2026-11-12-WRONG-SHIFTED-4MiB), and the 11-12 kernel was
  written to data-region 0x10000 = absolute 0x12000 = 4 MiB into the
  kernel partition, overwriting the old payload past its KRNL header ->
  boot failed, device fell back to Maskrom.
- REtracted later today: "minloader-state reads are unreliable". Wrong.
  After the session was rebuilt (db with loader/rk3288_loader_v1.12.263.bin
  via system rkdeveloptool 1.32), the eMMC channel verified fully good:
  `rfi` reports SAMSUNG 61071360 sectors, `ppt` prints the parameter
  table, a 4 KiB test pattern written at tool 0xE000 read back at the
  same address, and kernel.img written at 0xE000 read back with 1 MiB
  sha256 identical (7b5220bd...). The earlier "writes did not land"
  conclusions were my own arithmetic errors using raw-converted
  addresses (0x10000/0x52000) in that same window.
- Final addressing model (both rkdeveloptool 1.32 and the bundled 1.47
  agree): wl/rl/ppt take the parameter's mtdparts LBA, which equals the
  raw eMMC sector minus 0x2000 (the 4 MiB GPT/protect-block head).
  `rl 0x40 8` matches stock-backup head-8M.bin at raw sector 0x40,
  proving the -0x2000 offset belongs to the raw tools only.

### Write timeline and why each reboot failed (confirmed by arithmetic)

- Device's live kernel (read pre-W1 during the backup, strings show
  "#2 SMP PREEMPT Thu Nov 12 07:56:59 +08 2026") = the 11-12 package
  build 52e91ab2, partition start tool LBA 0xE000.
- W1 wl 0x10000 (absolute 0x12000): wrote a second copy of 52e91ab2
  starting 4 MiB into the partition -> old payload bytes 4 MiB.. broken
  against the header at 0xE000 -> reboot fail (expected).
- W2 wl 0xE000 <- f7eb972d (11-11 build): header+payload consistent,
  readback matched... but then W3 ran.
- W3 wl 0x10000 <- f7eb972d again: overwrote W2's payload past its
  4 MiB point -> header CRC mismatch again -> reboot fail (expected).
- 11-11 vs 11-12 kernel files: 9,147,708 B each, differ in 40 bytes
  only, all inside one region at ~6.4 MiB (KRNL/CRC fields). Same vmlinuz
  build. Either one is a valid kernel for the current system.
- Recovery write R1 (in flight): wl 0xE000 <- 52e91ab2 (the exact image
  that booted before the brick), readback at 0xE000, then rd 3.
  Boot success confirms: data-region addressing + minloader write path
  good + kernel partition is the boot kernel source.

### Second self-inflicted write: misc wipe overshot into resource

The manual misc-clear used a 16 MiB zero file while misc is 4 MiB:
`wl 0x4000 misc-zero-16MiB` would write over absolute 0x6000-0xE000 =
all of misc plus the first 12 MiB of the resource partition. The job
was killed mid-run; how many bytes actually landed is being measured
by sector probes (tool LBAs 0x4000..0x7000). Recovery plan:

1. Probes to find the zero boundary -> actual damage length.
2. Re-write misc: exactly 1 MiB of zeros at tool 0x4000 (flash.sh's
   committed misc-clear uses images/userdata-head-zero.img, 1 MiB -
   the manual command should have used that file instead of a
   self-made 16 MiB one).
3. Re-write the resource partition at tool 0x6000 with the package's
   images/resource.img (16 MiB; matches the running GSI system; guard
   validated its parameter/DTB contents this morning).
4. Kernel partition at tool 0xE000 already re-written with 52e91ab2 by
   the same killed job (verify with header+tail probes).
5. Reset, wait for adb.

flash.sh itself is unaffected: its misc write uses the 1 MiB file.

### Evening repair (2026-11-12, ~19:30): damage map and writes

Damage measured after re-establishing a clean session (db with the
v1.12.263 loader on system 1.32; eMMC identified as SAMSUNG 61071360
sectors via `rfi`):
- kernel partition: first 4 MiB of kernel.img intact at 0xE000,
  everything from 0x400000 to 0x2800000 = 0xcc bytes (W1's killed
  4 MiB-shifted write plus its overwrite window).
- boot partition 0x16000: all 4 MiB = 0xcc (the GSI ramdisk lived
  there, written by the 11-12 flash attempt, clobbered by a later
  mis-addressed job).
- resource 0x6000: header zeroed by the 16 MiB misc overshot.
Repaired in one session, every step read back and hash-verified:
resource.img full 16 MiB sha256 match (e94a1b01...), kernel.img 1 MiB
head match then full rewrite, ramdisk.img rewritten at 0x16000
(KRNL magic), misc head re-zeroed; then `rd 3`.
- Correction to an earlier claim in these notes: flash.sh does NOT only
  probe 8 sectors after writing - wl_verify already reads back every
  written byte and cmps it (line "CMP OK <label>" per partition). The
  11-12 flash failed before reaching any write because its Maskrom step
  fed UbootLoader.bin to `db` (see commit 97ffc0ee4). The manual
  recovery jobs that broke the partitions used bare `wl` and skipped
  readback; when those steps go through wl_verify they would have been
  caught.

### eMMC write state: only the first 32 MiB accepts writes (2026-11-12, 21:4x)

Four-part test with a 4 KiB pattern (magic "KTEST112") written and read
back at multiple data-region LBAs, each after a fresh successful `db`
(loader/rk3288_loader_v1.12.263.bin, system 1.32, BootROM Maskrom):

| LBA | partition | write + readback |
|---|---|---|
| 0x4000 (6 MiB) | misc | landed, magic verified |
| 0x2000 (4 MiB) | p1 parameter | landed, full mtdparts text verified |
| 0x6000 (12 MiB) | resource | landed (16 MiB full-image sha256 match, 17:26) |
| 0xE000+4 MiB (36 MiB) | kernel mid | 0xcc - not landed |
| 0x26000 (77 MiB) | recovery | 0xcc |
| 0x2E000 (92 MiB) | boot-new area | 0xcc |
| 0x52000 (164 MiB) | cache | 0xcc |

Writable window ends at data-region 0x10000 sectors = 32 MiB; every byte
beyond returns 0xcc after a write attempt (and 0xcc is also what the
controller returns for reads inside damaged blocks). A soft reset
(`rd 1`) followed by re-`db` did not restore writes. Reads of
pre-damage content (idbloader signature == stock-backup head-8M.bin at
raw 0x40, PARM copies, RSCE) are byte-exact, so the eMMC responds - it
just no longer programs beyond 32 MiB.

Diagnosis: Samsung eMMC controller in a write-protect/degraded state
that started after the interrupted W1 write (12:5x). `ppt`/`rfi` fine,
`ef` NOT attempted (would destroy /data, and the user has data on the
device). This is beyond host-software repair: Windows RKDevTool goes
through the same BootROM protocol and will hit the same wall.

Remaining routes, in order of cost:
1. Full power removal (battery connector) - eMMC controllers occasionally
   drop temporary power-on write protect only on a true cold boot.
   USB power does not cut the battery. Needs the tablet opened or a long
   battery drain.
2. SD-card boot Linux with mmc-utils and inspect/relax ext_csd
   write-protect groups (`mmc extcsd read /dev/mmcblk?`,
   PERM_WRITE_PROTECT/POWER_ON_WRITE_PROTECT fields). Requires a microSD
   card on the host - none present tonight. If PERM bits are set, nothing
   is recoverable.
3. eMMC chip replacement (BGA, board-level).

Current device state left as: p1 parameter = stock table (original,
verified readback holds 0xe000(kernel) again), misc = 1 MiB zeros,
resource = 11-12 package (sha verified), kernel partition = first 4 MiB
of 52e91ab2 + 0xcc beyond, boot partition = 0xcc. It will not boot until
the write state clears; nothing past 32 MiB was or can be modified.

Update 17:4x: the p1-restore job (bg_32) timed out mid-session and a
follow-up read (bg_34) could not open a session either - `db` stopped
being accepted again, so p1 holds either the stock or the remapped table
(both boot-fatal while the dead zone stays), and no further writes are
possible from this host right now. A watcher
(out/recovery-v6.sh, service `recovery-v6`) tests the two dead-zone
pattern writes every 10 minutes and performs the whole verified repair
(p1 original table, resource, kernel, ramdisk, misc - never anything
from 0x92000 onward) automatically if the eMMC ever accepts writes
again; it only resets the tablet after every readback hash matched.

Final USB assessment (18:0x): the failure is not an addressing bug. A
"16-bit sector boundary" theory (all bad areas start at sector 0x10000
= 32 MiB) was tested and died: reads at 0xFFFF - below the boundary -
fail just as hard once the loader session stops opening. Timeline of
session quality: afternoon (sessions up, everything read correctly) ->
evening 21:1x (sessions up, reads correct up to 32 MiB, `0xcc` beyond)
-> tonight 17:3x-18:0x (three loaders, three failure stages:
v1.32/UbootLoader "Invalid chip", v1.12.263 accepted by Maskrom but
the session never comes up, miniLoader.bin "Opening loader failed" -
and simple `rl 0xFFFF 1` now returns nothing at all). Maskrom enumerates
and answers `ld`, but idbloader can no longer finish booting to a
Loader session. That pattern matches an eMMC dying progressively, not a
host/cable/tool problem. Remaining human-side checks: battery pull for
a hard power cycle, and if a microSD card becomes available, booting
any SD-capable image to watch dmesg for mmc errors / try `mmc extcsd
read`. The watcher (v6, now on a 30-minute cadence with a lock file at
lbam/v6.pause) will do the full verified repair on its own if the chip
ever answers again.
