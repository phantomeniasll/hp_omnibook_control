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

install_release() {
    if [ -n "${OMNIBOOK_RELEASE_ARCHIVE:-}" ] || [ -n "${OMNIBOOK_RELEASE_SHA256:-}" ]; then
        [ -n "${OMNIBOOK_RELEASE_ARCHIVE:-}" ] && [ -n "${OMNIBOOK_RELEASE_SHA256:-}" ]
        archive=$(realpath "$OMNIBOOK_RELEASE_ARCHIVE")
        digest=$OMNIBOOK_RELEASE_SHA256
    elif [ -n "${OMNIBOOK_TRUSTED_COMMIT:-}" ]; then
        commit=$OMNIBOOK_TRUSTED_COMMIT
        case "$commit" in *[!a-f0-9]*) return 1 ;; esac
        [ "${#commit}" -eq 40 ] || [ "${#commit}" -eq 64 ]
        [ "$(git -C "$base" rev-parse --show-toplevel)" = "$base" ]
        archive=$(mktemp)
        trap 'rm -f -- "$archive"' EXIT
        git -C "$base" archive --format=tar "$commit" > "$archive"
        digest=$(sha256sum "$archive" | cut -d ' ' -f1)
    else
        printf 'Set OMNIBOOK_RELEASE_ARCHIVE and OMNIBOOK_RELEASE_SHA256 from a trusted release, or OMNIBOOK_TRUSTED_COMMIT for a verified Git revision.\n' >&2
        return 1
    fi

    # Pass the approval and bootstrap directly to sudo. The root process
    # never executes a program or installer from the build checkout.
    sudo /bin/sh -c '
        set -eu
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin
        umask 077
        stage=$(mktemp -d /run/omnibook-release.XXXXXX)
        trap "rm -rf -- $stage" EXIT
        cat > "$stage/release.tar"
        actual=$(sha256sum "$stage/release.tar" | cut -d " " -f1)
        [ "$actual" = "$1" ] || { printf "Release checksum mismatch.\n" >&2; exit 1; }
        mkdir "$stage/source"
        /usr/bin/python3 - "$stage/release.tar" "$stage/source" <<PY
import sys
import tarfile
with tarfile.open(sys.argv[1], "r:*") as release:
    release.extractall(sys.argv[2], filter="data")
PY
        shift
        /bin/sh "$stage/source/packaging/mint/install-system.sh" "$@"
    ' omnibook-install "$digest" "$@" < "$archive"
}

install_built() {
    fan=$(realpath "$1")
    charge=$(dirname -- "$fan")/omnibook-charge-control.ko
    fan_hash=$(sha256sum "$fan" | cut -d ' ' -f1)
    if [ "${2:-}" = --without-charge ]; then
        printf 'Installing fan control only.\n'
        install_release "$fan" "$fan_hash" --without-charge
    elif [ -f "$charge" ]; then
        charge_hash=$(sha256sum "$charge" | cut -d ' ' -f1)
        install_release "$fan" "$fan_hash" "$charge" "$charge_hash"
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
