#!/bin/sh
# Pure validation helpers. No function mutates installer or system state.

validate_nonempty_safe() {
	[ "$#" -eq 2 ] || return 1
	[ -n "$1" ] && triton_is_safe_text "$1" || return 1
	_validate_len=$(LC_ALL=C printf '%s' "$1" | wc -c | tr -d ' ')
	[ "$_validate_len" -le "$2" ]
}

validate_hostname() {
	[ "$#" -eq 1 ] || return 1
	validate_nonempty_safe "$1" 63 || return 1
	case $1 in
	-* | *- | *[!A-Za-z0-9-]*) return 1 ;;
	esac
}

validate_username() {
	[ "$#" -eq 1 ] || return 1
	validate_nonempty_safe "$1" 32 || return 1
	LC_ALL=C printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[a-z_][a-z0-9_-]*$' || return 1
	case $1 in *-) return 1 ;; esac
}

validate_display_name() {
	[ "$#" -eq 1 ] || return 1
	validate_nonempty_safe "$1" 64 || return 1
	case $1 in *:*) return 1 ;; esac
}

validate_keymap() {
	[ "$#" -eq 1 ] || return 1
	validate_nonempty_safe "$1" 64 || return 1
	case $1 in
	.* | *. | *..* | */* | *[!A-Za-z0-9_.-]*) return 1 ;;
	esac
}

validate_locale() {
	[ "$#" -eq 1 ] || return 1
	triton_is_safe_text "$1" || return 1
	case $1 in C | POSIX) return 0 ;; esac
	LC_ALL=C printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[a-z][a-z]_[A-Z][A-Z]\.UTF-8$'
}

validate_timezone() {
	[ "$#" -eq 1 ] || return 1
	validate_nonempty_safe "$1" 128 || return 1
	[ "$1" = UTC ] && return 0
	case $1 in
	/* | .* | *. | *..* | *//* | *[!A-Za-z0-9_+./-]* | */*/*/*) return 1 ;;
	*/*) return 0 ;;
	*) return 1 ;;
	esac
}

validate_choice() {
	[ "$#" -ge 2 ] || return 1
	_validate_wanted=$1
	shift
	triton_is_safe_text "$_validate_wanted" || return 1
	for _validate_choice; do
		[ "$_validate_wanted" = "$_validate_choice" ] && return 0
	done
	return 1
}

validate_positive_decimal() {
	[ "$#" -eq 1 ] || return 1
	case $1 in '' | *[!0-9]*) return 1 ;; esac
	_validate_positive=$(printf '%s' "$1" | sed 's/^0*//')
	[ -n "$_validate_positive" ]
}

validate_interface() {
	[ "$#" -eq 1 ] || return 1
	[ "$1" = auto ] && return 0
	validate_nonempty_safe "$1" 32 || return 1
	case $1 in *[!A-Za-z0-9_.:-]*) return 1 ;; esac
}

validate_disk_device() {
	[ "$#" -eq 1 ] || return 1
	case $1 in /dev/*) _validate_provider=${1#/dev/} ;; *) return 1 ;; esac
	validate_nonempty_safe "$_validate_provider" 128 || return 1
	case $_validate_provider in */* | .* | *. | *..* | *[!A-Za-z0-9_.-]*) return 1 ;; esac
}

validate_target_identity() {
	[ "$#" -eq 5 ] || return 1
	validate_disk_device "$1" || return 1
	validate_nonempty_safe "$2" 128 || return 1
	validate_nonempty_safe "$3" 128 || return 1
	validate_positive_decimal "$4" || return 1
	validate_positive_decimal "$5"
}
