# Rel07n: release 2026-11-07 (td16n) acceptance flash

- Zip sha256 791935d6… OK; SHA256SUMS 10/10 OK.
- Maskrom via reset_loader; flash.sh --yes: all writes read back OK, reset issued 1794041467.
- adb up: +282 s; sys.boot_completed=1: +314 s.
- +90 s (t=404): chgpolicy running; rn5t618_power high_current_allowed=Y.
- ADP input_current_limit=2000000 (not 500000, no reread needed); USB limit=500000.
- hwc sha256 83101dff… (/vendor/lib/hw/hwcomposer.rk30board.so) matches.
- cmdline contains rkwdt=0; no rkdeadline.
- Screen off/on cycle done; screencap runs/rel07n/rel07n.png shows keyguard ("Unlock for all features and data"), not Home. HOME keyevent sent while locked.
- settings: screen_brightness_mode=0, screen_brightness=20 set and read back.
- scratch/rel07n deleted.
