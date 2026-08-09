#!/bin/sh
set -eu

ROOT=${1:-}
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BINARY=${2:-${TRITON_INSTALLER_BINARY:-$PROJECT_DIR/installer/dist/triton-installer-ui}}
DEST=$ROOT/usr/local/libexec/triton
BIN=$ROOT/usr/local/bin
SHARE=$ROOT/usr/local/share/triton/installer-fixtures

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
	echo "usage: $0 /mounted/freebsd/root [installer-binary]" >&2
	exit 1
fi
if [ ! -x "$BINARY" ]; then
	echo "missing FreeBSD installer binary: $BINARY" >&2
	echo "run ./build/build-installer.sh first" >&2
	exit 1
fi
file "$BINARY" | grep -q 'FreeBSD.*x86-64\|x86-64.*FreeBSD' || {
	echo "installer binary is not FreeBSD amd64: $BINARY" >&2
	exit 1
}

install -d -m 755 "$BIN" "$DEST/lib" "$SHARE"
install -m 755 "$PROJECT_DIR/installer/triton-install" "$BIN/triton-install"
install -m 755 "$PROJECT_DIR/installer/libexec/triton/triton-model-bridge" "$DEST/triton-model-bridge"
install -m 755 "$BINARY" "$DEST/triton-ui"
for library in common.sh validate.sh state.sh discover.sh plan.sh; do
	install -m 644 "$PROJECT_DIR/installer/lib/$library" "$DEST/lib/$library"
done

rm -rf "$SHARE/gpt"
mkdir -p "$SHARE/gpt"
tar -C "$PROJECT_DIR/installer/fixtures/freebsd-live/gpt" -cf - . | tar -C "$SHARE/gpt" -xpf -

if [ "$(uname -s)" = FreeBSD ]; then
	"$DEST/triton-ui" --self-test | grep -qx rust-ui-ok
fi
printf '%s\n' "Installed Triton installer into $ROOT"
