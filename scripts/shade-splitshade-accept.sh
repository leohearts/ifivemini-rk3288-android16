#!/system/bin/sh
# shade-splitshade-accept.sh - PASS/FAIL of the split-shade-off module, two phases.
# Run ON the tablet:  sh /data/local/tmp/shade-splitshade-accept.sh before
#                     (then install ifive-split-shade-off-module.zip, reboot)
#                     sh /data/local/tmp/shade-splitshade-accept.sh after
# No partition writes; the only system change is the standard Magisk module.
#
# before phase: jank 2x12 + 6 s atrace of 12 pull-downs; counts full-width
#   band `Drawing` slices from NON-SystemUI pids (taskbar strip + exposed
#   band of the app behind the drawer). Saves state to /data/local/tmp.
# after phase:  same measurements + verdict + `cmd overlay lookup` truth.
#   PASS: band count <= 20% of before, and jank% not worse than before.
D=/data/local/tmp/splitaccept
S=$D/state
P=com.android.systemui
say(){ echo "[$(date +%T)] $*"; }
phase=${1:-before}

mkdir -p $D
[ "$phase" = before ] && rm -rf $D
pair(){ dumpsys gfxinfo $P 2>/dev/null | awk '/Total frames rendered/{t=$3} /Janky frames:/{j=$3" "$4} /Slow UI thread/{u=$4} END{print "jank", t, j, "slowUI", u}'; }
drag12(){
  i=0
  while [ $i -lt 12 ]; do
    input swipe 768 10 768 800 1400; sleep 0.6
    input swipe 768 700 768 10 1200; sleep 0.9
    i=$((i+1))
  done
}
run_phase(){ # $1=tag   (band counting happens on the host: shade-frame-audit.py)
  am force-stop com.android.settings 2>/dev/null || true
  input keyevent KEYCODE_HOME; sleep 3
  dumpsys gfxinfo $P reset >/dev/null 2>&1
  atrace -t 6 -b 16000 gfx sched freq idle am wm view > $D/trace_$1.txt 2>$D/atrace_$1.log &
  APID=$!
  sleep 0.4; drag12; wait $APID 2>/dev/null
  pair > $D/jank_$1.txt
  say "phase $1 jank: $(tr '\n' ' ' < $D/jank_$1.txt)"
}

if [ "$phase" = before ]; then
  run_phase before
  echo ok > $S
  tar -czf $D-before.tar.gz -C $D . 2>/dev/null
  say "now: install module zip (magisk --install-module), reboot, rerun with 'after'"
  exit 0
fi

[ -f $S ] || { say "FATAL: no before-phase state on device"; exit 1; }
say "=== overlay truth ==="
cmd overlay lookup $P $P:bool/config_use_split_notification_shade > $D/lookup_after.txt 2>&1
cmd overlay list $P | grep -ai splitshade >> $D/lookup_after.txt 2>&1
cat $D/lookup_after.txt | sed 's/^/  /'
if ! grep -aq false $D/lookup_after.txt; then
  say "FAIL: resource still resolves true (overlay not active or variant beats it)"
  exit 2
fi
run_phase after
J_B=$(awk '/jank/{gsub(/[()%]/,"",$4); print $4}' $D/jank_before.txt | head -1)
J_A=$(awk '/jank/{gsub(/[()%]/,"",$4); print $4}' $D/jank_after.txt | head -1)
U_B=$(awk '/jank/{print $6}' $D/jank_before.txt | head -1)
U_A=$(awk '/jank/{print $6}' $D/jank_after.txt | head -1)
say "slow-UI-thread frames: before=${U_B:-?} after=${U_A:-?}  (if jank stays high while slowUI stays ~90%, the A11-style app-side bottleneck applies)"
say "jank before=${J_B}% after=${J_A}%  (band verdict: run host-side shade-frame-audit.py --compare on the two traces)"
tar -czf $D-after.tar.gz -C $D . 2>/dev/null
say "pull back: adb pull $D-after.tar.gz"
