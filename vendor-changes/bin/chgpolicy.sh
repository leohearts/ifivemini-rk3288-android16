#!/vendor/bin/sh
# chgpolicy: raise ADP input current limit when conditions allow.
# Control: setprop persist.vendor.chg.boost on|off|auto   (default auto)
#   on   -> allowed
#   off  -> not allowed
#   auto -> allowed when ADP online, battery <40.0C, SoC <70C, capacity <95%
P=/sys/module/rn5t618_power/parameters/high_current_allowed
BAT=/sys/class/power_supply/rn5t618-battery
ADP=/sys/class/power_supply/rn5t618-adp
TZ=/sys/class/thermal/thermal_zone0/temp
DIR=/data/vendor/chg
LOG=$DIR/last.txt

rd() {
    v=$(cat "$1" 2>/dev/null)
    [ -n "$v" ] && echo "$v" || echo "$2"
}

mkdir -p "$DIR"
prev=""
while true; do
    boost=$(getprop persist.vendor.chg.boost auto)
    cap=$(rd $BAT/capacity 100)
    temp=$(rd $BAT/temp 9999)
    soc=$(rd $TZ 99999)
    online=$(rd $ADP/online 0)

    case "$boost" in
    on) allow=1 ;;
    off) allow=0 ;;
    *)
        if [ "$online" = 1 ] && [ "$temp" -lt 400 ] && [ "$soc" -lt 70000 ] && [ "$cap" -lt 95 ]; then
            allow=1
        else
            allow=0
        fi
        ;;
    esac

    if [ "$allow" != "$prev" ]; then
        cur=$(rd $P 0)
        [ "$cur" = "$allow" ] || echo "$allow" > $P
        s=$(wc -c < "$LOG" 2>/dev/null)
        [ "${s:-0}" -gt 65536 ] && : > "$LOG"
        echo "$(date '+%F %T') boost=$boost cap=$cap temp=$temp soc=$soc limit=$allow" >> "$LOG"
        prev=$allow
    fi
    sleep 30
done
