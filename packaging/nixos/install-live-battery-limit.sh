#!/bin/sh
set -eu
export PATH=/run/current-system/sw/bin
[ "$(id -u)" -eq 0 ] || { printf 'Run with sudo.\n' >&2; exit 1; }
[ "$#" -eq 1 ] || { printf 'Pass the absolute path to the Nix Python executable.\n' >&2; exit 1; }
python=$1
case "$python" in /nix/store/*/bin/python3|/nix/store/*/bin/python3.*) ;; *) exit 1 ;; esac
[ -x "$python" ]
[ "$(cat /sys/class/dmi/id/board_name)" = 8DA8 ]
[ "$(cat /sys/class/dmi/id/bios_version)" = F.11 ]
source=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
module="$source/driver/omnibook-charge-control.ko"
release=$(uname -r)
version=$(modinfo -F vermagic "$module")
[ "${version%% *}" = "$release" ]
[ "$(modinfo -F name "$module")" = omnibook_charge_control ]

dest=/usr/local/lib/omnibook-charge-limit
units=/usr/local/lib/systemd/system
service=omnibook-charge-limit.service
install -d -m755 "$dest/$release" "$units/multi-user.target.wants" /usr/local/bin \
    /var/lib/omnibook-charge-limit
install -m644 "$source/app/battery_limit.py" "$source/app/curve_control.py" \
    "$source/app/temperature_status.py" "$dest/"
install -m644 "$module" "$dest/$release/omnibook-charge-control.ko"
python_store=${python%/bin/*}
ln -sfn "$python_store" /nix/var/nix/gcroots/omnibook-charge-limit-python
sed -i 's|"/usr/sbin"|"/run/current-system/sw/bin"|' "$dest/curve_control.py"

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
systemctl restart "$service"
/usr/local/bin/hp-charge-limit enable
systemctl is-active "$service"
printf 'Charge limit enabled. Check it with /usr/local/bin/hp-charge-limit status.\n'
