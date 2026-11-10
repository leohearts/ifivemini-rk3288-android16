#!/system/bin/sh
# shade-scene-atrace.sh - on-device A/B of the two pull-down scenes, NO device writes.
# Run from host as: adb shell su -c 'sh /data/local/tmp/shade-scene-atrace.sh'
# Collects, for HOME-scene drag and APP-scene drag separately:
#   - atrace (gfx sched freq idle + hwc logcat) during 8 pull-downs
#   - per-layer composition state snapshot (who is CLIENT vs DEVICE, layer count)
#   - gfxinfo jank numbers with the standard 2x12 protocol
# Output: /data/local/tmp/shadescene1111.tar.gz - pull it back and diff the scenes.
D=/data/local/tmp/shadescene1111
rm -rf $D; mkdir -p $D
P=com.android.systemui
say(){ echo "[$(date +%T)] $*"; }
pair(){ dumpsys gfxinfo $P 2>/dev/null | awk '/Total frames rendered/{t=$3} /Janky frames:/{j=$3} END{print t, j}'; }

grab_scene(){ # $1=tag
  dumpsys SurfaceFlinger --list > $D/layers_$1.txt 2>/dev/null
  dumpsys SurfaceFlinger > $D/sf_$1.txt 2>/dev/null
  dumpsys window displays | grep -aE 'mLayerStack|Window\{' > $D/win_$1.txt 2>/dev/null
}

cycle(){ # $1=tag, run 12 swipes, record jank
  set -- $(pair); T0=$1; J0=$2
  i=1; while [ $i -le 12 ]; do input swipe 768 12 768 950 350; sleep 1; input swipe 768 950 768 12 250; sleep 1; i=$((i+1)); done
  set -- $(pair); T1=$1; J1=$2
  DT=$((T1-T0)); DJ=$((J1-J0)); [ "$DT" -gt 0 ] || DT=1
  echo "$1 frames=$DT janky=$DJ rate=$((DJ*100/DT))%" | tee -a $D/jank.txt
}

grab_gpu(){ # gpu clock trace of one slow drag
  ( while [ ! -f $D/.done_$1 ]; do grep -a . /sys/class/devfreq/ffa30000.gpu/last_stats 2>/dev/null >> $D/gpu_$1.txt; echo "t=$(date +%s%N) cur=$(cat /sys/class/devfreq/ffa30000.gpu/cur_freq)" >> $D/gpu_$1.txt; sleep 0.05; done ) &
}

say "stayon + wake + HOME"
svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; input keyevent KEYCODE_HOME; sleep 3

say "=== scene HOME (desktop pull-down) ==="
grab_scene home
logcat -c 2>/dev/null
grab_gpu home
cycle home
touch $D/.done_home
# one drag under atrace for layer/drawing evidence
atrace -t 6 -b 16384 gfx sched freq idle power > $D/atrace_home.txt 2>/dev/null &
sleep 0.5; input swipe 768 12 768 950 350; sleep 1; input swipe 768 950 768 12 250; wait
logcat -d | grep -aiE 'mix|skip layer|fail match|Go into|plane' | tail -80 > $D/hwclog_home.txt

sleep 5
say "=== scene APP (Settings page pull-down) ==="
am start -a android.settings.SETTINGS >/dev/null 2>&1; sleep 6
grab_scene app
logcat -c 2>/dev/null
grab_gpu app
cycle app
touch $D/.done_app
atrace -t 6 -b 16384 gfx sched freq idle power > $D/atrace_app.txt 2>/dev/null &
sleep 0.5; input swipe 768 12 768 950 350; sleep 1; input swipe 768 950 768 12 250; wait
logcat -d | grep -aiE 'mix|skip layer|fail match|Go into|plane' | tail -80 > $D/hwclog_app.txt
input keyevent KEYCODE_HOME

say "=== one idle-start sample (GPU cold, first beat) x3, home scene ==="
sleep 20
input keyevent KEYCODE_HOME; sleep 2
grab_gpu idle
i=1; while [ $i -le 3 ]; do input swipe 768 12 768 950 350 >/dev/null 2>&1; sleep 8; i=$((i+1)); done
touch $D/.done_idle

say "=== exp1: no_rounded_corners A/B (home scene) ==="
# experiment 1 from reports/ShadeJankTrace1110.md: does squaring SYSTEM corners
# move the shade card off SF's GLES path? only valid if the card uses system
# corners - the atrace comparison decides, this script just captures both states.
input keyevent KEYCODE_HOME; sleep 3
cycle round_off_baseline
settings put secure no_rounded_corners 1; sleep 3
grab_scene rounded_off
atrace -t 6 -b 16384 gfx sched freq idle power > $D/atrace_rounded_off.txt 2>/dev/null &
sleep 0.5; input swipe 768 12 768 950 350; sleep 1; input swipe 768 950 768 12 250; wait
cycle rounded_on
settings put secure no_rounded_corners 0; sleep 3   # restore user state
say "=== exp2: aflags mutability probe (read-only if set fails) ==="
aflags list 2>/dev/null | grep -aiE 'ignore_corner|corner_radius' > $D/aflags_flags.txt
aflags get com.android.window.flags ignore_corner_radius_and_shadows > $D/aflags_get.txt 2>&1
aflags set com.android.window.flags ignore_corner_radius_and_shadows true > $D/aflags_set.txt 2>&1
RC=$?
if [ $RC -eq 0 ]; then
  am force-stop $P; sleep 25
  grab_scene flag_off
  atrace -t 6 -b 16384 gfx sched freq idle power > $D/atrace_flag_off.txt 2>/dev/null &
  sleep 0.5; input swipe 768 12 768 950 350; sleep 1; input swipe 768 950 768 12 250; wait
  cycle flag_off
  aflags set com.android.window.flags ignore_corner_radius_and_shadows false >$D/aflags_restore.txt 2>&1
  am force-stop $P; sleep 20
else
  echo "aflags set rc=$RC (immutable or unavailable) - see aflags_set.txt" >> $D/aflags_get.txt
fi

svc power stayon false
tar -czf $D.tar.gz -C $D . 2>/dev/null && echo "OUTPUT: $D.tar.gz"
# host-side one-glance diff after pulling: grep -c 'Drawing' atrace_*.txt; grep 'Drawing' | awk median
echo "== done =="
