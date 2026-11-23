#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
module="$dir/omnibook-battery-query.ko"
started=$(date '+%Y-%m-%d %H:%M:%S')
result=0
if [ "$#" -ne 0 ]; then
    printf 'Usage: %s (read-only)\n' "$0" >&2
    exit 2
fi
insmod "$module" || result=$?
if [ "$result" -eq 0 ]; then
    rmmod omnibook_battery_query || result=$?
fi
journalctl -k -b --since "$started" --no-pager -o cat -g '^omnibook_battery_query:'
exit "$result"
