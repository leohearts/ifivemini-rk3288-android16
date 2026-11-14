# SD rescue runbook - tablet ML5RRJ6M5C (eMMC unresponsive)

Purpose: the eMMC stopped accepting any I/O at the idbloader stage
(rkdeveloptool sessions no longer come up; see
release-notes-2026-11-12.md). An SD boot is the only remaining way to
talk to the chip from inside the board: dmesg for mmc errors, and
`mmc-utils` to read/attempt-clear the ext_csd write-protect fields.

Nothing on this page clears data. Do NOT run `mmc erase`, `mmc discard`,
`mkfs`, or any partition-table write on /dev/mmcblk1 during diagnosis.

## 0. Host side (once a microSD card + reader exist)

Image (already downloaded, sha in .sha file):
`/run/media/leohearts/Data/agentwork/sd-image/Armbian_24.2.5_Xt-q8l-v10_bookworm_current_6.6.22_minimal.img.xz`

```bash
# double-check target before writing anything:
lsblk -o NAME,SIZE,MODEL,TRAN /dev/sdX
zcat Armbian_24.2.5_Xt-q8l-v10_bookworm_current_6.6.22_minimal.img.xz \
  | sudo dd of=/dev/sdX bs=8M status=progress oflag=direct
sync
```

## 1. Boot

Insert the card, power the tablet normally (or `rkdeveloptool rd 3` if it
sits in Maskrom). The BootROM tries eMMC idbloader first; because that
stage fails, it continues to the next boot source (SD). This same
fallback is how the board ran Armbian from SD earlier this project.
HDMI output, then login `root` / the password shown at first boot.

## 2. Diagnose from inside

```bash
uname -a                              # expect 6.6.22 armv7
dmesg | grep -ai "mmc\|dwmmc\|error\|timeout" | head -40
ls -l /dev/mmcblk*                    # eMMC = mmcblk1 (SD = mmcblk2 here)
cat /sys/kernel/debug/mmc1/ocr 2>/dev/null
sudo apt-get install -y mmc-utils
mmc extcsd read /dev/mmcblk1          # full dump - SAVE THE OUTPUT
```

Fields that decide everything (from the ext_csd dump):

| Field | Meaning if set | Fixable? |
|---|---|---|
| `PARTITION_CONFIG` boot area enable | boot split moved | `mmc partconf` - restore value from a healthy dump |
| `USER_WP` / `write protect` groups | soft WP on the first groups | `mmc writeprotect off <dev> <addr> <len>` per group; try ONE group first |
| `PERMWP` bits | permanent write protect | NOT fixable, chip replacement |
| `FPO` (Force Programming Only) | chip locked to factory pattern writes only | NOT field-reversible |
| `pre EOL info [0]/[1]` | vendor-recommended replacement | replacement |

Also worth one line: `mmc status get /dev/mmcblk1` and `mmc csd read
/dev/mmcblk1` - a READY FOR DATA that stays low tells the same story as
the USB behavior.

## 3. If WP groups were set and cleared

Reboot into Maskrom (power off, hold nothing, plug USB - BootROM falls
back to Maskrom when both eMMC boot stages stall): the `recovery-v6`
watchdog then does the whole repair by itself (verified writes of p1,
resource, kernel, ramdisk, misc; no touches past LBA 0x92000; only
resets after every readback hash matched). Manual equivalent:
`out/recovery-v6.sh` header comments.

## 4. If the dump says PERMWP/FPO/pre-EOL

Stop software attempts; the chip is end-of-life. Keep the 11-12
backups (`~/rk3288-ifive-mini4s/stock-backup`), report the exact dump
lines, and plan an eMMC replacement (same BGA part family as RK3288
boards: any 8 GiB HS200 eMMC with compatible CMDQ-none firmware).
