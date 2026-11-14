#!/bin/bash
# Host-side A/B harness for the iFive mini 4S HWC jank fix.
#
# Arms are switched by bind-mounting hwc/test/hal{base,strip}.so over
# /vendor/lib/hw/hwcomposer.rk30board.so + restarting the composer -
# this works on both the AOSP GSI and lineage WITHOUT Magisk (verified
# 2026-11-12 on lineage232: Magisk is not present in the restored boot,
# module installs never ran; bind+ctl.restart is the working path).
#
# Protocol per measured set: hwc/test/burst5.sh (re-injects + asserts
# >=12 notifications, expand/collapse via cmd statusbar - NEVER swipe
# close: it swipe-deletes notification cards mid-run and mutates the
# scene). burst4.sh is kept only for cross-checking old numbers.
#
# CRITICAL WORKFLOW RULES learned the hard way (see
# docs/jank-audit-2026-11-12.md):
#  - `adb root` breaks notification posting on lineage (NMS
#    fixNotification resolves the caller process name "root" ->
#    NameNotFoundException -> records silently dropped). All inject +
#    burst runs happen under `adb unroot` (plain shell uid 2000);
#    root is used only in short windows for bind/mount/setprop, then
#    we unroot again.
#  - `pkill` of the composer drags SystemUI/services down for minutes
#    ("Can't find service: input"). Only umount -l or fresh mount +
#    `setprop ctl.restart vendor.hwcomposer-2-1`, then sleep 35 s.
#  - Every result line carries the live .so md5 - the 12d-12j history
#    was lost because variants were not logged.
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
ADB=${ADB:-adb}
ADBD="$ADB -s ${SERIAL:-RK3288IFIVE01}"
R=$H/../out/tmp/jankwork/$(date +%m%d-%H%M)
mkdir -p "$R"
die() { echo "STOP: $*" >&2; exit 1; }
wait_composer() { # $1 = tag; device-side bounded poll until composer
  # shows a pid DIFFERENT from before restart (proves fresh HAL init, prop
  # re-read). Host side: one adb command, returns in <=8.4s or caller dies.
  S "p0=\$(pidof android.hardware.graphics.composer@2.1-service); setprop ctl.restart vendor.hwcomposer-2-1; for i in \$(seq 1 20); do sleep 0.4; p=\$(pidof android.hardware.graphics.composer@2.1-service); [ -n \"\$p\" ] && [ \"\$p\" != \"\$p0\" ] && echo WCRM-$1-\$p && break; done" 25 | grep -q "WCRM-$1"
}

S() { timeout "${2:-90}" $ADBD shell "$1" 2>&1; }
root_on()  { timeout 30 $ADBD root >/dev/null 2>&1 || return 1; }
root_off() { timeout 30 $ADBD unroot >/dev/null 2>&1 || return 1
  # unroot restarts adbd; settle with one bounded uid check (retry once,
  # no sleep/loop). Non-2000 after that -> caller dies with clear message.
  local u; u=$(timeout 15 $ADBD shell id -u 2>/dev/null | tr -dc 0-9)
  if [ "$u" != 2000 ]; then
    timeout 30 $ADBD unroot >/dev/null 2>&1
    u=$(timeout 15 $ADBD shell id -u 2>/dev/null | tr -dc 0-9)
  fi
  [ "$u" = 2000 ]
}

echo "-- device check"
$ADBD get-state >/dev/null 2>&1 || { echo "devices seen:"; timeout 5 adb devices; die "$ADBD not online (set SERIAL=)"; }

echo "-- verifying test inputs"
md5() { md5sum "$1" | cut -d' ' -f1; }
[ -f "$H/test/burst5.sh" ] && [ -f "$H/test/inject12.sh" ] || die "missing hwc/test scripts"
[ "$(md5 "$H/test/halbase.so")"  = b9fb394791788ec527945989baa959da ] || die "halbase.so md5 drifted: $(md5 "$H/test/halbase.so")"
[ "$(md5 "$H/test/halstrip.so")" = 6699bf1d15ca221f629fd99116c6bde2 ] || die "halstrip.so md5 drifted: $(md5 "$H/test/halstrip.so")"
timeout 60 $ADBD push "$H/test/burst5.sh" "$H/test/inject12.sh" \
  "$H/test/halbase.so" "$H/test/halstrip.so" /data/local/tmp/ >/dev/null \
  || die "push failed"
S "chmod 755 /data/local/tmp/burst5.sh /data/local/tmp/inject12.sh; test -x /data/local/tmp/burst5.sh && echo PUSH-OK" | grep -q PUSH-OK || die "push verify failed"

cur_md5() { S 'md5sum /vendor/lib/hw/hwcomposer.rk30board.so' 20 | cut -c1-32; }
bind_hal() { # $1 = file name under /data/local/tmp (halbase.so|halstrip.so)
  root_on
  S "chcon u:object_r:same_process_hal_file:s0 /data/local/tmp/halbase.so /data/local/tmp/halstrip.so 2>/dev/null; chmod 644 /data/local/tmp/hal*.so; umount -l /vendor/lib/hw/hwcomposer.rk30board.so 2>/dev/null; mount -o bind /data/local/tmp/$1 /vendor/lib/hw/hwcomposer.rk30board.so && echo MOUNT-OK || echo MOUNT-FAIL" | grep -q MOUNT-OK || die "bind $1 failed"
  wait_composer BH || die "composer restart not observed (bind $1)"
  root_off
  local got; got=$(cur_md5)
  local want; [ "$1" = halbase.so ] && want=b9fb394791788ec527945989baa959da || want=6699bf1d15ca221f629fd99116c6bde2
  [ "$got" = "$want" ] || die "after bind $1: /vendor md5=$got want=$want"
  echo "   bound $1 ($got) composer=$(S 'pidof android.hardware.graphics.composer@2.1-service' 15 | tr -dc 0-9)"
}
inj() { S 'sh /data/local/tmp/inject12.sh >/dev/null 2>&1; sh /data/local/tmp/inject12.sh 2>&1 | sed -n "s/^INJECTED=//p"' 90 | tr -dc 0-9; }
assert_shade() { # ensure >=12 before each measurement (idempotent tags)
    # adbd unroot is async: if we still land in a root shell, lineage drops
    # notification posts and INJECTED reads 0 - fail with an actionable
    # message instead of the misleading "scene not heavy" one.
    local u; u=$(S 'id -u' 10 | tr -dc 0-9)
    [ "$u" = 2000 ] || die "shell uid=$u (adbd still root) - rerun the script once"
    local n; n=$(inj)
    if [ "${n:-0}" -lt 12 ]; then
      # unroot-triggered USB state churn can drop notifications posted
      # microseconds after adbd restarts; re-post once (idempotent tags,
      # ~8s of natural round-trip spacing, no host sleep).
      n=$(inj)
    fi
    echo "   shade notifications: ${n:-?}"; [ "${n:-0}" -ge 12 ] || die "only ${n:-0} notifications - scene not heavy enough, aborting"
}
run_burst() { # $1 label  $2 protocol script (default burst5.sh)
    # HAL-log gate + framestat prop (needs one composer restart). This
    # root sandwich MUST run BEFORE assert_shade: adb root/unroot flap
    # clears shell-posted notifications, so posts have to come after it.
    root_on;  S 'setprop persist.sys.graphics.framestat_enabled true; setprop vendor.hwc.log 0; setprop ctl.restart vendor.hwcomposer-2-1' 15 >/dev/null
    root_off   # g_log_level is read at HAL init - restart applies the change
    assert_shade
    S 'logcat -c' 15 >/dev/null
  # GPU clock evidence (the lesson from the 2026-11-12 "pinned without
  # sampling" mistake): trans_stat before, 10 Hz cur_freq during, diff after.
  local t0; t0=$(S 'cat /sys/class/devfreq/ffa30000.gpu/trans_stat 2>/dev/null | head -4 | tr -s " " ' 20 | tr '\n' '|')
  S "nohup sh -c 'for i in \$(seq 1 400); do cat /sys/class/devfreq/ffa30000.gpu/cur_freq; sleep 0.1; done > /data/local/tmp/fq-$1.txt 2>/dev/null' >/dev/null 2>&1 &" 20 >/dev/null
  S 'dumpsys gfxinfo com.android.systemui reset' 20 >/dev/null
  S 'input keyevent KEYCODE_WAKEUP' 15 >/dev/null
  S "sh /data/local/tmp/${2:-burst5.sh}" 200 | tee -a "$R/$1.txt" | sed "s/^/   [$1] /"
  S 'dumpsys gfxinfo com.android.systemui' 40 | tee -a "$R/$1.txt" | grep -a -e "Janky" -e "percentile" -e "High input" -e "gpu perc" >/dev/null
  { echo "-- freq samples (10Hz):"; S "sort /data/local/tmp/fq-$1.txt | uniq -c | sort -rn" 30
    echo "-- trans_stat delta basis (before): $t0"
    echo "-- trans_stat (after):"; S 'cat /sys/class/devfreq/ffa30000.gpu/trans_stat 2>/dev/null' 20
    echo "-- governor at end:"; S 'cat /sys/class/devfreq/ffa30000.gpu/governor' 15
  } >> "$R/$1.txt" 2>&1
  echo "   [$1] .so=$(cur_md5 | cut -c1-8) freq/cur_freq + trans_stat appended to $R/$1.txt"
}
diag_burst() { # $1 label - one burst with HAL decision logging ON; counts
  # "go to GPU GLES"/"fail match after band merge"/"so big"/skip-all lines.
  root_on; S 'setprop vendor.hwc.log 63' 15 >/dev/null; wait_composer DIAG || die "composer restart not observed (diag)"
  # GPU reset-source counts at this moment (dmesg cumulative). Real driver
  # strings: job-hang path prints "Job has been on the GPU for too long"
  # (js_backend.c:257) + "Resetting GPU (allowing up to..." (jm_hw.c:1246);
  # power-on soft reset prints NOTHING (only failures print "Failed to
  # soft-/hard-reset"). So nonzero here => (b) job restart; zero here with
  # high mali_pm_census transitions => (a) PM ping-pong.
  S "dmesg | grep -icE 'Job has been on the GPU for too long'; dmesg | grep -icE 'Resetting GPU'; dmesg | grep -icE 'Failed to (soft|hard)-reset'" > "$R/$1.gpureset.txt" 2>&1
  root_off
  S 'logcat -c' 15 >/dev/null
  assert_shade
  S 'sh /data/local/tmp/burst5.sh >/dev/null 2>&1' 200 >/dev/null
  S 'logcat -d' 40 > "$R/$1.logcat.txt" 2>&1
      { echo "== HAL decision counts ($1) =="
      for k in "go to GPU GLES" "fail match after band merge" "is so big" "skip-all" "to set .is_afbc" "vop cann.t support first layer" "hwc_rk.*pair " "hwc_rk.*layer map id="; do
        printf "  %-40s %s\n" "$k" "$(grep -aEc "$k" "$R/$1.logcat.txt" 2>/dev/null)"
      done
      # group-size histogram = direct proof of the pair-merge running
      # (size>=2 counts should jump in A1d/A1e diag vs A1 diag)
      echo "  -- layer-map size distribution --"
      grep -a "layer map id=" "$R/$1.logcat.txt" 2>/dev/null | sed -n 's/.*size=\([0-9]*\).*/\1/p' | sort -n | uniq -c | sed 's/^/    /'
    } | tee -a "$R/$1.logcat.txt"
}
boost_kill() { # supervisor-proof: loop until no matches; governor check
  # NB: [d] bracket pattern - plain "gpubboostd" would also match the
  # wrapping `sh -c` process itself and pkill would kill its own shell.
  root_on
  S "for i in 1 2 3; do pkill -f gpubboost[d]; sleep 1; done" 30 >/dev/null
  local p; p=$(S 'pgrep -f gpubboost[d] | wc -l' 15 | tr -dc 0-9)
  [ "${p:-9}" = 0 ] || die "gpubboostd still running ($p procs) after 3 pkills"
  S 'echo simple_ondemand > /sys/class/devfreq/ffa30000.gpu/governor; cat /sys/class/devfreq/ffa30000.gpu/governor' 20 | grep -q simple_ondemand || die "governor not flipped to simple_ondemand"
  root_off
  echo "   boost OFF (daemon 0 procs, governor simple_ondemand)"
}
boost_on() { # start daemon like boot-complete.sh would
  root_on
  S 'pgrep -f gpubboost[d] >/dev/null || { setprop persist.vendor.hwc.vop.scale_trigger 6.5; setprop persist.vendor.hwc.vop.scale_limit 5.5; nohup /data/adb/modules/ifive-hwc-composition/gpubboostd >/dev/null 2>&1 & sleep 2; }' 30 >/dev/null
  local g; g=$(S 'cat /sys/class/devfreq/ffa30000.gpu/governor' 15 | tr -d '\r')
  root_off
  echo "   boost ON attempt: governor=$g (userspace = daemon took over)"
}

echo "=== T1 A3: BASE HAL, boost off ==="
bind_hal halbase.so;  boost_kill
for r in 1 2; do run_burst "A3-base-noBoost-r$r"; done
diag_burst "A3-diag"

echo "=== T1 A1: STRIP HAL, boost on (shipped combo) ==="
bind_hal halstrip.so; boost_on
for r in 1 2; do run_burst "A1-strip-boost-r$r"; done
diag_burst "A1-diag"

echo "=== T1 A2: STRIP HAL, boost off ==="
boost_kill
for r in 1 2; do run_burst "A2-strip-noBoost-r$r"; done

echo "=== T2 gate-off arm: STRIP + trigger=100 (reject merged shade scenes) ==="
boost_on
root_on; S 'setprop persist.vendor.hwc.vop.scale_trigger 100' 15 >/dev/null; root_off
for r in 1 2; do run_burst "B2-gate100-r$r"; done
root_on; S 'setprop persist.vendor.hwc.vop.scale_trigger 6.5' 15 >/dev/null; root_off

echo "=== recheck baseline drift (A1 again) ==="
for r in 3; do run_burst "A1-strip-boost-r$r"; done

echo "=== RECON equivalence arm: bind halrecon.so (md5 127b1134), compare vs A1 ==="
# bind_hal hardcodes the two shipped md5s; verify+bind recon explicitly.
root_on
S "chmod 644 /data/local/tmp/halrecon.so; chcon u:object_r:same_process_hal_file:s0 /data/local/tmp/halrecon.so 2>/dev/null; umount -l /vendor/lib/hw/hwcomposer.rk30board.so 2>/dev/null; mount -o bind /data/local/tmp/halrecon.so /vendor/lib/hw/hwcomposer.rk30board.so && setprop ctl.restart vendor.hwcomposer-2-1 && echo MOUNT-RECON" | grep -q MOUNT-RECON || die "halrecon bind failed"
root_off
got=$(cur_md5); [ "$got" = 127b1134bd139e1b599a6d19529ace55 ] || die "recon md5 drift: $got"
echo "   bound halrecon ($got)"
for r in 1 2; do run_burst "A1b-recon-boost-r$r"; done
echo "   compare A1b-* vs A1-* files: within ~3 pts jank => reconstruction equivalent"

# Second-round arm: activates automatically once halrecon2.so (merge-ported
# rebuild) exists in hwc/test/ - no script edit needed at that point.
RECON2="$H/test/halrecon2.so"
if [ -f "$RECON2" ]; then
  echo "=== A1d: halrecon2 (merge-ported rebuild) vs A1 ==="
  r2md5=$(md5 "$RECON2")
  timeout 60 $ADBD push "$RECON2" /data/local/tmp/halrecon2.so >/dev/null || die "recon2 push failed"
  root_on
  S "chmod 644 /data/local/tmp/halrecon2.so 2>/dev/null; chcon u:object_r:same_process_hal_file:s0 /data/local/tmp/halrecon2.so 2>/dev/null" 20 >/dev/null
  S "umount -l /vendor/lib/hw/hwcomposer.rk30board.so 2>/dev/null; mount -o bind /data/local/tmp/halrecon2.so /vendor/lib/hw/hwcomposer.rk30board.so && echo M2" | grep -q M2 || die "recon2 bind failed"
  wait_composer A1D || die "composer restart not observed (A1d)"
  root_off
  got=$(cur_md5); [ "$got" = "$r2md5" ] || die "recon2 md5: got=$got want=$r2md5"
  for r in 1 2; do run_burst "A1d-recon2-boost-r$r"; done
  diag_burst "A1d-diag"
else
  echo "(halrecon2.so not present - second-round arm skipped)"
fi

# Third-round lever arm: property-gated NONBLOCK atomic commit (halrecon3
# = halrecon2 + persist.vendor.hwc.nonblock_commit gate). Same bound file,
# toggle prop -> composer restart -> compare; t21 showed the composer
# binder thread D-blocks on vblank wait every present (396x/13.5s).
RECON3="$H/test/halrecon3.so"
if [ -f "$RECON3" ]; then
  echo "=== A1e: halrecon3 NONBLOCK prop toggle vs A1d ==="
  r3md5=$(md5 "$RECON3")
  timeout 60 $ADBD push "$RECON3" /data/local/tmp/halrecon3.so >/dev/null || die "recon3 push failed"
  root_on
  S "chmod 644 /data/local/tmp/halrecon3.so 2>/dev/null; chcon u:object_r:same_process_hal_file:s0 /data/local/tmp/halrecon3.so 2>/dev/null; setprop persist.vendor.hwc.nonblock_commit 0; umount -l /vendor/lib/hw/hwcomposer.rk30board.so 2>/dev/null; mount -o bind /data/local/tmp/halrecon3.so /vendor/lib/hw/hwcomposer.rk30board.so && echo M3" 20 | grep -q M3 || die "recon3 bind failed"
    wait_composer A1E || die "composer restart not observed (A1e)"
  root_off
  got=$(cur_md5); [ "$got" = "$r3md5" ] || die "recon3 md5: got=$got want=$r3md5"
  for r in 1 2; do run_burst "A1e-sync-r$r"; done
  root_on
  # device-side bounded poll (<=8s) until composer restart yields a NEW
  # pid - proves the HAL re-read the prop at init. Host single command.
  S "p0=\$(pidof android.hardware.graphics.composer@2.1-service); setprop persist.vendor.hwc.nonblock_commit 1; setprop ctl.restart vendor.hwcomposer-2-1; for i in \$(seq 1 20); do sleep 0.4; p=\$(pidof android.hardware.graphics.composer@2.1-service); [ -n \"\$p\" ] && [ \"\$p\" != \"\$p0\" ] && echo NB-READY-\$p && break; done" 25 | grep -q NB-READY || die "composer did not restart with new pid (nonblock=1)"
  root_off
  for r in 1 2; do run_burst "A1e-nonblock-r$r"; done
  root_on; S "setprop persist.vendor.hwc.nonblock_commit 0" 15 >/dev/null; root_off
  echo " compare A1e-sync vs A1e-nonblock (and vs A1d); watch for tearing"
else
  echo "(halrecon3.so not present - NONBLOCK toggle arm skipped)"
fi

echo "=== protocol bridge: burst6 (swipe-open, like the AOSP-era numbers) ==="
bind_hal halbase.so;  boost_kill
for r in 1 2; do run_burst "A3c-base-swipe-r$r" burst6.sh; done
bind_hal halstrip.so; boost_on
for r in 1 2; do run_burst "A1c-strip-swipe-r$r" burst6.sh; done
echo "   J(burst6) vs J(burst5) per arm = gesture contribution;"
echo "   A1c vs AOSP-era 6.9-7.2% = cross-build comparability check"

echo "=== T7 PM policy arm: power_policy=always_on vs A1 (same HAL, same boost) ==="
# demand policy gates GPU clock 800us after each idle tick -> per-frame
# L2 flush + power bring-up (+ soft reset on unpatched kernels). always_on
# removes that variable WITHOUT any kernel change; if A5 jank drops vs A1,
# the per-frame power cycle is a confirmed cost on the baseline rescue
# kernel too. power_policy sysfs attr: mali_kbase_core_linux.c:2375.
root_on
pol=$(S 'cat /sys/devices/platform/ffa30000.gpu/power_policy' 10 | tr -dc 'a-z_')
echo "  policy before: $pol"
S "echo always_on > /sys/devices/platform/ffa30000.gpu/power_policy 2>&1; cat /sys/devices/platform/ffa30000.gpu/power_policy" | sed 's/^/  pol-now: /'
S "echo 1 > /sys/kernel/tracing/tracing_on; echo 1 > /sys/kernel/tracing/events/sched/sched_blocked_reason/enable 2>/dev/null; echo > /sys/kernel/tracing/trace; true" 15 >/dev/null
root_off
for r in 1 2; do run_burst "A5-alwaysOn-r$r"; done
root_on
S "grep -c 'caller=kbase_pm_wait_for_reset' /sys/kernel/tracing/trace; grep -c 'wait_for_vblanks' /sys/kernel/tracing/trace; echo 0 > /sys/kernel/tracing/events/sched/sched_blocked_reason/enable 2>/dev/null; echo $pol > /sys/devices/platform/ffa30000.gpu/power_policy; cat /sys/devices/platform/ffa30000.gpu/power_policy" | tee "$R/A5.policy.txt" | sed 's/^/  /'
root_off
echo "   (line1=power_on count during always_on bursts, expect ~0; then restored policy)"

echo "DONE results=$R"
echo "restore note: binds vanish on reboot; setprops persist (trigger restored to 6.5 above)"
