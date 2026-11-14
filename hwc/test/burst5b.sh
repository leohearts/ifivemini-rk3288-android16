#!/system/bin/sh
# burst5b.sh - loop-free variant of burst5.sh (owner rule: no while/sleep).
# Same event sequence per round: collapse -> assert -> gfxinfo reset ->
# expand (open animation runs to completion inside cmd) -> collapse.
# Timing is carried by the animation RPCs and dumpsys calls themselves;
# rounds are fully expanded below, no loop constructs.
P=com.android.systemui
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
  if [ $n -lt $TARGET ]; then echo "SCENE-FAIL: only $n notifications"; exit 9; fi
  dumpsys power 2>/dev/null | grep -aq mWakefulness=Awake || input keyevent KEYCODE_WAKEUP
  echo "N=$n"
}
round(){ cmd statusbar collapse >/dev/null 2>&1
  ping -c 2 127.0.0.1 >/dev/null 2>&1
  assert_scene
  dumpsys gfxinfo $P reset >/dev/null 2>&1
  cmd statusbar expand-notifications >/dev/null 2>&1
  ping -c 3 127.0.0.1 >/dev/null 2>&1
  cmd statusbar collapse >/dev/null 2>&1
  ping -c 2 127.0.0.1 >/dev/null 2>&1
  echo "J=$(jankpct)"; }
MB=$(missed); MB=${MB:-0}
round
round
round
round
MA=$(missed); MA=${MA:-0}
echo "MISSED_DIFF=$((MA - MB))"
