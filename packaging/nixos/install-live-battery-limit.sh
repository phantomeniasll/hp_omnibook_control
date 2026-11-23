#!/bin/sh
set -eu
export PATH=/run/current-system/sw/bin
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
uid=${SUDO_UID:-${PKEXEC_UID:-0}}
release=$(uname -r)
staging=$(mktemp -d /run/omnibook-stage.XXXXXX)
old_fan=false
old_charge=false
old_socket=false
cleanup() {
    result=$?
    rm -rf -- "$staging"
    if [ "$result" -ne 0 ]; then
        if "$old_socket"; then systemctl start "$socket" || true; fi
        if "$old_fan"; then systemctl start "$fan" || true; fi
        if "$old_charge"; then systemctl start "$battery" || true; fi
    fi
}
trap cleanup EXIT
exec 9>/run/omnibook-install.lock
flock -x 9

stage_module() {
    "$python" "$source/packaging/stage-module.py" "$1" "$2" "$uid" "$3"
    [ "$(modinfo -F name "$2")" = "$4" ]
    version=$(modinfo -F vermagic "$2")
    [ "${version%% *}" = "$release" ]
}
charge_module="$staging/omnibook-charge-control.ko"
fan_module="$staging/omnibook-fan-probe.ko"
stage_module "$1" "$charge_module" "$2" omnibook_charge_control
if [ "$#" -eq 4 ]; then
    stage_module "$3" "$fan_module" "$4" omnibook_fan_probe
    systemctl is-active --quiet "$fan" && old_fan=true
fi
systemctl is-active --quiet "$battery" && old_charge=true
systemctl is-active --quiet "$socket" && old_socket=true

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

install -d -m755 "$dest/$release" "$units/multi-user.target.wants" \
    "$units/sockets.target.wants" /usr/local/bin
install -m644 "$app/"*.py "$app/curves.json" "$dest/"
install -m644 "$charge_module" "$dest/$release/omnibook-charge-control.ko"
if [ -f "$fan_module" ]; then
    install -m644 "$fan_module" "$dest/$release/omnibook-fan-probe.ko"
fi
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
rm -f -- "$units/omnibook-control@.service"
ln -sfn "../$socket" "$units/sockets.target.wants/$socket"
ln -sfn "../$battery" "$units/multi-user.target.wants/$battery"

if [ -f "$fan_module" ]; then
    install -m644 "$source/packaging/mint/$fan" "$units/$fan"
    sed -i "s|/usr/local/lib/omnibook-fan-curves/curve-python|$python|; s|/usr/local/lib/omnibook-fan-curves/|$dest/|" "$units/$fan"
    ln -sfn "../$fan" "$units/multi-user.target.wants/$fan"
fi
cat > /usr/local/bin/hp-charge-limit <<EOF
#!/bin/sh
exec "$python" "$dest/battery_limit.py" "\$@"
EOF
chmod 755 /usr/local/bin/hp-charge-limit

systemctl daemon-reload
systemctl start "$socket" "$battery"
"$python" "$dest/control_runner.py" check
if [ -f "$fan_module" ]; then systemctl start "$fan"; fi
if [ -n "$account" ] && [ "$account" != root ] && command -v setfacl >/dev/null; then
    setfacl -m "u:$account:rw" /run/omnibook-control.sock
fi
printf 'OmniBook controls are installed.\n'
