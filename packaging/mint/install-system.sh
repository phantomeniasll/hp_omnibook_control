#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" -eq 0 ]
[ "$#" -eq 1 ]
[ "$(cat /sys/class/dmi/id/board_name)" = 8DA8 ]
[ "$(cat /sys/class/dmi/id/bios_version)" = F.11 ]
[ "$(modinfo -F name "$1")" = omnibook_fan_probe ]
release=$(uname -r)
version=$(modinfo -F vermagic "$1")
[ "${version%% *}" = "$release" ]
source=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
dest=/usr/local/lib/omnibook-fan-curves
service=omnibook-fan-curves.service

# Test module loading before installing anything. Curve mode starts in firmware automatic.
if [ ! -d /sys/module/omnibook_fan_probe ]; then
    if ! insmod "$1" curve=1; then
        printf 'Kernel rejected the module. Check sudo journalctl -k -n 30 and the Secure Boot section of the README.\n' >&2
        exit 1
    fi
    rmmod omnibook_fan_probe
fi

if systemctl is-active --quiet "$service"; then
    systemctl stop "$service"
fi
if [ -d /sys/module/omnibook_fan_probe ]; then
    rmmod omnibook_fan_probe
fi
install -d -m 0755 "$dest/$release" /usr/local/share/applications
install -m 0644 "$source/app/"*.py "$source/app/curves.json" "$dest/"
install -m 0755 "$source/app/"curve-python "$source/app/"open-curve-editor "$dest/"
install -m 0644 "$1" "$dest/$release/omnibook-fan-probe.ko"
install -m 0644 "$source/packaging/mint/$service" "/etc/systemd/system/$service"
install -m 0644 "$source/packaging/mint/hp-fan-curves.desktop" /usr/local/share/applications/
systemctl daemon-reload
systemctl enable --now "$service"
systemctl is-active "$service"
printf 'Open HP Fan Curves from the Cinnamon menu.\n'
