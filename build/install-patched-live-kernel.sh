#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_DIR/build/triton.env"

if [ "$(uname -s)" != "FreeBSD" ]; then
    echo "The patched Triton kernel must be built on FreeBSD." >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "The patched Triton kernel must be installed as root." >&2
    exit 1
fi
if [ "$TRITON_FREEBSD_RELEASE" != "15.1-RELEASE" ] ||
    [ "$TRITON_TARGET_ARCH" != "amd64" ]; then
    echo "No reviewed LinuxKPI patch is available for $TRITON_FREEBSD_RELEASE/$TRITON_TARGET_ARCH." >&2
    exit 1
fi
if [ "$#" -ne 1 ] || [ "$1" = "/" ] || [ ! -d "$1/boot/kernel" ]; then
    echo "usage: $0 DESTDIR" >&2
    exit 1
fi

DESTDIR=$1
if ! mount | awk -v destdir="$DESTDIR" \
    '$2 == "on" && $3 == destdir { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "Refusing kernel install: DESTDIR is not a mounted filesystem." >&2
    exit 1
fi

BUILD_ROOT="$PROJECT_DIR/work/patched-kernel"
ARCHIVE="$BUILD_ROOT/src.txz"
SOURCE_ROOT="$BUILD_ROOT/source-root"
SRC_DIR="$SOURCE_ROOT/usr/src"
PATCH_FILE="$PROJECT_DIR/build/patches/freebsd-15.1-linuxkpi-addba-stop-lock.patch"
SOURCE_FILE="$SRC_DIR/sys/compat/linuxkpi/common/src/linux_80211.c"
METADATA_DIR="$DESTDIR/usr/local/share/triton"
METADATA_FILE="$METADATA_DIR/kernel-build.txt"

SRC_URL="https://download.freebsd.org/releases/amd64/15.1-RELEASE/src.txz"
SRC_SHA256="cf5762da53fd52e1eaf0f9ceee9bf58cbe314c821031d0d9ffa76823185a89e1"
SOURCE_FILE_SHA256="daab9dd2ff95e34268d37c11944919d4abbbe70645c3cace679f87378be22ef4"
PATCHED_SOURCE_FILE_SHA256="cab954ea8ba8a58ce00643c86a3d916440baca6d0a129e22e0d3a768f7e594b1"

mkdir -p "$BUILD_ROOT"
if [ ! -f "$ARCHIVE" ]; then
    echo "Fetching exact FreeBSD 15.1 release source"
    fetch -o "$ARCHIVE" "$SRC_URL"
fi
if [ "$(sha256 -q "$ARCHIVE")" != "$SRC_SHA256" ]; then
    echo "FreeBSD source archive checksum mismatch" >&2
    exit 1
fi

rm -rf "$SOURCE_ROOT"
mkdir -p "$SOURCE_ROOT"
tar -xpf "$ARCHIVE" -C "$SOURCE_ROOT"

if [ "$(sha256 -q "$SOURCE_FILE")" != "$SOURCE_FILE_SHA256" ]; then
    echo "linux_80211.c does not match the reviewed 15.1 release source" >&2
    exit 1
fi
patch -d "$SRC_DIR" -p0 --forward --batch < "$PATCH_FILE"
if [ "$(sha256 -q "$SOURCE_FILE")" != "$PATCHED_SOURCE_FILE_SHA256" ]; then
    echo "Patched linux_80211.c checksum mismatch" >&2
    exit 1
fi

JOBS=$(sysctl -n hw.ncpu)
[ "$JOBS" -le 4 ] || JOBS=4

echo "Building patched GENERIC kernel with $JOBS jobs"
make -C "$SRC_DIR" -j"$JOBS" buildkernel \
    KERNCONF=GENERIC \
    WITHOUT_DEBUG_FILES=yes

echo "Installing complete patched kernel and in-tree module set"
make -C "$SRC_DIR" installkernel \
    KERNCONF=GENERIC \
    DESTDIR="$DESTDIR" \
    NO_INSTALLEXTRAKERNELS=yes \
    WITHOUT_DEBUG_FILES=yes
kldxref "$DESTDIR/boot/kernel"

[ -s "$DESTDIR/boot/kernel/kernel" ]
[ -s "$DESTDIR/boot/kernel/linuxkpi_wlan.ko" ]
[ -s "$DESTDIR/boot/kernel/if_rtw88.ko" ]
nm -a "$DESTDIR/boot/kernel/kernel" | awk '$3 == "lkpi_ic_addba_stop" { found = 1 } END { exit found ? 0 : 1 }'

mkdir -p "$METADATA_DIR"
PATCH_SHA256=$(sha256 -q "$PATCH_FILE")
KERNEL_SHA256=$(sha256 -q "$DESTDIR/boot/kernel/kernel")
LINUXKPI_WLAN_SHA256=$(sha256 -q "$DESTDIR/boot/kernel/linuxkpi_wlan.ko")
RTW88_SHA256=$(sha256 -q "$DESTDIR/boot/kernel/if_rtw88.ko")
cat > "$METADATA_FILE" <<EOF
FreeBSD release: $TRITON_FREEBSD_RELEASE
Source archive SHA256: $SRC_SHA256
LinuxKPI patch SHA256: $PATCH_SHA256
Patched linux_80211.c SHA256: $PATCHED_SOURCE_FILE_SHA256
Kernel SHA256: $KERNEL_SHA256
linuxkpi_wlan.ko SHA256: $LINUXKPI_WLAN_SHA256
if_rtw88.ko SHA256: $RTW88_SHA256
Patch: conditionally release and restore the net80211 com lock in lkpi_ic_addba_stop
EOF
chmod 0444 "$METADATA_FILE"

cat "$METADATA_FILE"
echo "Patched Triton kernel installed"
