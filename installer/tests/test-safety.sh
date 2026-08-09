#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/triton-safety-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -m 700 "$TMP"

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

SHELL_FILES="$ROOT/triton-install $ROOT/libexec/triton/triton-model-bridge $ROOT/lib/common.sh $ROOT/lib/validate.sh $ROOT/lib/state.sh $ROOT/lib/discover.sh $ROOT/lib/plan.sh"
RUST_FILES="$ROOT/src/main.rs $ROOT/src/app.rs $ROOT/src/backend.rs $ROOT/src/model.rs $ROOT/src/terminal.rs $ROOT/src/ui.rs"

for file in $SHELL_FILES; do /bin/sh -n "$file" || fail "syntax: $file"; done
pass 'all runtime scripts parse as POSIX shell'

if grep -En '^[[:space:]]*(doas|sudo|bsdinstall|newfs|newfs_msdos|zpool|zfs|dd|pw|sysrc|reboot|shutdown|umount)([[:space:]]|$)' $SHELL_FILES >"$TMP/mutators"; then
	fail 'runtime contains privileged or mutating command'
fi
if grep -En 'gpart[[:space:]]+(add|backup|commit|create|delete|destroy|modify|recover|resize|restore|set|undo|unset)' $SHELL_FILES >"$TMP/gpart"; then
	fail 'runtime contains mutating gpart subcommand'
fi
pass 'runtime contains no disk, system, or privilege mutators'

if grep -En 'Command::new\("(doas|sudo|bsdinstall|newfs|zpool|zfs|dd|pw|reboot|shutdown|/bin/sh|/bin/bash)' $RUST_FILES >"$TMP/rust-mutators"; then
	fail 'Rust frontend can bypass the fixed model bridge'
fi
pass 'Rust frontend executes only the fixed model bridge'

if grep -En '(^|[[:space:]])eval([[:space:]]|$)|\.[[:space:]]+.*installer\.state|source[[:space:]]+.*installer\.state' $SHELL_FILES >"$TMP/eval"; then
	fail 'state could be evaluated as shell code'
fi
pass 'state is never sourced or evaluated'

if grep -En 'state_write_record[[:space:]]+(PASSWORD|PASSWORD_HASH|WPA_PSK|PSK|SECRET)([[:space:]]|$)|STATE_KEYS=.*(PASSWORD_HASH|WPA_PSK|PSK|SECRET)' "$ROOT/lib/state.sh" >"$TMP/secrets"; then
	fail 'persistent state contains secret fields'
fi
pass 'persistent schema contains no credential material'

grep -qx 'unset TRITON_DISCOVERY_FIXTURE' "$ROOT/triton-install" || fail 'live launcher inherits fixture override'
pass 'live launcher clears inherited fixture overrides'

[ -x "$ROOT/triton-install" ] || fail 'launcher is not executable'
[ -x "$ROOT/libexec/triton/triton-model-bridge" ] || fail 'bridge is not executable'
pass 'runtime entry points are executable'

printf '1..7\n'
