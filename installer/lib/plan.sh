#!/bin/sh
# Deterministic, non-destructive installation-plan helpers.

PLAN_HEADER='device	path	descr	ident	bytes	sector_size	transport	partitions	mounted	swap_active	live_parent	available	reason'

plan_validate() {
	state_check || return 1
	state_user_complete || return 1
	state_target_complete || return 1
	[ "$(state_get BOOT_MODE)" = uefi ] || return 1
	[ "$(state_get PARTITION_SCHEME)" = gpt ] || return 1
	[ "$(state_get FILESYSTEM)" = ufs ] || return 1
	case $(state_get SWAP_MODE) in auto | none | custom) : ;; *) return 1 ;; esac
	return 0
}

plan_validation_report() {
	state_check || {
		printf '%s\n' 'Installer state is invalid.'
		return 1
	}
	_plan_ok=yes
	state_user_complete || {
		printf '%s\n' 'Configure the installed user identity.'
		_plan_ok=no
	}
	state_target_complete || {
		printf '%s\n' 'Select an available target with a complete hardware identity.'
		_plan_ok=no
	}
	[ "$(state_get BOOT_MODE)" = uefi ] || {
		printf '%s\n' 'Only UEFI boot is supported in guided mode.'
		_plan_ok=no
	}
	[ "$(state_get PARTITION_SCHEME)" = gpt ] || {
		printf '%s\n' 'Only GPT partitioning is supported in guided mode.'
		_plan_ok=no
	}
	[ "$(state_get FILESYSTEM)" = ufs ] || {
		printf '%s\n' 'Only UFS is currently validated; ZFS remains deferred.'
		_plan_ok=no
	}
	[ "$_plan_ok" = yes ]
}

plan_render() {
	plan_validate || return 1
	_plan_admin=$(state_get ADMIN_ACCESS)
	_plan_swap=$(state_get SWAP_MODE)
	[ "$_plan_swap" = custom ] && _plan_swap="$(state_get SWAP_SIZE_MIB) MiB"
	cat <<EOF
TritonBSD installation plan
============================

System
  Hostname: $(state_get HOSTNAME)
  Locale: $(state_get LOCALE)
  Timezone: $(state_get TIMEZONE)
  Keyboard: $(state_get KEYBOARD_KEYMAP)
  Network: $(state_get NETWORK_MODE) ($(state_get NETWORK_INTERFACE))

Installed user
  Name: $(state_get DISPLAY_NAME)
  Username: $(state_get USERNAME)
  Administrator: $_plan_admin

Storage identity
  Target: $(state_get DISK_DEVICE)
  Model: $(state_get DISK_MODEL)
  Serial: $(state_get DISK_SERIAL)
  Exact size: $(state_get DISK_BYTES) bytes
  Sector size: $(state_get DISK_SECTOR_SIZE) bytes

Layout
  Boot: UEFI
  Partition table: GPT
  Filesystem: UFS
  Swap: $_plan_swap
  Package source: $(state_get PACKAGE_SOURCE)

Safety
  This installer prototype cannot modify disks.
  A real installer backend is not present.
EOF
}

plan_write() {
	[ "$#" -eq 1 ] || return 1
	_plan_path=$1
	[ ! -e "$_plan_path" ] && [ ! -L "$_plan_path" ] || return 1
	_plan_tmp=$_plan_path.tmp.$$
	[ ! -e "$_plan_tmp" ] && [ ! -L "$_plan_tmp" ] || return 1
	(
		umask 077
		plan_render >"$_plan_tmp"
	) || {
		rm -f "$_plan_tmp"
		return 1
	}
	chmod 600 "$_plan_tmp" || {
		rm -f "$_plan_tmp"
		return 1
	}
	mv "$_plan_tmp" "$_plan_path" || {
		rm -f "$_plan_tmp"
		return 1
	}
	[ -f "$_plan_path" ] && [ ! -L "$_plan_path" ] && [ "$(triton_stat_mode "$_plan_path")" = 600 ]
}

plan_confirmation_phrase() {
	plan_validate || return 1
	printf 'ERASE %s %s\n' "$(state_get DISK_DEVICE)" "$(state_get DISK_SERIAL)"
}

plan_snapshot_target() {
	[ "$#" -eq 2 ] || return 1
	_plan_inventory=$1
	_plan_snapshot=$2
	state_check && state_target_complete || return 1
	[ -f "$_plan_inventory" ] && [ ! -L "$_plan_inventory" ] || return 1
	[ ! -e "$_plan_snapshot" ] && [ ! -L "$_plan_snapshot" ] || return 1
	_plan_device=$(state_get DISK_DEVICE) || return 1
	_plan_tmp=$_plan_snapshot.tmp.$$
	awk -F '\t' -v target="$_plan_device" '
        NR == 1 {
            for (i=1; i<=NF; i++) h[$i]=i
            required="device path descr ident bytes sector_size transport partitions mounted swap_active live_parent available reason"
            n=split(required, r, " ")
            for (i=1; i<=n; i++) if (!(r[i] in h)) exit 2
            print
            next
        }
        $h["path"] == target { print; count++ }
        END { if (count != 1) exit 3 }
    ' "$_plan_inventory" >"$_plan_tmp" || {
		rm -f "$_plan_tmp"
		return 1
	}

	_plan_model=$(awk -F '\t' 'NR==1 { for(i=1;i<=NF;i++) h[$i]=i } NR==2 { print $h["descr"] }' "$_plan_tmp")
	_plan_serial=$(awk -F '\t' 'NR==1 { for(i=1;i<=NF;i++) h[$i]=i } NR==2 { print $h["ident"] }' "$_plan_tmp")
	_plan_bytes=$(awk -F '\t' 'NR==1 { for(i=1;i<=NF;i++) h[$i]=i } NR==2 { print $h["bytes"] }' "$_plan_tmp")
	_plan_sector=$(awk -F '\t' 'NR==1 { for(i=1;i<=NF;i++) h[$i]=i } NR==2 { print $h["sector_size"] }' "$_plan_tmp")
	_plan_available=$(awk -F '\t' 'NR==1 { for(i=1;i<=NF;i++) h[$i]=i } NR==2 { print $h["available"] }' "$_plan_tmp")
	[ "$_plan_model" = "$(state_get DISK_MODEL)" ] &&
		[ "$_plan_serial" = "$(state_get DISK_SERIAL)" ] &&
		[ "$_plan_bytes" = "$(state_get DISK_BYTES)" ] &&
		[ "$_plan_sector" = "$(state_get DISK_SECTOR_SIZE)" ] &&
		[ "$_plan_available" = yes ] || {
		rm -f "$_plan_tmp"
		return 1
	}
	chmod 600 "$_plan_tmp" || {
		rm -f "$_plan_tmp"
		return 1
	}
	mv "$_plan_tmp" "$_plan_snapshot"
}

plan_verify_target_snapshot() {
	[ "$#" -eq 2 ] || return 1
	_plan_before=$1
	_plan_inventory=$2
	[ -f "$_plan_before" ] && [ ! -L "$_plan_before" ] || return 1
	_plan_after=$TRITON_RUNTIME_DIR/.target-recheck.$$
	plan_snapshot_target "$_plan_inventory" "$_plan_after" || return 1
	if cmp -s "$_plan_before" "$_plan_after"; then
		rm -f "$_plan_after"
		return 0
	fi
	rm -f "$_plan_after"
	printf '%s\n' 'Target identity or availability changed; selection cleared.' >&2
	return 1
}
