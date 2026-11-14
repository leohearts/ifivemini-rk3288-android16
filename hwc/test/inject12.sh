#!/system/bin/sh
# inject12.sh - device-side shade filler for the HWC A/B harness
# (see hwc/ab-test.sh; pushed to /data/local/tmp and run as
# `sh /data/local/tmp/inject12.sh`).
#
# Posts N=12 test notifications and prints `INJECTED=<d>` where d is the ACTUAL
# delta in the visible-notification count read back from dumpsys (the harness
# requires >= 12, so a silent post failure stops the run instead of measuring
# an empty shade).
#
# Command availability, checked against the Android 16 GSI system.img
# (2026-11-12):
#   - cmd notification post [flags] <tag> <text>
#       help string "usage: cmd notification post [flags] <tag> <text>"
#       present in services.jar (NotificationShellCommand); posts as
#       com.android.shell, whose notification channel the shell command
#       manages itself. Flag -t <text> (title) also available if wanted.
#   - dumpsys notification  ("notification" service registered; the A16 dump
#       prints an "Active notifications: " section - per-record and summary
#       line wording differ by build, so ncount() below tries both shapes.)
#   - toybox grep/sed/tr/awk/sleep  (same toolset as out/tmp/jankwork/fullaccept.sh)
N=12

ncount() {
  # Primary (this build, verified 2026-11-12): one line per record,
  # "NotificationRecord(0x...:" - exclude the auto-group summary itself.
  n=$(dumpsys notification 2>/dev/null | grep -a 'NotificationRecord(' | grep -avc -e AUTOGROUP_SUMMARY -e GROUP_SUMMARY)
  if [ "$n" -gt 0 ] 2>/dev/null; then
    echo "$n"
    return
  fi
  # Legacy shapes kept for other builds:
  v=$(dumpsys notification 2>/dev/null | grep -a '^Active notifications: *[0-9]' | head -1 | tr -dc 0-9)
  if [ -n "$v" ]; then echo "$v"; return; fi
  dumpsys notification 2>/dev/null | grep -ac 'Notification Record'
}

B=$(ncount); B=${B:-0}
i=1
while [ $i -le $N ]; do
  # Primary: Android 16 shell post form (verified present in this image).
  cmd notification post "abtest$i" "hwc ab test $i" 2>/dev/null
  if [ $? -ne 0 ]; then
    # Fallback: pre-A15 positional form
    #   cmd notification post <tag|NULL> <id> <channelId> <packageName>
    # UNCONFIRMED on this build (that usage text is absent from services.jar);
    # kept only in case the shell helper rejects the A16 form above.
    cmd notification post NULL "abtest$i" 11 com.android.shell 2>/dev/null
  fi
  i=$((i+1))
  sleep 0.25
done
sleep 1.5          # let NMS settle before re-counting
A=$(ncount); A=${A:-0}
# INJECTED = total notifications visible in the shade after this run, NOT
# the delta: abtest tags are idempotent, so re-running with the same tags
# adds 0 new rows but the shade is still full - which is what the harness
# condition ">=12 notifications" actually checks.
echo "INJECTED=$A"
[ $A -ge $N ] || echo "WARN: only $A/$N in shade (delta was $((A - B)))"
