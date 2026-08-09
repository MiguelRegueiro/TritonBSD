#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/triton-installer-layout-test.$$
ROOT=$TMP/root
RUNTIME=$TMP/runtime
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -m 700 "$TMP" "$RUNTIME"
mkdir "$ROOT"

"$PROJECT_DIR/build/install-installer.sh" "$ROOT"

WRAPPER=$ROOT/usr/local/bin/triton-install
DEST=$ROOT/usr/local/libexec/triton
FIXTURE=$ROOT/usr/local/share/triton/installer-fixtures/gpt
for file in "$WRAPPER" "$DEST/triton-model-bridge" "$DEST/triton-ui"; do
	[ -x "$file" ] || {
		echo "installed executable is missing: $file" >&2
		exit 1
	}
done
for file in common.sh validate.sh state.sh discover.sh plan.sh; do
	[ -r "$DEST/lib/$file" ] || {
		echo "installed model library is missing: $file" >&2
		exit 1
	}
done
[ -d "$FIXTURE" ] || {
	echo "installed demo fixture is missing" >&2
	exit 1
}
grep -Fq 'INSTALLED_HELPERS=/usr/local/libexec/triton' "$WRAPPER"

export TRITON_RUNTIME_DIR=$RUNTIME
export TRITON_STATE_FILE=$RUNTIME/installer.state
export TRITON_DISCOVERY_FIXTURE=$FIXTURE
"$DEST/triton-model-bridge" state-init
"$DEST/triton-model-bridge" discover "$RUNTIME/inventory.tsv"
grep -Fq '/dev/nda0' "$RUNTIME/inventory.tsv"

printf '%s\n' 'Installed Triton installer layout passed'
