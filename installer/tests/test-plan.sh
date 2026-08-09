#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/triton-plan-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -m 700 "$TMP"
export TRITON_RUNTIME_DIR="$TMP/runtime"
export TRITON_STATE_FILE="$TRITON_RUNTIME_DIR/state"

. "$ROOT/lib/common.sh"
. "$ROOT/lib/validate.sh"
. "$ROOT/lib/state.sh"
[ -r "$ROOT/lib/plan.sh" ] || {
	printf '%s\n' 'RED: plan library missing'
	exit 1
}
. "$ROOT/lib/plan.sh"

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
expect_ok() {
	n=$1
	shift
	"$@" && ok "$n" || bad "$n"
}
expect_fail() {
	n=$1
	shift
	"$@" && bad "$n" || ok "$n"
}
contains() { grep -Fq "$2" "$1"; }

state_init
expect_fail 'incomplete state cannot validate' plan_validate
state_set_user 'Ada Lovelace' ada yes
expect_fail 'missing target cannot validate' plan_validate
state_set_target /dev/nda0 'Synthetic NVMe' SERIAL001 500107862016 512 yes
expect_ok 'complete guided plan validates' plan_validate

PLAN=$TMP/install-plan.txt
expect_ok 'plan writes to a private regular file' plan_write "$PLAN"
[ "$(triton_stat_mode "$PLAN")" = 600 ] && ok 'plan file is owner-only' || bad 'plan file mode'
contains "$PLAN" 'TritonBSD installation plan' && ok 'plan has human title' || bad 'plan title'
contains "$PLAN" 'Target: /dev/nda0' && ok 'plan includes canonical target' || bad 'plan target'
contains "$PLAN" 'Model: Synthetic NVMe' && ok 'plan includes model' || bad 'plan model'
contains "$PLAN" 'Serial: SERIAL001' && ok 'plan includes serial' || bad 'plan serial'
contains "$PLAN" 'Exact size: 500107862016 bytes' && ok 'plan includes exact byte size' || bad 'plan bytes'
contains "$PLAN" 'Boot: UEFI' && ok 'plan includes boot mode' || bad 'plan boot'
contains "$PLAN" 'Partition table: GPT' && ok 'plan includes partition scheme' || bad 'plan scheme'
contains "$PLAN" 'Filesystem: UFS' && ok 'plan includes filesystem' || bad 'plan filesystem'
contains "$PLAN" 'This installer prototype cannot modify disks.' && ok 'plan states safety boundary' || bad 'plan safety copy'
if grep -Eiq 'password|hash|psk|secret' "$PLAN"; then bad 'plan leaked secret vocabulary'; else ok 'plan contains no secrets'; fi

phrase=$(plan_confirmation_phrase)
[ "$phrase" = 'ERASE /dev/nda0 SERIAL001' ] && ok 'confirmation phrase binds path and serial' || bad 'confirmation phrase'

INV=$TMP/inventory.tsv
printf '%s\n' 'device	path	descr	ident	bytes	sector_size	transport	partitions	mounted	swap_active	live_parent	available	reason' >"$INV"
printf '%s\n' 'nda0	/dev/nda0	Synthetic NVMe	SERIAL001	500107862016	512	nvme	nda0p1:efi	no	no	no	yes	' >>"$INV"
SNAP=$TMP/selected.tsv
state_set_user '' '' yes
expect_ok 'target snapshot does not require account setup' plan_snapshot_target "$INV" "$SNAP"
state_set_user 'Ada Lovelace' ada yes
expect_ok 'stable selected identity matches inventory' plan_verify_target_snapshot "$SNAP" "$INV"
printf '%s\n' 'device	path	descr	ident	bytes	sector_size	transport	partitions	mounted	swap_active	live_parent	available	reason' >"$TMP/drift.tsv"
printf '%s\n' 'nda0	/dev/nda0	Synthetic NVMe	SERIAL999	500107862016	512	nvme	nda0p1:efi	no	no	no	yes	' >>"$TMP/drift.tsv"
expect_fail 'serial drift invalidates selection' plan_verify_target_snapshot "$SNAP" "$TMP/drift.tsv"
printf '%s\n' 'device	path	descr	ident	bytes	sector_size	transport	partitions	mounted	swap_active	live_parent	available	reason' >"$TMP/mounted.tsv"
printf '%s\n' 'nda0	/dev/nda0	Synthetic NVMe	SERIAL001	500107862016	512	nvme	nda0p1:efi	yes	no	no	no	mounted' >>"$TMP/mounted.tsv"
expect_fail 'availability drift invalidates selection' plan_verify_target_snapshot "$SNAP" "$TMP/mounted.tsv"

ln -s "$TMP/redirect" "$TMP/linked-plan"
expect_fail 'plan writer refuses symlink destination' plan_write "$TMP/linked-plan"

if [ "$fail" -ne 0 ]; then
	printf '%d passed; %d failed\n' "$pass" "$fail" >&2
	exit 1
fi
printf '%d tests passed; 0 failed\n' "$pass"
