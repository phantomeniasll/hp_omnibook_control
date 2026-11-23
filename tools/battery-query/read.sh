#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
module="$dir/omnibook-battery-query.ko"
started=$(date '+%Y-%m-%d %H:%M:%S')
insmod "$module"
rmmod omnibook_battery_query
journalctl -k -b --since "$started" --no-pager -o cat -g '^omnibook_battery_query:'
