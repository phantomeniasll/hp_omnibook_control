#!/bin/sh
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[ "$(id -u)" -eq 0 ]
[ "$#" -eq 4 ] || { [ "$#" -eq 3 ] && [ "$3" = --without-charge ]; }
[ "$(cat /sys/class/dmi/id/board_name)" = 8DA8 ]
[ "$(cat /sys/class/dmi/id/sys_vendor)" = HP ]
source=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
case "$source" in /run/omnibook-release.*/source) ;; *) exit 1 ;; esac
[ "$(stat -c '%u:%a' "$(dirname -- "$source")")" = 0:700 ]

release=$(uname -r)
dest=/usr/local/lib/omnibook-fan-curves
units=/etc/systemd/system
fan=omnibook-fan-curves.service
charge=omnibook-charge-limit.service
socket=omnibook-control.socket
listener=omnibook-control.service
legacy=omnibook-control@.service
desktop=/usr/local/share/applications/hp-fan-curves.desktop
cli=/usr/local/bin/hp-charge-limit
applet_uuid=omnibook-thermal@omnibook
applet_dest="/usr/share/cinnamon/applets/$applet_uuid"
kpostinst=/etc/kernel/postinst.d/omnibook-fan-curves
khpostinst=/etc/kernel/header_postinst.d/omnibook-fan-curves
kpostrm=/etc/kernel/postrm.d/omnibook-fan-curves
fan_link="$units/multi-user.target.wants/$fan"
charge_link="$units/multi-user.target.wants/$charge"
socket_link="$units/sockets.target.wants/$socket"
managed_files="$units/$fan $units/$charge $units/$socket $units/$listener $units/$legacy $desktop $cli $kpostinst $khpostinst $kpostrm $fan_link $charge_link $socket_link"

install -d -m755 /usr/local/lib
staging=$(mktemp -d /usr/local/lib/.omnibook-upgrade.XXXXXX)
swapping=false
old_fan=false
old_charge=false
old_socket=false
cleanup() {
    result=$?
    trap - EXIT
    if [ "$result" -ne 0 ] && "$swapping"; then
        set +e
        rollback_ok=true
        systemctl stop "$socket" "$listener" "$fan" "$charge" 'omnibook-control@*.service' 2>/dev/null
        for driver in omnibook_fan_probe omnibook_charge_control; do
            if [ -d "/sys/module/$driver" ]; then
                rmmod "$driver" || rollback_ok=false
            fi
        done
        if [ -e "$staging/previous-app" ] || [ -L "$staging/previous-app" ]; then
            rm -rf -- "$dest" && mv -T -- "$staging/previous-app" "$dest" || rollback_ok=false
        elif [ ! -e "$staging/new-app" ]; then
            rm -rf -- "$dest" || rollback_ok=false
        fi
        if [ -e "$staging/previous-applet" ] || [ -L "$staging/previous-applet" ]; then
            rm -rf -- "$applet_dest" && mv -T -- "$staging/previous-applet" "$applet_dest" || rollback_ok=false
        elif [ ! -e "$staging/new-applet" ]; then
            rm -rf -- "$applet_dest" || rollback_ok=false
        fi
        for file in $managed_files; do
            rm -f -- "$file" || rollback_ok=false
            saved="$staging/previous$file"
            if [ -e "$saved" ] || [ -L "$saved" ]; then
                cp -a -- "$saved" "$file" || rollback_ok=false
            fi
        done
        systemctl daemon-reload || rollback_ok=false
        if "$old_socket"; then systemctl start "$socket" || rollback_ok=false; fi
        if "$old_fan"; then systemctl start "$fan" || rollback_ok=false; fi
        if "$old_charge"; then systemctl start "$charge" || rollback_ok=false; fi
        if ! "$rollback_ok"; then
            printf 'Upgrade failed and rollback reported an error. Backups are in %s.\n' "$staging" >&2
            exit "$result"
        fi
        printf 'Upgrade failed. Restored the previous installation.\n' >&2
    fi
    rm -rf -- "$staging"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
exec 9>/run/omnibook-install.lock
flock -x 9

next="$staging/new-app"
install -d -m755 "$next/$release" "$staging/units"
stage_module() {
    /usr/bin/python3 "$source/packaging/stage-module.py" "$1" "$2" "${SUDO_UID:-0}" "$3"
    [ "$(modinfo -F name "$2")" = "$4" ]
    version=$(modinfo -F vermagic "$2")
    [ "${version%% *}" = "$release" ]
    chmod 644 "$2"
}

fan_module="$next/$release/omnibook-fan-probe.ko"
charge_module="$next/$release/omnibook-charge-control.ko"
stage_module "$1" "$fan_module" "$2" omnibook_fan_probe
if [ "$#" -eq 4 ]; then
    stage_module "$3" "$charge_module" "$4" omnibook_charge_control
fi
install -m644 "$source/app/"*.py "$source/app/curves.json" "$next/"
install -m755 "$source/app/curve-python" "$source/app/open-curve-editor" "$source/app/thermal" "$next/"
install -d -m755 "$next/driver-src"
install -m644 "$source/driver/Makefile" "$source/driver/"*.c "$source/driver/"*.h \
    "$source/driver/"*.asl "$next/driver-src/"
install -d -m755 "$staging/new-applet"
install -m644 "$source/packaging/mint/cinnamon-applet/$applet_uuid/"* "$staging/new-applet/"
install -m644 "$source/packaging/mint/$fan" "$source/packaging/mint/$charge" \
    "$source/packaging/mint/$socket" "$source/packaging/mint/$listener" "$staging/units/"
install -m644 "$source/packaging/mint/hp-fan-curves.desktop" "$staging/desktop"
install -m755 "$source/packaging/mint/hp-charge-limit" "$staging/cli"
install -m755 "$source/packaging/mint/kernel-postinst" "$staging/kpostinst"
install -m755 "$source/packaging/mint/kernel-postrm" "$staging/kpostrm"
# Compile without writing bytecode into the installation.
/usr/bin/python3 -c 'from pathlib import Path; import sys
for path in Path(sys.argv[1]).glob("*.py"):
    compile(path.read_bytes(), str(path), "exec")
' "$next"

for file in $managed_files; do
    if [ -e "$file" ] || [ -L "$file" ]; then
        install -d -m700 "$(dirname -- "$staging/previous$file")"
        cp -a -- "$file" "$staging/previous$file"
    fi
done
systemctl is-active --quiet "$fan" && old_fan=true
systemctl is-active --quiet "$charge" && old_charge=true
systemctl is-active --quiet "$socket" && old_socket=true

if [ -r /sys/module/omnibook_fan_probe/parameters/handoff ]; then
    for attempt in 1 2 3 4 5; do
        if [ "$(cat /sys/module/omnibook_fan_probe/parameters/handoff)" != recovering ]; then break; fi
        sleep 1
    done
    if [ "$(cat /sys/module/omnibook_fan_probe/parameters/handoff)" = recovering ]; then
        printf 'Fan driver is still recovering automatic control; try the upgrade again shortly.\n' >&2
        exit 1
    fi
fi

swapping=true
if "$old_socket"; then systemctl stop "$socket"; fi
if systemctl is-active --quiet "$listener"; then systemctl stop "$listener"; fi
systemctl stop 'omnibook-control@*.service'
if "$old_fan"; then systemctl stop "$fan"; fi
if "$old_charge"; then systemctl stop "$charge"; fi
for driver in omnibook_fan_probe omnibook_charge_control; do
    if [ -d "/sys/module/$driver" ]; then rmmod "$driver"; fi
done
# Load and unload the staged bytes before replacing the previous installation.
insmod "$fan_module" curve=1
rmmod omnibook_fan_probe
if [ -f "$charge_module" ]; then
    insmod "$charge_module"
    rmmod omnibook_charge_control
fi

if [ -e "$dest" ] || [ -L "$dest" ]; then
    mv -T -- "$dest" "$staging/previous-app"
fi
mv -T -- "$next" "$dest"
install -d -m755 /usr/share/cinnamon/applets
if [ -e "$applet_dest" ] || [ -L "$applet_dest" ]; then
    mv -T -- "$applet_dest" "$staging/previous-applet"
fi
mv -T -- "$staging/new-applet" "$applet_dest"
groupadd --force --system omnibook-control
install -d -m755 /usr/local/share/applications /usr/local/bin \
    /etc/kernel/postinst.d /etc/kernel/header_postinst.d /etc/kernel/postrm.d \
    "$units/multi-user.target.wants" "$units/sockets.target.wants"
for unit in "$fan" "$socket" "$listener"; do
    install -m644 "$staging/units/$unit" "$units/$unit"
done
rm -f -- "$units/$legacy"
install -m644 "$staging/desktop" "$desktop"
install -m755 "$staging/kpostinst" "$kpostinst"
install -m755 "$staging/kpostinst" "$khpostinst"
install -m755 "$staging/kpostrm" "$kpostrm"
if [ -f "$dest/$release/omnibook-charge-control.ko" ]; then
    install -m644 "$staging/units/$charge" "$units/$charge"
    install -m755 "$staging/cli" "$cli"
    ln -sfn "../$charge" "$charge_link"
else
    rm -f -- "$units/$charge" "$charge_link" "$cli"
fi
ln -sfn "../$fan" "$fan_link"
ln -sfn "../$socket" "$socket_link"
systemctl daemon-reload
systemctl start "$fan"
if [ -f "$units/$charge" ]; then systemctl start "$charge"; fi
systemctl start "$socket"
"$dest/curve-python" "$dest/control_runner.py" check
for service in "$fan" "$charge"; do
    if [ ! -f "$units/$service" ]; then continue; fi
    for attempt in 1 2 3 4 5; do
        if [ -s "/run/${service%.service}/status.json" ]; then break; fi
        sleep 1
    done
    systemctl is-active --quiet "$service"
    [ -s "/run/${service%.service}/status.json" ]
done
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    usermod -aG omnibook-control "$SUDO_USER"
fi
printf 'Sign out and back in to activate group access, then open HP Fan Curves from the Cinnamon menu or add the HP Thermal & Battery panel applet.\n'
