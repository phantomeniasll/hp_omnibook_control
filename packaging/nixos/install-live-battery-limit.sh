#!/bin/sh
set -eu
export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
[ "$#" -eq 2 ] || [ "$#" -eq 4 ] || {
    printf 'Use hp-install-live CHARGE_MODULE SHA256 [FAN_MODULE SHA256].\n' >&2
    exit 2
}
script=$(readlink -f -- "$0")
source=$(CDPATH= cd -- "$(dirname -- "$script")/../.." && pwd)
case "$source" in
    /nix/store/*-omnibook-fan-curves-*/share/omnibook-live-install) ;;
    *) printf 'Run hp-install-live from the built Nix package.\n' >&2; exit 1 ;;
esac
package=${source%/share/omnibook-live-install}
app="$package/libexec/omnibook-fan-curves"
python="$app/curve-python"
[ "$(cat /sys/class/dmi/id/board_name)" = 8DA8 ]
[ "$(cat /sys/class/dmi/id/sys_vendor)" = HP ]

dest=/usr/local/lib/omnibook-charge-limit
units=/usr/local/lib/systemd/system
battery=omnibook-charge-limit.service
fan=omnibook-fan-curves.service
socket=omnibook-control.socket
runner=omnibook-control.service
legacy=omnibook-control@.service
cli=/usr/local/bin/hp-charge-limit
battery_link="$units/multi-user.target.wants/$battery"
fan_link="$units/multi-user.target.wants/$fan"
socket_link="$units/sockets.target.wants/$socket"
managed_files="$units/$battery $units/$fan $units/$socket $units/$runner $units/$legacy $battery_link $fan_link $socket_link $cli"
uid=${SUDO_UID:-${PKEXEC_UID:-0}}
release=$(uname -r)
staging=$(mktemp -d /run/omnibook-stage.XXXXXX)
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
        systemctl stop "$socket" "$runner" "$fan" "$battery" 'omnibook-control@*.service' 2>/dev/null
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
        if "$old_charge"; then systemctl start "$battery" || rollback_ok=false; fi
        if ! "$rollback_ok"; then
            printf 'Live install failed and rollback reported an error. Backups are in %s.\n' "$staging" >&2
            exit "$result"
        fi
        printf 'Live install failed. Restored the previous installation.\n' >&2
    fi
    rm -rf -- "$staging"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
exec 9>/run/omnibook-install.lock
flock -x 9

stage_module() {
    "$python" "$source/packaging/stage-module.py" "$1" "$2" "$uid" "$3"
    [ "$(modinfo -F name "$2")" = "$4" ]
    version=$(modinfo -F vermagic "$2")
    [ "${version%% *}" = "$release" ]
}
next="$staging/new-app"
install -d -m755 "$next/$release"
charge_module="$next/$release/omnibook-charge-control.ko"
fan_module="$next/$release/omnibook-fan-probe.ko"
stage_module "$1" "$charge_module" "$2" omnibook_charge_control
if [ "$#" -eq 4 ]; then
    stage_module "$3" "$fan_module" "$4" omnibook_fan_probe
    systemctl is-active --quiet "$fan" && old_fan=true
fi
install -m644 "$app/"*.py "$app/curves.json" "$next/"
systemctl is-active --quiet "$battery" && old_charge=true
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

for file in $managed_files; do
    if [ -e "$file" ] || [ -L "$file" ]; then
        install -d -m700 "$(dirname -- "$staging/previous$file")"
        cp -a -- "$file" "$staging/previous$file"
    fi
done

swapping=true
if "$old_socket"; then systemctl stop "$socket"; fi
if systemctl is-active --quiet "$runner"; then systemctl stop "$runner"; fi
systemctl stop 'omnibook-control@*.service'
if "$old_fan"; then systemctl stop "$fan"; fi
if "$old_charge"; then systemctl stop "$battery"; fi
if [ -d /sys/module/omnibook_charge_control ]; then rmmod omnibook_charge_control; fi
insmod "$charge_module"
rmmod omnibook_charge_control
if [ -f "$fan_module" ]; then
    if [ -d /sys/module/omnibook_fan_probe ]; then rmmod omnibook_fan_probe; fi
    insmod "$fan_module" curve=1
    rmmod omnibook_fan_probe
fi

install -d -m755 /usr/local/lib "$units/multi-user.target.wants" \
    "$units/sockets.target.wants" /usr/local/bin
if [ -e "$dest" ] || [ -L "$dest" ]; then
    mv -T -- "$dest" "$staging/previous-app"
fi
mv -T -- "$next" "$dest"
ln -sfn "$package" /nix/var/nix/gcroots/omnibook-live-backend

groupadd --force --system omnibook-control
account=$(getent passwd "$uid" | cut -d: -f1)
if [ -n "$account" ] && [ "$account" != root ]; then
    usermod -aG omnibook-control "$account"
fi
for file in "$socket" "$runner" "$battery"; do
    install -m644 "$source/packaging/mint/$file" "$units/$file"
    sed -i "s|/usr/local/lib/omnibook-fan-curves/curve-python|$python|; s|/usr/local/lib/omnibook-fan-curves/|$dest/|" "$units/$file"
done
rm -f -- "$units/$legacy"
ln -sfn "../$socket" "$socket_link"
ln -sfn "../$battery" "$battery_link"

if [ -f "$dest/$release/omnibook-fan-probe.ko" ]; then
    install -m644 "$source/packaging/mint/$fan" "$units/$fan"
    sed -i "s|/usr/local/lib/omnibook-fan-curves/curve-python|$python|; s|/usr/local/lib/omnibook-fan-curves/|$dest/|" "$units/$fan"
    ln -sfn "../$fan" "$fan_link"
fi
cat > "$cli" <<EOF
#!/bin/sh
exec "$python" "$dest/battery_limit.py" "\$@"
EOF
chmod 755 "$cli"

systemctl daemon-reload
systemctl start "$socket" "$battery"
if [ -f "$dest/$release/omnibook-fan-probe.ko" ]; then systemctl start "$fan"; fi
"$python" "$dest/control_runner.py" check
if [ -n "$account" ] && [ "$account" != root ] && command -v setfacl >/dev/null; then
    setfacl -m "u:$account:rw" /run/omnibook-control.sock
fi
printf 'OmniBook controls are installed.\n'
