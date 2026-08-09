#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/triton-bridge-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -m 700 "$TMP"
export TRITON_RUNTIME_DIR=$TMP/runtime
export TRITON_STATE_FILE=$TRITON_RUNTIME_DIR/installer.state
export TRITON_DISCOVERY_FIXTURE=$ROOT/fixtures/freebsd-live/gpt
mkdir -m 700 "$TRITON_RUNTIME_DIR"

. "$ROOT/lib/common.sh"
. "$ROOT/lib/validate.sh"
. "$ROOT/lib/state.sh"
state_init

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok %d - %s\n' "$pass" "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'not ok - %s\n' "$1" >&2
}

BRIDGE=$ROOT/libexec/triton/triton-model-bridge
"$BRIDGE" state-dump | grep -Fq 'BOOT_MODE	uefi' && ok 'bridge reads inert state' || bad 'bridge state read'
chmod 755 "$TRITON_RUNTIME_DIR"
if "$BRIDGE" state-dump >/dev/null 2>&1; then bad 'bridge accepted non-private runtime'; else ok 'bridge rejects non-private runtime'; fi
chmod 700 "$TRITON_RUNTIME_DIR"
if (
	TRITON_RUNTIME_DIR="$TMP/runtime/../runtime"
	TRITON_STATE_FILE="$TMP/runtime/../runtime/installer.state"
	export TRITON_RUNTIME_DIR TRITON_STATE_FILE
	"$BRIDGE" state-dump >/dev/null 2>&1
); then bad 'bridge accepted dot components in runtime path'; else ok 'bridge rejects dot components in runtime path'; fi
mkdir -m 700 "$TMP/physical-parent" "$TMP/physical-parent/runtime"
ln -s "$TMP/physical-parent" "$TMP/runtime-parent-link"
if (
	TRITON_RUNTIME_DIR="$TMP/runtime-parent-link/runtime"
	TRITON_STATE_FILE="$TMP/runtime-parent-link/runtime/installer.state"
	export TRITON_RUNTIME_DIR TRITON_STATE_FILE
	"$BRIDGE" state-init >/dev/null 2>&1
); then bad 'bridge accepted symlinked runtime ancestor'; else ok 'bridge rejects symlinked runtime ancestor'; fi
SET_OUTPUT=$("$BRIDGE" set HOSTNAME triton-test)
printf '%s\n' "$SET_OUTPUT" | grep -Fq "HOSTNAME$(printf '\t')triton-test" && [ "$(state_get HOSTNAME)" = triton-test ] && ok 'bridge mutation returns updated state' || bad 'bridge update state'
INV=$TRITON_RUNTIME_DIR/inventory.tsv
SNAP=$TRITON_RUNTIME_DIR/selected-target.tsv
VICTIM=$TMP/victim
printf '%s\n' unchanged >"$VICTIM"
if "$BRIDGE" discover "$TRITON_RUNTIME_DIR/../victim" >/dev/null 2>&1; then bad 'bridge accepted traversal path'; else ok 'bridge rejects traversal path'; fi
[ "$(cat "$VICTIM")" = unchanged ] && ok 'traversal cannot replace outside file' || bad 'outside file changed'
mkdir "$TRITON_RUNTIME_DIR/nested"
if "$BRIDGE" discover "$TRITON_RUNTIME_DIR/nested/inventory.tsv" >/dev/null 2>&1; then bad 'bridge accepted nested output'; else ok 'bridge rejects nested output'; fi
ln -s "$VICTIM" "$INV"
if "$BRIDGE" discover "$INV" >/dev/null 2>&1; then bad 'bridge followed output symlink'; else ok 'bridge rejects output symlink'; fi
[ "$(cat "$VICTIM")" = unchanged ] && ok 'symlink cannot replace outside file' || bad 'symlink target changed'
rm "$INV"
OUTSIDE_STATE=$TMP/outside.state
printf '%s\n' unchanged >"$OUTSIDE_STATE"
if TRITON_STATE_FILE=$OUTSIDE_STATE "$BRIDGE" state-init >/dev/null 2>&1; then bad 'bridge accepted external state file'; else ok 'bridge rejects external state file'; fi
[ "$(cat "$OUTSIDE_STATE")" = unchanged ] && ok 'external state file remains untouched' || bad 'external state file changed'

"$BRIDGE" discover "$INV" && [ -s "$INV" ] && ok 'fixture discovery' || bad 'fixture discovery'
TARGET_OUTPUT=$("$BRIDGE" select-target "$INV" /dev/nda0 "$SNAP")
printf '%s\n' "$TARGET_OUTPUT" | grep -Fq "DISK_DEVICE$(printf '\t')/dev/nda0" && [ -s "$SNAP" ] && ok 'target selection returns updated state' || bad 'target selection'
"$BRIDGE" revalidate "$INV" "$SNAP" && ok 'bridge revalidates stable target' || bad 'bridge revalidation'
if "$BRIDGE" plan-report >/dev/null 2>&1; then bad 'incomplete plan passed'; else ok 'incomplete plan remains blocked'; fi
"$BRIDGE" set-user 'Ada Lovelace' ada yes >/dev/null
"$BRIDGE" validate "$INV" "$SNAP" && ok 'complete plan validates through bridge' || bad 'bridge validation'

if [ "$fail" -ne 0 ]; then
	printf '%d passed; %d failed\n' "$pass" "$fail" >&2
	exit 1
fi
printf '%d tests passed; 0 failed\n' "$pass"
