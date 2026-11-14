#!/system/bin/sh
# inject12b.sh - loop-free variant of inject12.sh (owner rule: no while/sleep).
# 12 explicit idempotent posts, a fixed ping pause instead of sleep, then the
# same shade-record count. Prints INJECTED=<total visible records>.
cmd notification post "abtest1" "hwc ab test 1"  >/dev/null 2>&1
cmd notification post "abtest2" "hwc ab test 2"  >/dev/null 2>&1
cmd notification post "abtest3" "hwc ab test 3"  >/dev/null 2>&1
cmd notification post "abtest4" "hwc ab test 4"  >/dev/null 2>&1
cmd notification post "abtest5" "hwc ab test 5"  >/dev/null 2>&1
cmd notification post "abtest6" "hwc ab test 6"  >/dev/null 2>&1
cmd notification post "abtest7" "hwc ab test 7"  >/dev/null 2>&1
cmd notification post "abtest8" "hwc ab test 8"  >/dev/null 2>&1
cmd notification post "abtest9" "hwc ab test 9"  >/dev/null 2>&1
cmd notification post "abtest10" "hwc ab test 10" >/dev/null 2>&1
cmd notification post "abtest11" "hwc ab test 11" >/dev/null 2>&1
cmd notification post "abtest12" "hwc ab test 12" >/dev/null 2>&1
ping -c 2 127.0.0.1 >/dev/null 2>&1
n=$(dumpsys notification 2>/dev/null | grep -a 'NotificationRecord(' | grep -avc -e AUTOGROUP_SUMMARY -e GROUP_SUMMARY)
echo "INJECTED=${n:-0}"
