# ChgFix: vendor.chgpolicy never starts

## Cause
`vendor.chgpolicy` has no `seclabel`, so init tries an automatic domain transition from `u:r:init:s0` into the file label `vendor_shell_exec` of `/vendor/bin/chgpolicy.sh`. The policy grants init only `(allow init vendor_shell_exec (file (execute)))`. It has no `entrypoint` and no `domain_auto_trans`, so init refuses to start the service.

## Evidence
- init log at boot (`sys.boot_completed=1`, `/vendor/etc/init/hw/init.rk3288.rc:59`):
  `Command 'start vendor.chgpolicy' ... took 1ms and failed: Could not start service: File /vendor/bin/chgpolicy.sh(labeled "u:object_r:vendor_shell_exec:s0") has incorrect label or no domain transition from u:r:init:s0 to another SELinux domain defined.`
- Manual `start vendor.chgpolicy` fails with the same error (start_rc=1).
- Policy: `vendor_shell_exec` is `vendor_file_type`/`exec_type` (vendor_sepolicy.cil ~line 120). Its only init rule is `allow init vendor_shell_exec (file (execute))` (~line 21496). `vendor_shell` can execute `vendor_shell_exec` with `entrypoint` (~lines 32228, 32532).
- Foreground `sh /vendor/bin/chgpolicy.sh` runs its loop. The script works once it runs.

## Fix
`/vendor/etc/init/hw/init.rk3288.rc`, service block, after `group system`:
`+    seclabel u:r:vendor_shell:s0`
File labels are unchanged. The script's `mkdir -p /data/vendor/chg` already covers its data dir. The file is 2348 -> 2381 bytes.

## Build
- Partition `vendor` rebuilt via debugfs (rm, write, mode 0644, uid/gid 0, `security.selinux` = `u:object_r:vendor_configs_file:s0`), then `e2fsck -fy` rc=0.
- `super-td16k.img` built with lpmake. Block device `system` and group `rockchip_dynamic_partitions:1649410048`, same as td16j. `lpdump` matches td16j. The 113 changed bytes all lie in the vendor extent.
- sha256 `4d7e844c64c8f957eaed5c278cfa0e425984d7f620e1380cee467c2ea274f20a` (`gsi/new/super-td16k.img`, sidecar written).

## Caveats
- The device runs Permissive. Denials would not show on device, so the fix is verified by policy reading, not by a live Enforcing start.
- Checks for the main agent after reflash: `start vendor.chgpolicy` succeeds under Enforcing. `high_current_allowed` goes to Y when `persist.vendor.chg.boost` is auto and battery <40 C, SoC <70 C, capacity <95.
- Device left as is (will be reflashed). Its `high_current_allowed` is Y and `/data/vendor/chg` exists from the foreground test.
