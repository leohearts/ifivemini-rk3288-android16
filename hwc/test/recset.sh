#!/bin/bash
# recset.sh <tag> <rounds> : portrait, open Settings, KEYCODE_APP_SWITCH (Settings shown as a live tile),
# 6 swipes through recents, HOME. Prints launcher3 gfxinfo per round and the HWC layer types once.
A=$(cd "$(dirname "$0")/../.." && pwd)
export TMPDIR=${TMPDIR:-$A/out/tmp}; mkdir -p "$TMPDIR"
tag=$1; n=$2
timeout 300 adb shell "settings put system accelerometer_rotation 0; settings put system user_rotation 0; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard
for r in \$(seq $n); do am start -W -n com.android.settings/.Settings >/dev/null; ping -c 2 127.0.0.1 >/dev/null; input keyevent KEYCODE_APP_SWITCH; ping -c 3 127.0.0.1 >/dev/null
  [ \$r = 1 ] && dumpsys SurfaceFlinger | grep -aE '^ +[0-9]+ \|' | awk -F'|' '{printf \"%s \", \$3}' && echo
  dumpsys gfxinfo com.android.launcher3 reset >/dev/null
  for i in 1 2 3 4 5 6; do input swipe 1200 1000 300 1000 200; ping -c 2 127.0.0.1 >/dev/null; done
  echo \"$tag r\$r \$(dumpsys gfxinfo com.android.launcher3 | grep -aE 'Janky frames:|50th percentile' | tr '\n' ' ')\"
  input keyevent KEYCODE_HOME; ping -c 2 127.0.0.1 >/dev/null; done
settings put system accelerometer_rotation 1" | tr -d '\r'
