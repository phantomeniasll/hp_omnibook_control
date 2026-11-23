#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
service=omnibook-fan-curves.service
battery_service=omnibook-charge-limit.service
socket=omnibook-control.socket
if [ -f "/etc/systemd/system/$socket" ]; then
    systemctl disable --now "$socket"
    systemctl stop omnibook-control.service 'omnibook-control@*.service' 2>/dev/null || true
fi
if [ -f "/etc/systemd/system/$service" ]; then
    systemctl disable --now "$service"
fi
if [ -f "/etc/systemd/system/$battery_service" ]; then
    systemctl disable --now "$battery_service"
fi
if [ -d /sys/module/omnibook_fan_probe ]; then
    rmmod omnibook_fan_probe
fi
if [ -d /sys/module/omnibook_charge_control ]; then
    rmmod omnibook_charge_control
fi
rm -f "/etc/systemd/system/$service" "/etc/systemd/system/$battery_service" \
    "/etc/systemd/system/$socket" /etc/systemd/system/omnibook-control.service \
    /etc/systemd/system/omnibook-control@.service \
    /usr/local/share/applications/hp-fan-curves.desktop /usr/local/bin/hp-charge-limit
if [ -d /usr/local/lib/omnibook-fan-curves ]; then
    rm -r /usr/local/lib/omnibook-fan-curves
fi
systemctl daemon-reload
printf 'Removed the service and app. Saved curves are retained in /var/lib/omnibook-fan-curves.\n'
