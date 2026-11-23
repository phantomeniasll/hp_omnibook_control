#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release=$(uname -r)
headers="/lib/modules/$release/build"

check_board() {
    board=$(cat /sys/class/dmi/id/board_name)
    bios=$(cat /sys/class/dmi/id/bios_version)
    printf 'Board: %s | BIOS: %s | Kernel: %s\n' "$board" "$bios" "$release"
    if [ "$board" != 8DA8 ] || [ "$bios" != F.11 ]; then
        printf 'This driver supports only HP board 8DA8 with BIOS F.11.\n' >&2
        exit 1
    fi
}

check_board
case "${1:-}" in
    --check) [ "$#" -eq 1 ]; exit ;;
    --install-built)
        [ "$#" -eq 2 ]
        exec sudo /bin/sh "$base/packaging/mint/install-system.sh" "$(realpath "$2")"
        ;;
    ""|--build-only) [ "$#" -le 1 ] ;;
    *) printf 'Usage: %s [--check | --build-only | --install-built FILE]\n' "$0" >&2; exit 2 ;;
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
    sudo /bin/sh "$base/packaging/mint/install-system.sh" "$module"
fi
