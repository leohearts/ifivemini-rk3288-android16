#!/bin/bash
# release-check.sh <outdir> : the acceptance run for a flashed release package, on a fresh boot,
# with no composer/SurfaceFlinger restart (restarts leave a slower state that users never see).
#   1. device state: build, kernel, vendor HAL md5, Magisk, DDR rate, tick broadcast device
#   2. app launch: tap the Gallery icon, HOME, 5 times (launcher3 gfxinfo + SF timestats)
#   3. real3.sh 8 rounds: portrait recents, landscape app drawer, landscape notification shade
#   4. recset.sh 3 rounds: recents opened from Settings (rounded live tile)
#   5. errors logged during the run: IOMMU faults, HWC commit failures, tombstones
# No while/sleep: pauses are ping -c N.
A=$(cd "$(dirname "$0")/../.." && pwd)
export TMPDIR=${TMPDIR:-$A/out/tmp}; mkdir -p "$TMPDIR"
R=${1:?usage: $0 <outdir>}; mkdir -p "$R"
T=$A/hwc/test
timeout 15 adb root >/dev/null 2>&1
timeout 60 adb shell 'echo "== state"; echo build=$(getprop ro.build.fingerprint); echo lineage=$(getprop ro.lineage.version)
  echo kernel=$(uname -v); echo hal=$(md5sum /vendor/lib/hw/hwcomposer.rk30board.so | cut -c1-8)
  echo magisk=$(magisk -v 2>/dev/null); echo ddr=$(cat /sys/class/devfreq/ff610000.dmc-cros/cur_freq 2>/dev/null)
  echo fbbufs=$(getprop ro.surface_flinger.max_frame_buffer_acquired_buffers)
  echo broadcast=$(grep -m1 -A1 "^Broadcast device" /proc/timer_list | tail -1)
  echo tombstones=$(ls /data/tombstones | wc -l); logcat -c; dmesg -c >/dev/null' | tr -d '\r' | tee "$R/state.txt"
timeout 10 adb unroot >/dev/null 2>&1
timeout 150 adb shell "settings put system accelerometer_rotation 0; settings put system user_rotation 0
  input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; input keyevent KEYCODE_HOME; ping -c 2 127.0.0.1 >/dev/null
  dumpsys gfxinfo com.android.launcher3 reset >/dev/null; dumpsys SurfaceFlinger --timestats -disable -clear >/dev/null; dumpsys SurfaceFlinger --timestats -enable >/dev/null
  for k in 1 2 3 4 5; do input tap 1333 1600; ping -c 3 127.0.0.1 >/dev/null; input keyevent KEYCODE_HOME; ping -c 3 127.0.0.1 >/dev/null; done
  echo == launch \$(dumpsys gfxinfo com.android.launcher3 | grep -aE 'Janky frames:|50th percentile' | tr '\n' ' ') \$(dumpsys SurfaceFlinger --timestats -dump | grep -aE '^(totalFrames|missedFrames|clientCompositionFrames) =' | head -3 | tr '\n' ' ')
  dumpsys SurfaceFlinger --timestats -disable >/dev/null" | tr -d '\r' | tee "$R/launch.txt"
"$T/real3.sh" "$R/real3" 8 | tee "$R/real3.txt"
"$T/recset.sh" recents-from-settings 3 | tee "$R/recset.txt"
timeout 15 adb root >/dev/null 2>&1
timeout 60 adb shell 'echo "== errors"; echo iommu=$(dmesg | grep -acE "Page fault|stall request") hwc=$(logcat -d | grep -acE "Failed to commit pset|Composite failed") tombstones=$(ls /data/tombstones | wc -l)
  settings put system accelerometer_rotation 1' | tr -d '\r' | tee "$R/errors.txt"
timeout 10 adb unroot >/dev/null 2>&1
