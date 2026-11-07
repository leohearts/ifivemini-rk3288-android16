#!/bin/bash
# usage: boot.sh <hwc.so> ; flashes kernel/res/ramdisk if in maskrom, boots, bind-mounts HWC, sets SF durations
set -e
SO=${1:-/run/media/leohearts/Data/rk3288-a11/hwc/out-pipe/hwcomposer.rk30board.so}
A="adb -s RK3288IFIVE01"
G=/run/media/leohearts/Data/rk3288-a11/gsi
if lsusb | grep -q 2207:320a; then
  (cd $G && sha256sum -c res-gsi.img.sha256 ramdisk-gsi.krnl.sha256 && cd ../work-rl1 && sha256sum -c rl1.krnl.sha256)
  (cd $G && /tmp/rk3288-port/scripts/flashX.sh --kernel ../work-rl1/rl1.krnl --res res-gsi.img --ramdisk ramdisk-gsi.krnl --rd)
fi
timeout 180 $A wait-for-device
for i in $(seq 60); do [ "$($A shell getprop sys.boot_completed | tr -d '\r')" = 1 ] && break; sleep 2; done
$A root; sleep 3; $A wait-for-device
$A shell 'settings put system screen_brightness_mode 0; settings put system screen_brightness 20'
$A push "$SO" /data/local/tmp/hwc.so
$A shell 'chmod 644 /data/local/tmp/hwc.so; chcon u:object_r:same_process_hal_file:s0 /data/local/tmp/hwc.so; umount /vendor/lib/hw/hwcomposer.rk30board.so 2>/dev/null; mount -o bind /data/local/tmp/hwc.so /vendor/lib/hw/hwcomposer.rk30board.so || { echo MOUNT_FAIL; exit 1; }; for p in late early earlyGl; do setprop debug.sf.$p.sf.duration 22000000; setprop debug.sf.$p.app.duration 16600000; done; setprop debug.sf.use_phase_offsets_as_durations 1; setprop ctl.restart vendor.hwcomposer-2-1'
sleep 25
$A shell 'md5sum /vendor/lib/hw/hwcomposer.rk30board.so; ls /proc/$(pidof android.hardware.graphics.composer@2.1-service)/task | wc -l; dumpsys SurfaceFlinger | grep -m2 -i duration; input keyevent KEYCODE_WAKEUP'
echo BOOT_OK
