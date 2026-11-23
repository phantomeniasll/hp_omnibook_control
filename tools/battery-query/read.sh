#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
module="$dir/omnibook-battery-query.ko"
started=$(date '+%Y-%m-%d %H:%M:%S')
result=0
if [ "${1:-}" = --test-inhibit ] && [ "$#" -eq 1 ]; then
    battery=/sys/class/power_supply/BAT0
    [ "$(cat "$battery/status")" = Charging ] || {
        printf 'The battery must be charging to measure a pause and resumption.\n' >&2
        exit 1
    }
    insmod "$module" test_inhibit=1 &
    probe=$!
    while kill -0 "$probe" 2>/dev/null; do
        printf '%s %s%% | %s | %s µW\n' "$(date +%T)" "$(cat "$battery/capacity")" \
            "$(cat "$battery/status")" "$(cat "$battery/power_now")"
        sleep 2
    done
    wait "$probe" || result=$?
elif [ "${1:-}" = --restore-after-test ] && [ "$#" -eq 1 ]; then
    insmod "$module" restore_after_test=1 || result=$?
    for field in capacity status power_now; do
        printf '%s: ' "$field"
        cat "/sys/class/power_supply/BAT0/$field"
    done
elif [ "$#" -eq 0 ]; then
    insmod "$module" || result=$?
else
    printf 'Usage: %s [--test-inhibit | --restore-after-test]\n' "$0" >&2
    exit 2
fi
if [ "$result" -eq 0 ]; then
    rmmod omnibook_battery_query || result=$?
fi
journalctl -k -b --since "$started" --no-pager -o cat -g '^omnibook_battery_query:'
exit "$result"
