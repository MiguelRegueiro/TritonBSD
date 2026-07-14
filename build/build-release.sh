#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_DIR/build/triton.env"

SRC_DIR="${SRC_DIR:-$PROJECT_DIR/work/freebsd-src}"
RELEASE_CONF="${RELEASE_CONF:-$PROJECT_DIR/build/triton-release.conf}"

if [ "$(uname -s)" != "FreeBSD" ]; then
    cat >&2 <<EOF
FreeBSD release media must be built on FreeBSD.

This host is: $(uname -s)

Use a FreeBSD ${TRITON_FREEBSD_RELEASE} builder or VM, then run:

  cd $PROJECT_DIR
  ./build/fetch-freebsd-src.sh
  ./build/build-release.sh
EOF
    exit 1
fi

if [ ! -f "$SRC_DIR/release/release.sh" ]; then
    echo "Missing FreeBSD source at $SRC_DIR" >&2
    echo "Run ./build/fetch-freebsd-src.sh first." >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "release.sh needs root. Re-running with doas or sudo." >&2
    if command -v doas >/dev/null 2>&1; then
        exec doas /bin/sh "$SRC_DIR/release/release.sh" -c "$RELEASE_CONF"
    fi
    if command -v sudo >/dev/null 2>&1; then
        exec sudo /bin/sh "$SRC_DIR/release/release.sh" -c "$RELEASE_CONF"
    fi
    echo "Neither doas nor sudo found; run this script as root." >&2
    exit 1
fi

exec /bin/sh "$SRC_DIR/release/release.sh" -c "$RELEASE_CONF"

