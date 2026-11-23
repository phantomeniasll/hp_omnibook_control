#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
service=omnibook-fan-curves.service
if [ -f "/etc/systemd/system/$service" ]; then
    systemctl disable --now "$service"
fi
if [ -d /sys/module/omnibook_fan_probe ]; then
    rmmod omnibook_fan_probe
fi
rm -f "/etc/systemd/system/$service" /usr/local/share/applications/hp-fan-curves.desktop
if [ -d /usr/local/lib/omnibook-fan-curves ]; then
    rm -r /usr/local/lib/omnibook-fan-curves
fi
systemctl daemon-reload
printf 'Removed the service and app. Saved curves are retained in /var/lib/omnibook-fan-curves.\n'
