#!/bin/bash
# real3.sh <outdir> <rounds> : three real-use scenes, real gestures, no while/sleep.
#  recents : home (current rotation), KEYCODE_APP_SWITCH -> overview, HOME back       -> launcher3
#  drawer  : landscape home, swipe up -> app drawer, HOME back                          -> launcher3
#  shade   : landscape home, swipe down from top -> notification shade, swipe up closes -> systemui
A=$(cd "$(dirname "$0")/../.." && pwd)
export TMPDIR=${TMPDIR:-$A/out/tmp}; mkdir -p "$TMPDIR"
R=$1; N=${2:-8}; mkdir -p "$R"
S() { timeout 60 adb shell "$1" 2>/dev/null | tr -d '\r'; }
P() { S "ping -c $1 127.0.0.1 >/dev/null"; }
G='Total frames rendered|Janky frames:|50th percentile|90th percentile|95th percentile|99th percentile|Number Missed Vsync|Number High input latency|Number Slow UI thread|Number Slow bitmap|Number Slow issue draw|Number Frame deadline missed:|50th gpu|90th gpu'
scene() { # name pkg gesture-open gesture-close
    local name=$1 pkg=$2 open=$3 close=$4
    S "input keyevent KEYCODE_HOME"; P 3
    for i in 1 2; do S "$open"; P 2; S "$close"; P 2; done   # warm-up, not counted
    S "dumpsys gfxinfo $pkg reset >/dev/null; dumpsys SurfaceFlinger --timestats -clear -enable >/dev/null"
    for i in $(seq "$N"); do S "$open"; P 2; S "$close"; P 2; done
    echo "== $name ($pkg, $N rounds) top=$(S 'dumpsys activity activities' | grep -a -m1 topResumedActivity | grep -aoE '[a-z0-9.]+/[A-Za-z0-9.$]+')"
    S "dumpsys gfxinfo $pkg" > "$R/$name.gfx"
    grep -aE "$G" "$R/$name.gfx" | head -14 | sed 's/^ */  /'
    S "dumpsys SurfaceFlinger --timestats -dump" > "$R/$name.ts"
    grep -aE "^(totalFrames|missedFrames|clientCompositionFrames) " "$R/$name.ts" | tr '\n' ' '; echo
    S "dumpsys SurfaceFlinger --timestats -disable >/dev/null"
}
S "settings put system accelerometer_rotation 0; settings put system user_rotation 0"; P 3
scene recents com.android.launcher3 "input keyevent KEYCODE_APP_SWITCH" "input keyevent KEYCODE_HOME"
S "settings put system user_rotation 1"; P 4
echo "size after rotate: $(S 'dumpsys window displays' | grep -aoE 'cur=[0-9]+x[0-9]+' | head -1)"
scene drawer com.android.launcher3 "input swipe 1024 1350 1024 300 250" "input keyevent KEYCODE_HOME"
scene shade com.android.systemui "input swipe 1024 2 1024 1200 300" "input swipe 1024 1450 1024 100 250"
S "settings put system user_rotation 0; settings put system accelerometer_rotation 1"
echo "restored rot=$(S 'settings get system user_rotation') auto=$(S 'settings get system accelerometer_rotation')"
