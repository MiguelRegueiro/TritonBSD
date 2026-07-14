#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_DIR/build/triton.env"

if [ "$(uname -s)" != "FreeBSD" ]; then
    echo "This script must run on FreeBSD because it uses mdconfig, gpart, and UFS mount." >&2
    exit 1
fi

WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work/remix}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$PROJECT_DIR/artifacts}"
IMAGE_KIND="${TRITON_IMAGE_KIND:-memstick}"
IMAGE_FLAVOR="${TRITON_IMAGE_FLAVOR:-bootstrap}"
WITH_LIVE_DESKTOP="${TRITON_WITH_LIVE_DESKTOP:-0}"
TRITON_IMAGE_SIZE="${TRITON_IMAGE_SIZE:-6G}"

BASE_URL="${FREEBSD_RELEASE_BASE_URL:-https://download.freebsd.org/releases/ISO-IMAGES/$TRITON_FREEBSD_VERSION}"
BASE_IMAGE="FreeBSD-${TRITON_FREEBSD_RELEASE}-${TRITON_TARGET_ARCH}-${IMAGE_KIND}.img"
BASE_IMAGE_XZ="$BASE_IMAGE.xz"
CHECKSUM_FILE="CHECKSUM.SHA512-FreeBSD-${TRITON_FREEBSD_RELEASE}-${TRITON_TARGET_ARCH}"
TRITON_IMAGE="TritonBSD-${TRITON_FREEBSD_RELEASE}-${TRITON_TARGET_ARCH}-${IMAGE_FLAVOR}-${IMAGE_KIND}.img"
TRITON_IMAGE_XZ="$TRITON_IMAGE.xz"

mkdir -p "$WORK_DIR" "$ARTIFACT_DIR"

cd "$WORK_DIR"

rm -f "$BASE_IMAGE_XZ" "$CHECKSUM_FILE"

echo "Fetching $BASE_IMAGE_XZ"
fetch -o "$BASE_IMAGE_XZ" "$BASE_URL/$BASE_IMAGE_XZ"

echo "Fetching checksums"
fetch -o "$CHECKSUM_FILE" "$BASE_URL/$CHECKSUM_FILE"

EXPECTED=$(awk -v f="$BASE_IMAGE_XZ" '$2 == "(" f ")" { print $4 }' "$CHECKSUM_FILE")
if [ -z "$EXPECTED" ]; then
    echo "Could not find checksum for $BASE_IMAGE_XZ" >&2
    exit 1
fi

ACTUAL=$(sha512 -q "$BASE_IMAGE_XZ")
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "Checksum mismatch for $BASE_IMAGE_XZ" >&2
    echo "expected: $EXPECTED" >&2
    echo "actual:   $ACTUAL" >&2
    exit 1
fi

echo "Checksum OK"

rm -f "$BASE_IMAGE" "$TRITON_IMAGE" "$TRITON_IMAGE_XZ"
xz -dk "$BASE_IMAGE_XZ"
cp "$BASE_IMAGE" "$TRITON_IMAGE"

if [ "$WITH_LIVE_DESKTOP" = "1" ]; then
    echo "Growing image to $TRITON_IMAGE_SIZE for live desktop packages"
    truncate -s "$TRITON_IMAGE_SIZE" "$TRITON_IMAGE"
fi

MNT="$WORK_DIR/mnt"
mkdir -p "$MNT"

MD=""
cleanup() {
    if mount | grep -q " on $MNT "; then
        umount "$MNT" || true
    fi
    if [ -n "$MD" ]; then
        mdconfig -d -u "$MD" || true
    fi
}
trap cleanup EXIT INT TERM

MD=$(mdconfig -a -t vnode -f "$TRITON_IMAGE")
echo "Attached image as /dev/$MD"

if [ "$WITH_LIVE_DESKTOP" = "1" ]; then
    FREEBSD_SLICE=$(gpart show -p "$MD" | awk '$4 == "freebsd" { print $3; exit }')
    if [ -n "$FREEBSD_SLICE" ]; then
        SLICE_INDEX=${FREEBSD_SLICE#${MD}s}
        if [ "$SLICE_INDEX" = "$FREEBSD_SLICE" ]; then
            SLICE_INDEX=${FREEBSD_SLICE#${MD}p}
        fi
        echo "Growing FreeBSD slice $FREEBSD_SLICE"
        gpart resize -i "$SLICE_INDEX" "$MD"
        echo "Growing BSD label partition in $FREEBSD_SLICE"
        gpart resize -i 1 "$FREEBSD_SLICE"
    fi
fi

echo "Top-level partition table:"
gpart show -p "$MD"

ROOT_PART=$(gpart show -p "$MD" | awk '$4 == "freebsd-ufs" { print "/dev/" $3; exit }')
if [ -z "$ROOT_PART" ]; then
    FREEBSD_SLICE=$(gpart show -p "$MD" | awk '$4 == "freebsd" { print $3; exit }')
    if [ -n "$FREEBSD_SLICE" ]; then
        echo "Nested BSD label in /dev/$FREEBSD_SLICE:"
        gpart show -p "$FREEBSD_SLICE"
        ROOT_PART=$(gpart show -p "$FREEBSD_SLICE" | awk '$4 == "freebsd-ufs" { print "/dev/" $3; exit }')
        if [ -z "$ROOT_PART" ] && [ -e "/dev/${FREEBSD_SLICE}a" ]; then
            ROOT_PART="/dev/${FREEBSD_SLICE}a"
        fi
    fi
fi

if [ -z "$ROOT_PART" ]; then
    echo "Could not find a freebsd-ufs root partition in /dev/$MD" >&2
    exit 1
fi

echo "Mounting $ROOT_PART"
if [ "$WITH_LIVE_DESKTOP" = "1" ]; then
    echo "Growing root filesystem $ROOT_PART"
    growfs -y "$ROOT_PART"
fi
mount -o noatime "$ROOT_PART" "$MNT"

echo "Applying Triton overlay"
tar -C "$PROJECT_DIR/build/overlay" -cf - . | tar -C "$MNT" -xpf -

mkdir -p "$MNT/usr/local/share/triton/docs"
cp "$PROJECT_DIR/README.md" "$MNT/usr/local/share/triton/docs/PROJECT-README.md"
cp "$PROJECT_DIR/docs/how-it-works.md" "$MNT/usr/local/share/triton/docs/how-it-works.md"

if [ "$WITH_LIVE_DESKTOP" = "1" ]; then
    "$PROJECT_DIR/build/live-setup.sh" "$MNT"
fi

sync
umount "$MNT"
mdconfig -d -u "$MD"
MD=""

echo "Compressing artifact"
xz -T0 -6 "$TRITON_IMAGE"
cp "$TRITON_IMAGE_XZ" "$ARTIFACT_DIR/$TRITON_IMAGE_XZ"

echo "Created $ARTIFACT_DIR/$TRITON_IMAGE_XZ"
