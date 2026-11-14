#!/system/bin/sh
# burst6.sh - fullaccept-style SWIPE-open protocol (bridges 2026-11-11/12
# AOSP-era numbers made with fullaccept.sh) with two fixes learned on
# 2026-11-12/13:
#   - close via `cmd statusbar collapse`, NEVER swipe-close: the
#     700->10 swipe lands on notification cards and swipe-DELETES them
#     (15 cards -> 2 within one run).
#   - re-inject before EVERY burst and assert the count (burst5 guard).
# Open gesture itself is identical to fullaccept.sh: input swipe 768 10
# 768 800 1400 (physics drag, velocity-tracked animation) - this is the
# variable that differs from burst5's `cmd statusbar expand-notifications`
# programmatic animation. Compare J(burst5) vs J(burst6) per arm to
# quantify the gesture contribution; compare J(burst6) vs the AOSP-era
# 6.9-7.2% numbers as the cross-build check.
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

MB=$(missed); MB=${MB:-0}
i=1
while [ $i -le $N ]; do
  cmd statusbar collapse >/dev/null 2>&1
  sleep 0.7
  n=$(recs); n=${n:-0}
  if [ $n -lt $TARGET ]; then
    sh /data/local/tmp/inject12.sh >/dev/null 2>&1
    n=$(recs); n=${n:-0}
  fi
  [ $n -ge $TARGET ] || { echo "SCENE-FAIL: only $n notifications"; exit 9; }
  echo "N=$n"
  if ! dumpsys power 2>/dev/null | grep -aq mWakefulness=Awake; then
    input keyevent KEYCODE_WAKEUP; sleep 1.5
  fi
  dumpsys gfxinfo $P reset >/dev/null 2>&1
  input swipe 768 10 768 800 1400          # identical to fullaccept.sh open
  sleep 1.6
  cmd statusbar collapse >/dev/null 2>&1   # no card-deleting swipe
  sleep 0.7
  echo "J=$(jankpct)"
  i=$((i+1))
done
MA=$(missed); MA=${MA:-0}
echo "MISSED_DIFF=$((MA - MB))"
