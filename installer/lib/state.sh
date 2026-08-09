#!/bin/sh
# Inert, allowlisted installer state. The file is parsed, never sourced.

: "${TRITON_RUNTIME_DIR:=${TMPDIR:-/tmp}/triton-installer}"
: "${TRITON_STATE_FILE:=$TRITON_RUNTIME_DIR/installer.state}"

STATE_KEYS='KEYBOARD_KEYMAP NETWORK_MODE NETWORK_INTERFACE HOSTNAME LOCALE TIMEZONE USERNAME DISPLAY_NAME ADMIN_ACCESS DISK_DEVICE DISK_MODEL DISK_SERIAL DISK_BYTES DISK_SECTOR_SIZE DISK_AVAILABLE INSTALL_MODE PARTITION_SCHEME BOOT_MODE FILESYSTEM SWAP_MODE SWAP_SIZE_MIB PACKAGE_SOURCE'
STATE_KEY_COUNT=22

state_key_allowed() {
	[ "$#" -eq 1 ] || return 1
	case " $STATE_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

state_value_valid() {
	[ "$#" -eq 2 ] || return 1
	_state_key=$1
	_state_value=$2
	triton_is_safe_text "$_state_value" || return 1
	case $_state_key in
	KEYBOARD_KEYMAP) validate_keymap "$_state_value" ;;
	NETWORK_MODE) validate_choice "$_state_value" auto dhcp manual offline ;;
	NETWORK_INTERFACE) validate_interface "$_state_value" ;;
	HOSTNAME) validate_hostname "$_state_value" ;;
	LOCALE) validate_locale "$_state_value" ;;
	TIMEZONE) validate_timezone "$_state_value" ;;
	USERNAME) [ -z "$_state_value" ] || validate_username "$_state_value" ;;
	DISPLAY_NAME) [ -z "$_state_value" ] || validate_display_name "$_state_value" ;;
	ADMIN_ACCESS) validate_choice "$_state_value" yes no ;;
	DISK_DEVICE) [ -z "$_state_value" ] || validate_disk_device "$_state_value" ;;
	DISK_MODEL | DISK_SERIAL) [ -z "$_state_value" ] || validate_nonempty_safe "$_state_value" 128 ;;
	DISK_BYTES | DISK_SECTOR_SIZE) [ -z "$_state_value" ] || validate_positive_decimal "$_state_value" ;;
	DISK_AVAILABLE) validate_choice "$_state_value" unknown yes no ;;
	INSTALL_MODE) validate_choice "$_state_value" guided advanced ;;
	PARTITION_SCHEME) validate_choice "$_state_value" gpt ;;
	BOOT_MODE) validate_choice "$_state_value" uefi ;;
	FILESYSTEM) validate_choice "$_state_value" ufs zfs ;;
	SWAP_MODE) validate_choice "$_state_value" auto custom none ;;
	SWAP_SIZE_MIB) [ -z "$_state_value" ] || validate_positive_decimal "$_state_value" ;;
	PACKAGE_SOURCE) validate_choice "$_state_value" network local ;;
	*) return 1 ;;
	esac
}

state_write_defaults() {
	state_write_record KEYBOARD_KEYMAP us
	state_write_record NETWORK_MODE auto
	state_write_record NETWORK_INTERFACE auto
	state_write_record HOSTNAME triton
	state_write_record LOCALE en_US.UTF-8
	state_write_record TIMEZONE UTC
	state_write_record USERNAME ''
	state_write_record DISPLAY_NAME ''
	state_write_record ADMIN_ACCESS yes
	state_write_record DISK_DEVICE ''
	state_write_record DISK_MODEL ''
	state_write_record DISK_SERIAL ''
	state_write_record DISK_BYTES ''
	state_write_record DISK_SECTOR_SIZE ''
	state_write_record DISK_AVAILABLE unknown
	state_write_record INSTALL_MODE guided
	state_write_record PARTITION_SCHEME gpt
	state_write_record BOOT_MODE uefi
	state_write_record FILESYSTEM ufs
	state_write_record SWAP_MODE auto
	state_write_record SWAP_SIZE_MIB ''
	state_write_record PACKAGE_SOURCE network
}

state_write_record() {
	[ "$#" -eq 2 ] || return 1
	state_key_allowed "$1" && state_value_valid "$1" "$2" || return 1
	_state_hex=$(triton_hex_encode "$2") || return 1
	printf '%s=%s\n' "$1" "$_state_hex"
}

state_check_file() {
	[ "$#" -eq 1 ] || return 1
	_state_file=$1
	[ -f "$_state_file" ] && [ ! -L "$_state_file" ] || return 1
	[ "$(triton_stat_uid "$_state_file")" = "$(id -u)" ] || return 1
	_state_seen=' '
	_state_count=0
	while IFS='=' read -r _state_key _state_hex _state_extra; do
		[ -z "$_state_extra" ] || return 1
		state_key_allowed "$_state_key" || return 1
		case "$_state_seen" in *" $_state_key "*) return 1 ;; esac
		triton_hex_is_safe "$_state_hex" || return 1
		_state_value=$(triton_hex_decode "$_state_hex") || return 1
		state_value_valid "$_state_key" "$_state_value" || return 1
		_state_seen="$_state_seen$_state_key "
		_state_count=$((_state_count + 1))
	done <"$_state_file"
	[ "$_state_count" -eq "$STATE_KEY_COUNT" ] || return 1
	for _state_key in $STATE_KEYS; do
		case "$_state_seen" in *" $_state_key "*) : ;; *) return 1 ;; esac
	done
	return 0
}

state_get_from_file() {
	[ "$#" -eq 2 ] || return 1
	_state_file=$1
	_state_wanted=$2
	state_key_allowed "$_state_wanted" || return 1
	_state_hex=$(awk -F= -v wanted="$_state_wanted" '$1 == wanted { print $2; found=1 } END { if (!found) exit 1 }' "$_state_file") || return 1
	triton_hex_decode "$_state_hex"
}

state_consistent_file() {
	[ "$#" -eq 1 ] || return 1
	_state_file=$1
	_state_user=$(state_get_from_file "$_state_file" USERNAME) || return 1
	_state_name=$(state_get_from_file "$_state_file" DISPLAY_NAME) || return 1
	if [ -n "$_state_user$_state_name" ]; then
		[ -n "$_state_user" ] && [ -n "$_state_name" ] || return 1
	fi

	_state_disk_values=''
	for _state_key in DISK_DEVICE DISK_MODEL DISK_SERIAL DISK_BYTES DISK_SECTOR_SIZE; do
		_state_value=$(state_get_from_file "$_state_file" "$_state_key") || return 1
		[ -n "$_state_value" ] && _state_disk_values="$_state_disk_values+" || _state_disk_values="$_state_disk_values-"
	done
	case $_state_disk_values in '-----' | '+++++') : ;; *) return 1 ;; esac
	_state_available=$(state_get_from_file "$_state_file" DISK_AVAILABLE) || return 1
	[ "$_state_disk_values" = +++++ ] || [ "$_state_available" = unknown ] || return 1

	_state_swap=$(state_get_from_file "$_state_file" SWAP_MODE) || return 1
	_state_swap_size=$(state_get_from_file "$_state_file" SWAP_SIZE_MIB) || return 1
	if [ "$_state_swap" = custom ]; then
		validate_positive_decimal "$_state_swap_size" || return 1
	else
		[ -z "$_state_swap_size" ] || return 1
	fi
}

state_check() {
	state_check_file "$TRITON_STATE_FILE" && state_consistent_file "$TRITON_STATE_FILE"
}

state_init() {
	triton_ensure_private_dir "$TRITON_RUNTIME_DIR" || return 1
	if [ -e "$TRITON_STATE_FILE" ] || [ -L "$TRITON_STATE_FILE" ]; then
		[ ! -L "$TRITON_STATE_FILE" ] || return 1
		chmod 600 "$TRITON_STATE_FILE" || return 1
		state_check
		return
	fi
	_state_tmp=$TRITON_RUNTIME_DIR/.installer.state.$$
	(
		umask 077
		state_write_defaults >"$_state_tmp"
	) || {
		rm -f "$_state_tmp"
		return 1
	}
	chmod 600 "$_state_tmp" || {
		rm -f "$_state_tmp"
		return 1
	}
	state_check_file "$_state_tmp" && state_consistent_file "$_state_tmp" || {
		rm -f "$_state_tmp"
		return 1
	}
	mv "$_state_tmp" "$TRITON_STATE_FILE" || {
		rm -f "$_state_tmp"
		return 1
	}
	state_check
}

state_get() {
	[ "$#" -eq 1 ] || return 1
	state_get_from_file "$TRITON_STATE_FILE" "$1"
}

state_apply_updates() {
	[ $(($# % 2)) -eq 0 ] && [ "$#" -gt 0 ] || return 1
	state_check || return 1
	_state_overrides=$TRITON_RUNTIME_DIR/.overrides.$$
	_state_tmp=$TRITON_RUNTIME_DIR/.installer.state.$$
	: >"$_state_overrides" || return 1
	while [ "$#" -gt 0 ]; do
		_state_key=$1
		_state_value=$2
		shift 2
		state_key_allowed "$_state_key" && state_value_valid "$_state_key" "$_state_value" || {
			rm -f "$_state_overrides"
			return 1
		}
		case " $(awk -F= '{print $1}' "$_state_overrides" | tr '\n' ' ') " in *" $_state_key "*)
			rm -f "$_state_overrides"
			return 1
			;;
		esac
		_state_hex=$(triton_hex_encode "$_state_value") || {
			rm -f "$_state_overrides"
			return 1
		}
		printf '%s=%s\n' "$_state_key" "$_state_hex" >>"$_state_overrides" || {
			rm -f "$_state_overrides"
			return 1
		}
	done
	awk -F= 'NR==FNR { value[$1]=$2; next } { if ($1 in value) print $1 "=" value[$1]; else print }' "$_state_overrides" "$TRITON_STATE_FILE" >"$_state_tmp" || {
		rm -f "$_state_overrides" "$_state_tmp"
		return 1
	}
	rm -f "$_state_overrides"
	chmod 600 "$_state_tmp" || {
		rm -f "$_state_tmp"
		return 1
	}
	state_check_file "$_state_tmp" && state_consistent_file "$_state_tmp" || {
		rm -f "$_state_tmp"
		return 1
	}
	mv "$_state_tmp" "$TRITON_STATE_FILE" || {
		rm -f "$_state_tmp"
		return 1
	}
	return 0
}

state_set() {
	[ "$#" -eq 2 ] || return 1
	case $1 in
	USERNAME | DISPLAY_NAME | DISK_DEVICE | DISK_MODEL | DISK_SERIAL | DISK_BYTES | DISK_SECTOR_SIZE | DISK_AVAILABLE | SWAP_MODE | SWAP_SIZE_MIB) return 1 ;;
	esac
	state_apply_updates "$1" "$2"
}

state_set_user() {
	[ "$#" -eq 3 ] || return 1
	state_apply_updates DISPLAY_NAME "$1" USERNAME "$2" ADMIN_ACCESS "$3"
}

state_set_target() {
	[ "$#" -eq 6 ] || return 1
	validate_target_identity "$1" "$2" "$3" "$4" "$5" || return 1
	validate_choice "$6" yes no || return 1
	state_apply_updates DISK_DEVICE "$1" DISK_MODEL "$2" DISK_SERIAL "$3" DISK_BYTES "$4" DISK_SECTOR_SIZE "$5" DISK_AVAILABLE "$6"
}

state_clear_target() {
	state_apply_updates DISK_DEVICE '' DISK_MODEL '' DISK_SERIAL '' DISK_BYTES '' DISK_SECTOR_SIZE '' DISK_AVAILABLE unknown
}

state_set_swap() {
	[ "$#" -eq 2 ] || return 1
	state_apply_updates SWAP_MODE "$1" SWAP_SIZE_MIB "$2"
}

state_user_complete() {
	[ -n "$(state_get USERNAME)" ] && [ -n "$(state_get DISPLAY_NAME)" ]
}

state_target_complete() {
	_state_device=$(state_get DISK_DEVICE) || return 1
	_state_model=$(state_get DISK_MODEL) || return 1
	_state_serial=$(state_get DISK_SERIAL) || return 1
	_state_bytes=$(state_get DISK_BYTES) || return 1
	_state_sector=$(state_get DISK_SECTOR_SIZE) || return 1
	validate_target_identity "$_state_device" "$_state_model" "$_state_serial" "$_state_bytes" "$_state_sector" && [ "$(state_get DISK_AVAILABLE)" = yes ]
}

state_status_user() {
	if state_user_complete; then
		printf '%s · administrator: %s\n' "$(state_get USERNAME)" "$(state_get ADMIN_ACCESS)"
	else
		printf '%s\n' 'Not configured'
	fi
}

state_status_storage() {
	if state_target_complete; then
		printf '%s · %s bytes · %s\n' "$(state_get DISK_MODEL)" "$(state_get DISK_BYTES)" "$(state_get DISK_DEVICE)"
	else
		printf '%s\n' 'Not selected'
	fi
}

state_status_layout() {
	_state_swap=$(state_get SWAP_MODE) || return 1
	[ "$_state_swap" = custom ] && _state_swap="$(state_get SWAP_SIZE_MIB) MiB swap"
	printf '%s · %s · %s · %s\n' "$(state_get BOOT_MODE)" "$(state_get PARTITION_SCHEME)" "$(state_get FILESYSTEM)" "$_state_swap"
}
