#!/bin/sh
set -eu
export PATH=/run/current-system/sw/bin
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
[ "$#" -eq 2 ] || { printf 'Pass the absolute Nix Python path and the approved module SHA-256.\n' >&2; exit 1; }
python=$1
case "$python" in /nix/store/*/bin/python3|/nix/store/*/bin/python3.*) ;; *) exit 1 ;; esac
[ -x "$python" ]
[ "$(cat /sys/class/dmi/id/board_name)" = 8DA8 ]
[ "$(cat /sys/class/dmi/id/sys_vendor)" = HP ]
source=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
staging=$(mktemp -d /run/omnibook-stage.XXXXXX)
trap 'rm -rf -- "$staging"' EXIT
module="$staging/omnibook-charge-control.ko"
"$python" "$source/packaging/stage-module.py" "$source/driver/omnibook-charge-control.ko" \
    "$module" "${SUDO_UID:-${PKEXEC_UID:-0}}" "$2"
release=$(uname -r)
version=$(modinfo -F vermagic "$module")
[ "${version%% *}" = "$release" ]
[ "$(modinfo -F name "$module")" = omnibook_charge_control ]

dest=/usr/local/lib/omnibook-charge-limit
units=/usr/local/lib/systemd/system
service=omnibook-charge-limit.service
socket=omnibook-control.socket
old_charge=false
old_socket=false
systemctl is-active --quiet "$service" && old_charge=true
systemctl is-active --quiet "$socket" && old_socket=true
cleanup() {
    result=$?
    rm -rf -- "$staging"
    if [ "$result" -ne 0 ]; then
        if "$old_charge"; then systemctl start "$service" || true; fi
        if "$old_socket"; then systemctl start "$socket" || true; fi
    fi
}
trap cleanup EXIT
if "$old_charge"; then
    systemctl stop "$service"
fi
if [ -d /sys/module/omnibook_charge_control ]; then
    rmmod omnibook_charge_control
fi
insmod "$module"
rmmod omnibook_charge_control
if systemctl is-active --quiet "$socket"; then
    systemctl stop "$socket" 'omnibook-control@*.service'
fi
install -d -m755 "$dest/$release" "$units/multi-user.target.wants" \
    "$units/sockets.target.wants" /usr/local/bin \
    /var/lib/omnibook-charge-limit
install -m644 "$source/app/battery_limit.py" "$source/app/curve_control.py" \
    "$source/app/control_runner.py" "$source/app/temperature_status.py" \
    "$source/app/curves.json" "$dest/"
install -m644 "$module" "$dest/$release/omnibook-charge-control.ko"
python_store=${python%/bin/*}
ln -sfn "$python_store" /nix/var/nix/gcroots/omnibook-charge-limit-python
sed -i 's|"/usr/sbin"|"/run/current-system/sw/bin"|' "$dest/curve_control.py"
groupadd --force --system omnibook-control
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    usermod -aG omnibook-control "$SUDO_USER"
fi
install -m644 "$source/packaging/mint/$socket" "$units/$socket"
runner=omnibook-control@.service
install -m644 "$source/packaging/mint/$runner" "$units/$runner"
sed -i "s|/usr/local/lib/omnibook-fan-curves/curve-python /usr/local/lib/omnibook-fan-curves/control_runner.py|$python $dest/control_runner.py|" "$units/$runner"
ln -sfn "../$socket" "$units/sockets.target.wants/$socket"

cat > /usr/local/bin/hp-charge-limit <<EOF
#!/bin/sh
exec "$python" "$dest/battery_limit.py" "\$@"
EOF
chmod 755 /usr/local/bin/hp-charge-limit
cat > "$units/$service" <<EOF
[Unit]
Description=HP OmniBook battery charge limit
After=systemd-modules-load.service

[Service]
ExecStart=$python $dest/battery_limit.py run
StateDirectory=omnibook-charge-limit
RuntimeDirectory=omnibook-charge-limit
StateDirectoryMode=0755
RuntimeDirectoryMode=0755
Restart=on-failure
RestartSec=3
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
ln -sfn "../$service" "$units/multi-user.target.wants/$service"
systemctl daemon-reload
systemctl start "$socket"
systemctl restart "$service"
/usr/local/bin/hp-charge-limit enable
systemctl is-active "$service"
printf 'Charge limit enabled. Sign out and back in to activate group access.\n'
