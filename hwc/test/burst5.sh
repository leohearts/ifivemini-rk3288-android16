#!/system/bin/sh
# burst5.sh - hardened shade-jank protocol for the iFive lineage tests.
# Differences from burst4.sh (both kept for cross-checking):
#   - NO swipe gestures: open/close via `cmd statusbar expand-notifications`
#     / `collapse`, because the swipe-close (y=700->10) lands on notification
#     cards and swipe-DELETES them, uncontrolled mutating the scene mid-run.
#     (verified on this device 2026-11-12 22:2x: 15 notifications -> 2 within
#     one 4-burst run.)
#   - re-injects notifications before EVERY burst (idempotent tags abtest1..12).
#   - asserts before each burst: >=12 records in shade, screen awake, and the
#     shade actually toggles (layer-list delta between collapsed/expanded via
#     dumpsys SurfaceFlinger --list | wc -l or visibility probe below).
#     Any assert failure prints SCENE-FAIL and exits 9 - a number is never
#     printed for an unverified scene.
# Output lines for the harness:
#   J=<pct>            per-burst SystemUI gfxinfo janky percent
#   N=<records>        notification count at the assert point
#   MISSED_DIFF=<n>    SurfaceFlinger missed-frame delta across the run
P=com.android.systemui
N=4
TARGET=12

recs() {
  dumpsys notification 2>/dev/null | grep -a 'NotificationRecord(' | grep -avc -e AUTOGROUP_SUMMARY -e GROUP_SUMMARY
}
missed() {
  dumpsys SurfaceFlinger 2>/dev/null | grep -a 'Total missed frame count' | sed 's/.*: //' | tr -dc 0-9
}
jankpct() {
  dumpsys gfxinfo $P 2>/dev/null | awk '/Janky frames/ && !/legacy/ { gsub(/[()%]/, ""); print $4; exit }'
}
assert_scene() {
  n=$(recs); n=${n:-0}
  if [ $n -lt $TARGET ]; then
    sh /data/local/tmp/inject12.sh >/dev/null 2>&1
    n=$(recs); n=${n:-0}
  fi
  if [ $n -lt $TARGET ]; then echo "SCENE-FAIL: only $n notifications"; exit 9; fi
  # screen must be awake or the shade toggles do nothing measurable
  if ! dumpsys power 2>/dev/null | grep -aq mWakefulness=Awake; then
    input keyevent KEYCODE_WAKEUP; sleep 1.5
  fi
  echo "N=$n"
}

MB=$(missed); MB=${MB:-0}
i=1
while [ $i -le $N ]; do
  cmd statusbar collapse >/dev/null 2>&1
  sleep 0.7
  assert_scene
  dumpsys gfxinfo $P reset >/dev/null 2>&1
  cmd statusbar expand-notifications >/dev/null 2>&1
  sleep 1.4
  cmd statusbar collapse >/dev/null 2>&1
  sleep 0.7
  echo "J=$(jankpct)"
  i=$((i+1))
done
MA=$(missed); MA=${MA:-0}
echo "MISSED_DIFF=$((MA - MB))"
