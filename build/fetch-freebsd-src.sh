#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_DIR/build/triton.env"

SRC_DIR="${SRC_DIR:-$PROJECT_DIR/work/freebsd-src}"

if ! command -v git >/dev/null 2>&1; then
    echo "git is required to fetch FreeBSD source" >&2
    exit 1
fi

if [ -d "$SRC_DIR/.git" ]; then
    echo "Updating FreeBSD source in $SRC_DIR"
    git -C "$SRC_DIR" fetch origin "$TRITON_FREEBSD_SRC_BRANCH"
    git -C "$SRC_DIR" switch -C "$TRITON_FREEBSD_SRC_BRANCH" \
        "origin/$TRITON_FREEBSD_SRC_BRANCH"
    git -C "$SRC_DIR" pull --ff-only
else
    echo "Cloning FreeBSD source branch $TRITON_FREEBSD_SRC_BRANCH into $SRC_DIR"
    git clone --branch "$TRITON_FREEBSD_SRC_BRANCH" --depth 1 \
        "$FREEBSD_SRC_URL" "$SRC_DIR"
fi

echo "FreeBSD source ready: $SRC_DIR"
