# Rel07k: GSI16 td16k release and acceptance flash

## Done
- release/build/make-release.sh line 19: SUPER default is now gsi/new/super-td16k.img. GSI16_SUPER override kept.
- Built release/ifive-mini4s-android16-gsi-2026-11-07.zip (802235900 B), sha256 87b6fd4b0ee9b94e2d7edee3ebc097ab6ef81b9f94bfcab1a2a8babed4dc7fe3. Sidecar sha check OK, unzip -t OK, guard OK (super 1650458624 B <= system 3072M).
- Flash (runs/device.lock held, log runs/rel07k/run.log): FLASH COMPLETE, all writes read back OK (super, metadata, userdata head, resource, kernel, ramdisk). Reset issued at 156 s.

## Not verified
- adb up: NOT reached. Device absent from adb and from lsusb after reset (about 10 min of polling). adb server restarted; still no device.
- boot_completed, init.svc.vendor.chgpolicy, last.txt, input_current_limit, HWC sha, screencap: NOT checked (no device).
- release/SHA256SUMS.txt: not re-verified against the new zip in this report.

## Blocker
Device dropped off USB after the flash reset. Next step: physically check the phone (power, cable). Then run adb devices -l and the post-boot checks from the assignment.
