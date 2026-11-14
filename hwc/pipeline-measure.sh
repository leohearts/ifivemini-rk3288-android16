#!/bin/bash
# pipeline-measure.sh - GPU/HWC pipeline measurement on the lineage
# device. Per user direction 2026-11-13 the fix path is optimizing the
# HWC/GPU processing pipeline, NOT reducing draw work - so the earlier
# animation-scaling / static-theme arms were REMOVED from this script
# (they measured the wrong thing).
#
# This script only measures, per arm:
#   A. current HAL (whichever is bound) + devfreq governor state
#      - cur_freq samples during bursts (is it ramping at all?)
#      - /sys/class/devfreq/ffa30000.gpu/trans_stat (up/down counters)
#      - devfreq load value if exposed
#   B. gfxinfo jank + SurfaceFlinger missed-frame delta (burst5 protocol)
#   C. atrace with the correct tag set + gfxinfo framestats
#
# Run after the mali polling fix kernel is flashed to compare arms:
#   stock governor behavior: A1 (before) vs A2 (after kernel swap)
#   boost daemon ON/OFF:     A1 (with gpubboostd) vs A3 (killed)
# All device writes here are /sys + setprop + adb settings only.
# NO partition writes, NO data changes. Inject/burst steps MUST run
# unrooted (root shell breaks lineage notification posting - see
# docs/jank-audit-2026-11-12.md).
set -u
S="timeout 60 adb shell"
R=/run/media/leohearts/Data/agentwork/ifivemini-rk3288-android16/out/tmp/jankwork/pipe-$(date +%m%d-%H%M)
mkdir -p "$R"
die() { echo "STOP: $*" >&2; exit 1; }

[ "$($S 'id -u' | tr -dc 0-9)" = 2000 ] || die "need unrooted adb shell for measurement (run adb unroot first)"

arm() { # $1 label
  echo "== $1 =="
  $S "md5sum /vendor/lib/hw/hwcomposer.rk30board.so | cut -c1-12" | sed 's/^/  hal: /'
  $S "cat /sys/class/devfreq/ffa30000.gpu/trans_stat" > "$R/$1.transstat.txt" 2>&1
  # sample cur_freq at 10 Hz across the whole burst
  $S "nohup sh -c 'for i in \$(seq 1 400); do cat /sys/class/devfreq/ffa30000.gpu/cur_freq; cat /sys/class/devfreq/ffa30000.gpu/load 2>/dev/null; done' > /data/local/tmp/fq.txt 2>/dev/null & " >/dev/null 2>&1
  $S "sh /data/local/tmp/inject12.sh >/dev/null 2>&1; dumpsys gfxinfo com.android.systemui reset >/dev/null; sh /data/local/tmp/burst5.sh" 2>&1 | tee "$R/$1.burst.txt" | sed 's/^/  /'
  $S "cat /data/local/tmp/fq.txt" > "$R/$1.freq.txt" 2>&1
  # post-burst trans_stat delta comes free: user diffs the two files
  $S "cat /sys/class/devfreq/ffa30000.gpu/trans_stat" >> "$R/$1.transstat.txt" 2>&1
  $S "dumpsys gfxinfo com.android.systemui framestats | tail -50" > "$R/$1.framestats.txt" 2>&1
  # dmesg proves WHERE the ~20/s kbase_pm_wait_for_reset events come from:
  # "soft reset" only at power transitions => PM ping-pong (raise
  # power-off-delay-ms in dts); "Job ... timed out" => job-slot restart path
  # (investigate JS timeout vs shader hang). Non-destructive read.
  $S "dmesg | grep -iE 'mali|kbase|gpu' | tail -120" > "$R/$1.dmesg.txt" 2>&1 || true
}

echo "results dir: $R"
echo "parse later with: python3 /run/media/leohearts/Data/agentwork/ifivemini-rk3288-android16/hwc/analyze-run.py $R (single consistent parser)"
echo "gpubboostd state at start: $($S 'getprop init.svc.gpubboostd')" | tee -a "$R/boostd.txt"
arm before

# Devfreq auto-ramp arm: same burst with the boost daemon stopped, so any
# frequency rise must come from the governor itself (todo #1 requirement).
# gpubboostd is a Magisk-module service (/data/adb/modules/ifive-hwc-
# composition/gpubboostd), NOT an init service: stop = pkill loop as root,
# restart = relaunch with the same props ab-test's boost_on uses.
echo "== stopping gpubboostd (pkill loop, volatile) =="
timeout 30 adb root >/dev/null 2>&1
timeout 30 adb shell "for i in 1 2 3; do pkill -f 'gpubboost[d]'; sleep 1; done; pgrep -f gpubboost[d] | wc -l" | tee -a "$R/boostd.txt"
timeout 30 adb unroot >/dev/null 2>&1
[ "$($S 'id -u' | tr -dc 0-9)" = 2000 ] || die "unroot failed before noboost arm"
arm noboost
timeout 30 adb root >/dev/null 2>&1
timeout 30 adb shell "pgrep -f gpubboost[d] >/dev/null || { setprop persist.vendor.hwc.vop.scale_trigger 6.5; setprop persist.vendor.hwc.vop.scale_limit 5.5; nohup /data/adb/modules/ifive-hwc-composition/gpubboostd >/dev/null 2>&1 & sleep 2; }; pgrep -f gpubboost[d] | wc -l" | tee -a "$R/boostd.txt"
timeout 30 adb unroot >/dev/null 2>&1

# Mali PM census v2: this kernel has NO events/mali class compiled in, so
# count D-state wait callers instead: kbase_pm_wait_for_reset occurrences
# = GPU resets (the exact thing the patched kernel must zero);
# wait_for_vblanks = present serialization count. tracefs only, volatile.
echo "== GPU/vblank wait census (sched_blocked_reason) =="
timeout 30 adb root >/dev/null 2>&1
timeout 20 adb shell "echo 1 > /sys/kernel/tracing/tracing_on; echo 1 > /sys/kernel/tracing/events/sched/sched_blocked_reason/enable 2>/dev/null; echo > /sys/kernel/tracing/trace; true"
timeout 30 adb unroot >/dev/null 2>&1
$S "dumpsys gfxinfo com.android.systemui reset >/dev/null; sh /data/local/tmp/burst5.sh" 2>&1 | tail -2 | sed 's/^/    /'
$S "dumpsys gfxinfo com.android.systemui" 2>/dev/null | grep -aE "Janky frames|Total frames" | sed 's/^/census gfxinfo: /' | tee "$R/census.gfx.txt" | sed 's/^/    /'
timeout 30 adb root >/dev/null 2>&1
timeout 20 adb shell "grep -c 'caller=kbase_pm_wait_for_reset' /sys/kernel/tracing/trace; grep -c 'wait_for_vblanks' /sys/kernel/tracing/trace; echo 0 > /sys/kernel/tracing/events/sched/sched_blocked_reason/enable 2>/dev/null" | tee "$R/mali_pm_census.txt" | sed 's/^/    /'
echo "    (line1=reset-waits line2=vblank-waits across the ~6s burst)"
# one 6s trace WITH drm+sync+binder categories, captured UNDER LOAD:
# t21 showed the present path waits vblank per commit but durations were
# unmeasurable (categories off). burst5 = input swipes only, safe rooted
# (the unrooted rule is for notification INJECT, not swipes).
echo "  capturing 6s drm/sync trace during burst..."
(timeout 40 adb shell "atrace -t 6 -b 16384 sched drm sync binder gfx input freq clk > /data/local/tmp/pipeline.drmtrace 2>/dev/null" ; echo "    atrace done") &
$S "sh /data/local/tmp/burst5.sh" 2>&1 | tail -1 | sed 's/^/    /'
timeout 60 adb shell "wc -c /data/local/tmp/pipeline.drmtrace; cat /data/local/tmp/pipeline.drmtrace" > "$R/pipeline.drmtrace.txt" 2>/dev/null || true
timeout 20 adb shell "rm /data/local/tmp/pipeline.drmtrace" 2>/dev/null
timeout 30 adb unroot >/dev/null 2>&1

# T8: deeper display buffer pipeline (volatile, clears on reboot). postAndWait
# p50 was only 2.5ms so this is a cheap check, not the main bet (see audit).
echo "== enabling SF triple buffering (service call 1008 i32 1) =="
timeout 30 adb root >/dev/null 2>&1
timeout 20 adb shell "service call SurfaceFlinger 1008 i32 1" >/dev/null 2>&1
timeout 30 adb unroot >/dev/null 2>&1
arm T8-triplebuffer
echo "== disabling triple buffering (back to 2) =="
timeout 30 adb root >/dev/null 2>&1
timeout 20 adb shell "service call SurfaceFlinger 1008 i32 0" >/dev/null 2>&1
timeout 30 adb unroot >/dev/null 2>&1

# one root-level dmesg covering the WHOLE run (buffer is cumulative; arm()
# unrooted captures may be permission-denied on recent kernels)
timeout 30 adb root >/dev/null 2>&1
timeout 30 adb shell "dmesg | grep -iE 'mali|kbase|gpu|reset' | tail -400" > "$R/full.dmesg.txt" 2>&1
timeout 30 adb unroot >/dev/null 2>&1
echo "full dmesg: $R/full.dmesg.txt ($(wc -l < "$R/full.dmesg.txt") lines)"

