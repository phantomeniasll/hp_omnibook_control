#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" -eq 0 ]
[ "$#" -eq 4 ] || { [ "$#" -eq 3 ] && [ "$3" = --without-charge ]; }
[ "$(cat /sys/class/dmi/id/board_name)" = 8DA8 ]
[ "$(cat /sys/class/dmi/id/sys_vendor)" = HP ]
release=$(uname -r)
source=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
dest=/usr/local/lib/omnibook-fan-curves
service=omnibook-fan-curves.service
battery_service=omnibook-charge-limit.service
socket=omnibook-control.socket
staging=$(mktemp -d /run/omnibook-stage.XXXXXX)
trap 'rm -rf -- "$staging"' EXIT
fan_module="$staging/omnibook-fan-probe.ko"
charge_module="$staging/omnibook-charge-control.ko"
uid=${SUDO_UID:-0}

stage_module() {
    /usr/bin/python3 "$source/packaging/stage-module.py" "$1" "$2" "$uid" "$3"
    [ "$(modinfo -F name "$2")" = "$4" ]
    version=$(modinfo -F vermagic "$2")
    [ "${version%% *}" = "$release" ]
}

stage_module "$1" "$fan_module" "$2" omnibook_fan_probe
if [ "$#" -eq 4 ]; then
    stage_module "$3" "$charge_module" "$4" omnibook_charge_control
fi

old_fan=false
old_charge=false
old_socket=false
systemctl is-active --quiet "$service" && old_fan=true
systemctl is-active --quiet "$battery_service" && old_charge=true
systemctl is-active --quiet "$socket" && old_socket=true
cleanup() {
    result=$?
    rm -rf -- "$staging"
    if [ "$result" -ne 0 ]; then
        if "$old_socket"; then systemctl start "$socket" || true; fi
        if "$old_fan"; then systemctl start "$service" || true; fi
        if "$old_charge"; then systemctl start "$battery_service" || true; fi
    fi
}
trap cleanup EXIT

if "$old_fan"; then
    systemctl stop "$service"
fi
if "$old_charge"; then
    systemctl stop "$battery_service"
fi
if "$old_socket"; then
    systemctl stop "$socket" 'omnibook-control@*.service'
fi
if [ -d /sys/module/omnibook_fan_probe ]; then
    rmmod omnibook_fan_probe
fi
if [ -d /sys/module/omnibook_charge_control ]; then
    rmmod omnibook_charge_control
fi
# Load each staged module before installing those same bytes.
# Module initialization leaves control with HP.
if ! insmod "$fan_module" curve=1; then
    printf 'Kernel rejected the module. Check sudo journalctl -k -n 30 and the Secure Boot section of the README.\n' >&2
    exit 1
fi
rmmod omnibook_fan_probe

if [ -f "$charge_module" ]; then
    insmod "$charge_module"
    rmmod omnibook_charge_control
fi

install -d -m 0755 "$dest/$release" /usr/local/share/applications
install -m 0644 "$source/app/"*.py "$source/app/curves.json" "$dest/"
install -m 0755 "$source/app/"curve-python "$source/app/"open-curve-editor "$dest/"
install -m 0644 "$fan_module" "$dest/$release/omnibook-fan-probe.ko"
install -m 0644 "$source/packaging/mint/$service" "/etc/systemd/system/$service"
groupadd --force --system omnibook-control
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    usermod -aG omnibook-control "$SUDO_USER"
fi
install -m 0644 "$source/packaging/mint/$socket" \
    "$source/packaging/mint/omnibook-control@.service" /etc/systemd/system/
install -m 0644 "$source/packaging/mint/hp-fan-curves.desktop" /usr/local/share/applications/
if [ -f "$charge_module" ]; then
    install -m 0644 "$charge_module" "$dest/$release/omnibook-charge-control.ko"
    install -Dm755 "$source/packaging/mint/hp-charge-limit" /usr/local/bin/hp-charge-limit
    install -m 0644 "$source/packaging/mint/$battery_service" "/etc/systemd/system/$battery_service"
else
    if [ -f "/etc/systemd/system/$battery_service" ]; then
        systemctl disable "$battery_service"
    fi
    rm -f "/etc/systemd/system/$battery_service" /usr/local/bin/hp-charge-limit
    find "$dest" -mindepth 2 -maxdepth 2 -type f -name omnibook-charge-control.ko -delete
fi
systemctl daemon-reload
systemctl enable --now "$socket"
systemctl enable --now "$service"
if [ -f "$charge_module" ]; then
    systemctl enable --now "$battery_service"
fi
systemctl is-active "$service"
printf 'Sign out and back in to activate group access, then open HP Fan Curves from the Cinnamon menu.\n'
