#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/triton-model-test.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -m 700 "$TMP"
export TRITON_RUNTIME_DIR="$TMP/runtime"
export TRITON_STATE_FILE="$TRITON_RUNTIME_DIR/installer.state"

. "$ROOT/lib/common.sh"
. "$ROOT/lib/validate.sh"
. "$ROOT/lib/state.sh"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok %d - %s\n' "$pass" "$1"
}
not_ok() {
	fail=$((fail + 1))
	printf 'not ok - %s\n' "$1" >&2
}
expect_ok() {
	name=$1
	shift
	if "$@"; then ok "$name"; else not_ok "$name"; fi
}
expect_fail() {
	name=$1
	shift
	if "$@"; then not_ok "$name"; else ok "$name"; fi
}
expect_eq() {
	name=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then ok "$name"; else not_ok "$name (expected [$expected], got [$actual])"; fi
}

state_init
expect_eq 'runtime directory is owner-only' 700 "$(triton_stat_mode "$TRITON_RUNTIME_DIR")"
expect_eq 'state file is owner-only' 600 "$(triton_stat_mode "$TRITON_STATE_FILE")"
expect_eq 'guided mode is default' guided "$(state_get INSTALL_MODE)"
expect_eq 'GPT is default' gpt "$(state_get PARTITION_SCHEME)"
expect_eq 'UEFI is default' uefi "$(state_get BOOT_MODE)"
expect_eq 'UFS is default' ufs "$(state_get FILESYSTEM)"
expect_eq 'automatic swap is default' auto "$(state_get SWAP_MODE)"
expect_eq 'hostname is simple' triton "$(state_get HOSTNAME)"
expect_eq 'installed username starts incomplete' '' "$(state_get USERNAME)"
expect_eq 'installed display name starts incomplete' '' "$(state_get DISPLAY_NAME)"
expect_eq 'target device starts incomplete' '' "$(state_get DISK_DEVICE)"
expect_eq 'target availability starts unknown' unknown "$(state_get DISK_AVAILABLE)"
expect_fail 'user is initially incomplete' state_user_complete
expect_fail 'target is initially incomplete' state_target_complete
expect_eq 'initial user status is clear' 'Not configured' "$(state_status_user)"
expect_eq 'initial storage status is clear' 'Not selected' "$(state_status_storage)"
expect_eq 'default layout status is deterministic' 'uefi · gpt · ufs · auto' "$(state_status_layout)"

expect_ok 'valid hostname' validate_hostname host-01
expect_fail 'hostname rejects FQDN and punctuation' validate_hostname host.example
expect_fail 'hostname rejects leading hyphen' validate_hostname -host
expect_fail 'hostname rejects oversized value' validate_hostname "$(printf '%064d' 0)"
expect_ok 'valid username' validate_username ada_01
expect_fail 'username rejects uppercase' validate_username Ada
expect_fail 'username rejects leading digit' validate_username 1ada
expect_ok 'Unicode display name is accepted' validate_display_name 'Áda Lovelace'
expect_fail 'display name rejects passwd delimiter' validate_display_name 'Ada:Admin'
expect_ok 'valid keymap' validate_keymap es.kbd
expect_fail 'keymap rejects traversal' validate_keymap ../es.kbd
expect_ok 'valid locale' validate_locale es_ES.UTF-8
expect_fail 'locale rejects malformed value' validate_locale es-ES
expect_ok 'UTC timezone' validate_timezone UTC
expect_ok 'region timezone' validate_timezone Europe/Madrid
expect_fail 'timezone rejects traversal' validate_timezone Europe/../UTC
expect_fail 'timezone rejects duplicate slash' validate_timezone Europe//Madrid
expect_fail 'timezone rejects metacharacters' validate_timezone 'Europe/Mad;rid'
expect_ok 'positive decimal accepts bytes' validate_positive_decimal 500107862016
expect_fail 'positive decimal rejects zero' validate_positive_decimal 000
expect_ok 'canonical disk device accepted' validate_disk_device /dev/nda0
expect_fail 'disk path rejects partition traversal' validate_disk_device /dev/../nda0
expect_fail 'disk path rejects nested aliases' validate_disk_device /dev/diskid/DISK-1
expect_ok 'complete disk identity accepted' validate_target_identity /dev/nda0 'Synthetic NVMe' SERIAL001 500107862016 512
expect_fail 'disk identity requires serial' validate_target_identity /dev/nda0 'Synthetic NVMe' '' 500107862016 512
expect_fail 'disk identity requires positive size' validate_target_identity /dev/nda0 'Synthetic NVMe' SERIAL001 0 512

expect_fail 'unknown key is rejected' state_set UNKNOWN value
expect_fail 'password key is rejected' state_set PASSWORD hunter2
expect_fail 'password hash key is rejected' state_set PASSWORD_HASH hash
expect_fail 'WPA key is rejected' state_set WPA_PSK secret
expect_fail 'grouped username cannot be partially updated' state_set USERNAME ada
expect_fail 'grouped disk cannot be partially updated' state_set DISK_DEVICE /dev/nda0
expect_fail 'invalid hostname cannot enter state' state_set HOSTNAME 'bad.host'
expect_ok 'valid hostname enters state' state_set HOSTNAME triton-workstation
expect_eq 'hostname update round-trips' triton-workstation "$(state_get HOSTNAME)"

expect_fail 'partial user tuple is rejected' state_set_user 'Ada Lovelace' '' yes
expect_ok 'complete user tuple is accepted' state_set_user 'Áda Lovelace' ada yes
expect_ok 'configured user is complete' state_user_complete
expect_eq 'Unicode state round-trips inertly' 'Áda Lovelace' "$(state_get DISPLAY_NAME)"
expect_eq 'configured user status is concise' 'ada · administrator: yes' "$(state_status_user)"

expect_fail 'target tuple rejects unavailable enum' state_set_target /dev/nda0 'Synthetic NVMe' SERIAL001 500107862016 512 maybe
expect_ok 'unavailable target can be represented' state_set_target /dev/nda0 'Synthetic NVMe' SERIAL001 500107862016 512 no
expect_fail 'unavailable target is not complete' state_target_complete
expect_ok 'available target can be represented' state_set_target /dev/nda0 'Synthetic NVMe' SERIAL001 500107862016 512 yes
expect_ok 'available target identity is complete' state_target_complete
expect_eq 'storage status includes immutable identity context' 'Synthetic NVMe · 500107862016 bytes · /dev/nda0' "$(state_status_storage)"
expect_ok 'target can be cleared atomically' state_clear_target
expect_fail 'cleared target is incomplete' state_target_complete

expect_fail 'custom swap requires a size' state_set_swap custom ''
expect_fail 'automatic swap rejects custom size' state_set_swap auto 2048
expect_ok 'custom swap accepts positive MiB' state_set_swap custom 2048
expect_eq 'custom swap status is explicit' 'uefi · gpt · ufs · 2048 MiB swap' "$(state_status_layout)"
expect_ok 'automatic swap clears custom size' state_set_swap auto ''

expect_fail 'tab cannot enter state' state_set HOSTNAME "$(printf 'bad\tname')"
expect_fail 'newline cannot enter state' state_set HOSTNAME "$(printf 'bad\nname')"
expect_fail 'control byte cannot enter state' state_set HOSTNAME "$(printf 'bad\001name')"

cp "$TRITON_STATE_FILE" "$TMP/good.state"
awk -F= '$1 == "HOSTNAME" { print "HOSTNAME=747269746f6e0a"; next } { print }' "$TMP/good.state" >"$TRITON_STATE_FILE"
chmod 600 "$TRITON_STATE_FILE"
expect_fail 'persisted encoded newline is rejected' state_check
cp "$TMP/good.state" "$TRITON_STATE_FILE"
awk -F= '$1 == "HOSTNAME" { print; print "EVIL=746f756368"; next } { print }' "$TMP/good.state" >"$TRITON_STATE_FILE"
chmod 600 "$TRITON_STATE_FILE"
expect_fail 'persisted unknown key is rejected' state_check
cp "$TMP/good.state" "$TRITON_STATE_FILE"
chmod 600 "$TRITON_STATE_FILE"
expect_ok 'known-good state remains valid' state_check

mkdir "$TMP/real-runtime"
ln -s "$TMP/real-runtime" "$TMP/runtime-link"
(
	TRITON_RUNTIME_DIR="$TMP/runtime-link"
	TRITON_STATE_FILE="$TMP/runtime-link/state"
	state_init
) >/dev/null 2>&1 && not_ok 'symlink runtime directory was accepted' || ok 'symlink runtime directory is rejected'
ln -s "$TMP/good.state" "$TRITON_RUNTIME_DIR/symlink.state"
(
	TRITON_STATE_FILE="$TRITON_RUNTIME_DIR/symlink.state"
	state_init
) >/dev/null 2>&1 && not_ok 'symlink state file was accepted' || ok 'symlink state file is rejected'

if [ "$fail" -ne 0 ]; then
	printf '%d tests passed; %d failed\n' "$pass" "$fail" >&2
	exit 1
fi
printf '%d tests passed; 0 failed\n' "$pass"
