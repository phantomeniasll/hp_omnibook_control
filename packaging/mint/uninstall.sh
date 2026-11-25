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
if [ -r /sys/module/omnibook_fan_probe/parameters/handoff ]; then
    for attempt in 1 2 3 4 5; do
        if [ "$(cat /sys/module/omnibook_fan_probe/parameters/handoff)" != recovering ]; then break; fi
        sleep 1
    done
fi
unload_failed=false
if [ -d /sys/module/omnibook_fan_probe ]; then
    if ! rmmod omnibook_fan_probe; then
        printf 'Warning: could not unload omnibook_fan_probe (still busy); reboot to clear it.\n' >&2
        unload_failed=true
    fi
fi
if [ -d /sys/module/omnibook_charge_control ]; then
    if ! rmmod omnibook_charge_control; then
        printf 'Warning: could not unload omnibook_charge_control (still busy); reboot to clear it.\n' >&2
        unload_failed=true
    fi
fi
rm -f "/etc/systemd/system/$service" "/etc/systemd/system/$battery_service" \
    "/etc/systemd/system/$socket" /etc/systemd/system/omnibook-control.service \
    /etc/systemd/system/omnibook-control@.service \
    /usr/local/share/applications/hp-fan-curves.desktop /usr/local/bin/hp-charge-limit \
    /etc/kernel/postinst.d/omnibook-fan-curves \
    /etc/kernel/header_postinst.d/omnibook-fan-curves \
    /etc/kernel/postrm.d/omnibook-fan-curves
if [ -d /usr/local/lib/omnibook-fan-curves ]; then
    rm -r /usr/local/lib/omnibook-fan-curves
fi
if [ -d /usr/share/cinnamon/applets/omnibook-thermal@omnibook ]; then
    rm -r /usr/share/cinnamon/applets/omnibook-thermal@omnibook
fi
systemctl daemon-reload
printf 'Removed the services, app, and panel applet. Saved preferences are retained in /var/lib/omnibook-fan-curves and /var/lib/omnibook-charge-limit.\n'
if "$unload_failed"; then
    exit 1
fi
