#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PROJECT_DIR/build/triton.env"

MANIFEST=$PROJECT_DIR/installer/Cargo.toml
TARGET_DIR=${TRITON_INSTALLER_TARGET_DIR:-$HOME/.cache/triton-installer-target}
OUTPUT=${1:-$PROJECT_DIR/installer/dist/triton-installer-ui}
TARGET=x86_64-unknown-freebsd

command -v cargo >/dev/null 2>&1 || {
	echo "cargo is required to build the Triton installer" >&2
	exit 1
}
mkdir -p "$TARGET_DIR" "$(dirname -- "$OUTPUT")"

if [ "$(uname -s)" = FreeBSD ]; then
	CARGO_TARGET_DIR=$TARGET_DIR cargo build --locked --release --manifest-path "$MANIFEST"
	BUILT=$TARGET_DIR/release/triton-installer-ui
else
	command -v rustup >/dev/null 2>&1 || {
		echo "rustup is required for the FreeBSD cross-build" >&2
		exit 1
	}
	command -v clang >/dev/null 2>&1 || {
		echo "clang is required for the FreeBSD cross-build" >&2
		exit 1
	}
	rustup target add "$TARGET"

	SYSROOT=${FREEBSD_SYSROOT:-$HOME/.cache/freebsd-$TRITON_FREEBSD_VERSION-sysroot}
	BASE_ARCHIVE=${FREEBSD_BASE_ARCHIVE:-$HOME/.cache/freebsd-$TRITON_FREEBSD_VERSION-base.txz}
	MANIFEST_FILE=${FREEBSD_MANIFEST_FILE:-$HOME/.cache/freebsd-$TRITON_FREEBSD_VERSION-MANIFEST}
	command -v curl >/dev/null 2>&1 || {
		echo "curl is required to fetch the FreeBSD sysroot" >&2
		exit 1
	}
	command -v sha256sum >/dev/null 2>&1 || {
		echo "sha256sum is required to verify the FreeBSD sysroot" >&2
		exit 1
	}
	BASE_URL=https://download.freebsd.org/releases/amd64/$TRITON_FREEBSD_RELEASE
	curl -fL --retry 3 "$BASE_URL/MANIFEST" -o "$MANIFEST_FILE.tmp"
	mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
	EXPECTED=$(awk '$1 == "base.txz" { print $2; exit }' "$MANIFEST_FILE")
	[ -n "$EXPECTED" ] || {
		echo "FreeBSD base.txz checksum is missing" >&2
		exit 1
	}

	STAMPED=
	if [ -r "$SYSROOT/.base.sha256" ]; then
		IFS= read -r STAMPED <"$SYSROOT/.base.sha256" || STAMPED=
	fi
	if [ ! -r "$SYSROOT/lib/libc.so.7" ] || [ "$STAMPED" != "$EXPECTED" ]; then
		ACTUAL=
		if [ -r "$BASE_ARCHIVE" ]; then
			ACTUAL=$(sha256sum "$BASE_ARCHIVE" | awk '{ print $1 }')
		fi
		if [ "$ACTUAL" != "$EXPECTED" ]; then
			rm -f "$BASE_ARCHIVE"
			curl -fL --retry 3 "$BASE_URL/base.txz" -o "$BASE_ARCHIVE.tmp"
			ACTUAL=$(sha256sum "$BASE_ARCHIVE.tmp" | awk '{ print $1 }')
			if [ "$ACTUAL" != "$EXPECTED" ]; then
				rm -f "$BASE_ARCHIVE.tmp"
				echo "FreeBSD base.txz checksum mismatch" >&2
				exit 1
			fi
			mv "$BASE_ARCHIVE.tmp" "$BASE_ARCHIVE"
		fi
		rm -rf "$SYSROOT"
		mkdir -p "$SYSROOT"
		tar -xJf "$BASE_ARCHIVE" -C "$SYSROOT" ./lib ./usr/lib ./usr/include
		printf '%s\n' "$EXPECTED" >"$SYSROOT/.base.sha256"
	fi

	CARGO_TARGET_DIR=$TARGET_DIR \
		CARGO_TARGET_X86_64_UNKNOWN_FREEBSD_LINKER=clang \
		RUSTFLAGS="-C link-arg=--target=x86_64-unknown-freebsd$TRITON_FREEBSD_VERSION -C link-arg=--sysroot=$SYSROOT -C link-arg=-fuse-ld=lld" \
		cargo build --locked --release --target "$TARGET" --manifest-path "$MANIFEST"
	BUILT=$TARGET_DIR/$TARGET/release/triton-installer-ui
fi

install -m 755 "$BUILT" "$OUTPUT"
file "$OUTPUT"
file "$OUTPUT" | grep -q 'FreeBSD.*x86-64\|x86-64.*FreeBSD' || {
	echo "installer artifact is not a FreeBSD amd64 binary" >&2
	exit 1
}

if command -v llvm-readelf >/dev/null 2>&1; then
	llvm-readelf -h -d "$OUTPUT"
elif command -v readelf >/dev/null 2>&1; then
	readelf -h -d "$OUTPUT"
fi

if [ "$(uname -s)" = FreeBSD ]; then
	"$OUTPUT" --self-test | grep -qx rust-ui-ok
fi
