#!/system/bin/sh
# shade-splitshade-accept.sh - A/B of the split-shade overlay on device.
# Run ON the tablet:  sh /data/local/tmp/shade-splitshade-accept.sh <rounds>
#   rounds = number of A/B pairs (default 3). Each pair ~2 min.
#
# Two modes, auto-selected:
#   FABRICATE mode (preferred): `cmd overlay fabricate` flips
#     config_use_split_notification_shade in RAM, no install, no reboot, and
#     can be toggled between every measurement round - giving interleaved
#     A/B samples against clock/burst variance. Mode is chosen only if
#     `cmd overlay lookup` CONFIRMS the flip (the base (sw600dp) variant might
#     outrank the fabricate's default-variant entry - then lookup stays true
#     and the script refuses this mode). Takes effect without restart:
#     NSSL.onConfigurationChanged() re-runs updateSplitNotificationShade(),
#     and enabling an overlay is itself a config change to the target.
#   MODULE mode (fallback): needs the reboot between phases; supports only
#     before(N) then after(N) - still interleaved by reboot only once.
#
# Per round: reset gfxinfo -> 6 s atrace during 12 slow pull-downs ->
# jank line + shade release-cadence line printed per round (host tool
# scripts/shade-frame-audit.py computes medians from the saved traces).
# No partition writes, no settings changes; overlay torn down at the end.
D=/data/local/tmp/splitaccept
P=com.android.systemui
R=${1:-3}
say(){ echo "[$(date +%T)] $*"; }

rm -rf $D; mkdir -p $D
pair(){ dumpsys gfxinfo $P 2>/dev/null | awk '/Total frames rendered/{t=$3} /Janky frames:/{j=$3" "$4} /Slow UI thread/{u=$4} END{print "jank", t, j, "slowUI", u}'; }
drag12(){
  i=0
  while [ $i -lt 12 ]; do
    input swipe 768 10 768 800 1400; sleep 0.6
    input swipe 768 700 768 10 1200; sleep 0.9
    i=$((i+1))
  done
}
grab(){ # $1=rounddir ; ONE slow pull-down inside the 6 s window: the release
        # cadence and band-draw counts are per-gesture metrics, one clean
        # gesture is the unit of analysis (12 would overrun the buffer window).
  atrace -t 6 -b 16000 gfx sched freq idle am wm view > "$1/trace.txt" 2>"$1/atrace.err" &
  A=$!
  sleep 0.4
  input swipe 768 10 768 800 1400; sleep 0.6
  input swipe 768 700 768 10 1200
  wait $A 2>/dev/null
}
jankrun(){ # $1=rounddir ; the jank number needs the full 2x12 protocol
  dumpsys gfxinfo $P reset >/dev/null 2>&1
  drag12
  pair > "$1/jank.txt"
  cat "$1/jank.txt" | tr '\n' ' ' | sed 's/^/    /'; echo ""
}
setmode(){ # $1=false|true via fabricate; echoes resulting lookup value
  if [ "$1" = off ]; then
    cmd overlay fabricate --target $P --name splitA $P:bool/config_use_split_notification_shade bool false >/dev/null 2>&1
    cmd overlay enable com.android.shell:splitA >/dev/null 2>&1
  else
    cmd overlay disable com.android.shell:splitA >/dev/null 2>&1
    cmd overlay destroy com.android.shell:splitA >/dev/null 2>&1
  fi
  sleep 2
  cmd overlay lookup $P $P:bool/config_use_split_notification_shade 2>/dev/null
}
home(){ am force-stop com.android.settings 2>/dev/null || true; input keyevent KEYCODE_HOME; sleep 2; }

MODE=fabricate
say "probe fabricate mode..."
V=$(setmode off)
say "  lookup with overlay off-request: $V"
case "$V" in *false*) : ;; *) MODE=module; say "  fabricate cannot flip (variant wins) -> MODULE mode (install + reboot flow)";; esac
cmd overlay disable com.android.shell:splitA >/dev/null 2>&1; cmd overlay destroy com.android.shell:splitA >/dev/null 2>&1

if [ "$MODE" = fabricate ]; then
  i=1
  while [ $i -le $R ]; do
    say "== round $i/$R : A (drawer, overlay off) =="
    setmode on > $D/lookup_A$i.txt; home
    mkdir -p $D/A$i; home; grab $D/A$i; jankrun $D/A$i
    say "== round $i/$R : B (classic, overlay on) =="
    setmode off > $D/lookup_B$i.txt; home
    mkdir -p $D/B$i; home; grab $D/B$i; jankrun $D/B$i
    i=$((i+1))
  done
  setmode on >/dev/null 2>&1   # ensure no leftover fabricate
  cmd overlay disable com.android.shell:splitA 2>/dev/null
  cmd overlay destroy com.android.shell:splitA 2>/dev/null
else
  # module mode: two invocations, before / after
  case "$2" in
    before) say "before phase x$R"; i=1; while [ $i -le $R ]; do mkdir -p $D/A$i; home; grab $D/A$i; jankrun $D/A$i; i=$((i+1)); done; echo ok> $D/state ;;
    after)  [ -f $D/state ] || { say "FATAL: no before state"; exit 1; }
            V=$(cmd overlay lookup $P $P:bool/config_use_split_notification_shade 2>/dev/null)
            say "lookup after module install: $V"
            case "$V" in *false*) : ;; *) say "FAIL: overlay not active"; exit 2;; esac
            i=1; while [ $i -le $R ]; do mkdir -p $D/B$i; home; grab $D/B$i; jankrun $D/B$i; i=$((i+1)); done ;;
    *) say "module mode usage: $0 <rounds> before|after"; exit 1 ;;
  esac
fi

tar -czf $D.tar.gz -C $D . 2>/dev/null
say "host analysis: adb pull $D.tar.gz && for f in A1 B1 A2 B2...: shade-frame-audit.py trace ; compare shade release cadence medians"
