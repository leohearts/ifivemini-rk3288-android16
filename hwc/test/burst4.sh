#!/system/bin/sh
# burst4.sh - device-side burst measurement for the HWC A/B harness
# (see hwc/ab-test.sh; pushed to /data/local/tmp and run as
# `sh /data/local/tmp/burst4.sh`).
#
# Opens and closes the notification shade N=4 times and prints, for the
# harness to grep (`grep -aE "MISSED_DIFF|^J="`):
#   J=<pct>          per-burst SystemUI jank percent (gfxinfo, reset each burst)
#   MISSED_DIFF=<n>  SurfaceFlinger "Total missed frame count" delta over the run
#
# Command availability, checked against the Android 16 GSI system.img
# (2026-11-12) and the on-device predecessor scripts in out/tmp/jankwork/:
#   - dumpsys SurfaceFlinger, "Total missed frame count: N"
#       literal string present in /system/bin/surfaceflinger (verified 2026-11-12)
#   - dumpsys gfxinfo com.android.systemui [reset], "Janky frames: 4 (3.88%)"
#       seen in real device capture out/tmp/jankwork/t6.txt; `reset` used by
#       out/tmp/jankwork/fullaccept.sh
#   - cmd statusbar expand-notifications / collapse
#       com.android.server.statusbar.StatusBarShellCommand in services.jar,
#       "expand-notifications" string verified; `cmd statusbar collapse` proven
#       on-device by out/tmp/jankwork/{reload_hal,postboot}.sh
#   - input swipe (fallback gesture, 1280x800 panel)
#       proven on-device by fullaccept.sh (same x=768, y 10<->800 coordinates)
#   NOTE: there is no shell verb to reset the SurfaceFlinger missed-frame
#   counter (no reset string in the binary; it clears only when SF restarts),
#   so the before/after DELTA is reported instead of a zeroed counter.
P=com.android.systemui
N=4
X=768

missed() {
  dumpsys SurfaceFlinger 2>/dev/null | grep -a 'Total missed frame count' | sed 's/.*: //' | tr -dc 0-9
}

jankpct() {
  # gfxinfo line "Janky frames: 4 (3.88%)" -> 3.88 ("Janky frames (legacy)" skipped)
  dumpsys gfxinfo $P 2>/dev/null | awk '/Janky frames/ && !/legacy/ { gsub(/[()%]/, ""); print $4; exit }'
}

open_shade() {
  cmd statusbar expand-notifications 2>/dev/null && return 0
  # Fallback if the statusbar cmd is unavailable: top-edge pull-down
  input swipe $X 10 $X 800 1400
}

close_shade() {
  cmd statusbar collapse 2>/dev/null && return 0
  # Fallback if the statusbar cmd is unavailable: swipe back up
  input swipe $X 700 $X 10 1200
}

B=$(missed); B=${B:-0}
i=1
while [ $i -le $N ]; do
  close_shade
  sleep 0.6
  dumpsys gfxinfo $P reset >/dev/null 2>&1   # fresh frame stats per burst
  open_shade
  sleep 1.2                                  # cover the open+close animation
  close_shade
  sleep 0.6
  echo "J=$(jankpct)"
  i=$((i+1))
done
A=$(missed); A=${A:-0}
echo "MISSED_DIFF=$((A - B))"
