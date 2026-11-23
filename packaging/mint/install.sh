#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release=$(uname -r)
headers="/lib/modules/$release/build"

check_board() {
    board=$(cat /sys/class/dmi/id/board_name)
    bios=$(cat /sys/class/dmi/id/bios_version)
    printf 'Board: %s | BIOS: %s | Kernel: %s\n' "$board" "$bios" "$release"
    if [ "$(cat /sys/class/dmi/id/sys_vendor)" != HP ] || [ "$board" != 8DA8 ]; then
        printf 'This driver supports only HP board 8DA8.\n' >&2
        exit 1
    fi
}

install_built() {
    fan=$(realpath "$1")
    charge=$(dirname -- "$fan")/omnibook-charge-control.ko
    fan_hash=$(sha256sum "$fan" | cut -d ' ' -f1)
    if [ "${2:-}" = --without-charge ]; then
        printf 'Installing fan control only.\n'
        sudo /bin/sh "$base/packaging/mint/install-system.sh" "$fan" "$fan_hash" --without-charge
    elif [ -f "$charge" ]; then
        charge_hash=$(sha256sum "$charge" | cut -d ' ' -f1)
        sudo /bin/sh "$base/packaging/mint/install-system.sh" "$fan" "$fan_hash" "$charge" "$charge_hash"
    else
        printf 'Charge module missing. Use --install-built FILE --without-charge for a fan-only installation.\n' >&2
        return 1
    fi
}

check_board
case "${1:-}" in
    --check) [ "$#" -eq 1 ]; exit ;;
    --install-built)
        [ "$#" -eq 2 ] || { [ "$#" -eq 3 ] && [ "$3" = --without-charge ]; }
        install_built "$2" "${3:-}"
        exit
        ;;
    ""|--build-only) [ "$#" -le 1 ] ;;
    *) printf 'Usage: %s [--check | --build-only | --install-built FILE [--without-charge]]\n' "$0" >&2; exit 2 ;;
esac
if [ "$(id -u)" -eq 0 ]; then
    printf 'Run this script as your regular user. It asks for sudo when installing.\n' >&2
    exit 1
fi
if [ ! -f "$headers/Makefile" ]; then
    printf 'Install matching kernel headers: sudo apt install linux-headers-%s\n' "$release" >&2
    exit 1
fi
make -C "$headers" M="$base/driver" modules
module="$base/driver/omnibook-fan-probe.ko"
if [ "${1:-}" = "--build-only" ]; then
    printf '%s\n' "$module"
else
    install_built "$module"
fi
