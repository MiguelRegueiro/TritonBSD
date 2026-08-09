#!/bin/sh
# Shared primitives for the non-destructive Triton installer.

umask 077

triton_is_safe_text() {
	[ "$#" -eq 1 ] || return 1
	_triton_newline='
'
	case $1 in *"$_triton_newline"*) return 1 ;; esac
	LC_ALL=C printf '%s' "$1" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1 && return 1
	return 0
}

triton_stat_uid() {
	if stat -c '%u' "$1" >/dev/null 2>&1; then
		stat -c '%u' "$1"
	else
		stat -f '%u' "$1"
	fi
}

triton_stat_mode() {
	if stat -c '%a' "$1" >/dev/null 2>&1; then
		stat -c '%a' "$1"
	else
		stat -f '%Lp' "$1"
	fi
}

triton_ensure_private_dir() {
	[ "$#" -eq 1 ] || return 1
	_triton_dir=$1
	if [ -e "$_triton_dir" ] || [ -L "$_triton_dir" ]; then
		[ -d "$_triton_dir" ] && [ ! -L "$_triton_dir" ] || return 1
	else
		mkdir -m 700 "$_triton_dir" || return 1
	fi
	[ "$(triton_stat_uid "$_triton_dir")" = "$(id -u)" ] || return 1
	chmod 700 "$_triton_dir" || return 1
	[ "$(triton_stat_mode "$_triton_dir")" = 700 ]
}

triton_hex_encode() {
	[ "$#" -eq 1 ] || return 1
	triton_is_safe_text "$1" || return 1
	LC_ALL=C printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

triton_hex_is_safe() {
	[ "$#" -eq 1 ] || return 1
	_triton_hex=$1
	case $_triton_hex in *[!0123456789abcdef]*) return 1 ;; esac
	[ $((${#_triton_hex} % 2)) -eq 0 ] || return 1
	awk -v h="$_triton_hex" 'BEGIN {
        digits = "0123456789abcdef"
        for (i = 1; i <= length(h); i += 2) {
            hi = index(digits, substr(h, i, 1)) - 1
            lo = index(digits, substr(h, i + 1, 1)) - 1
            n = hi * 16 + lo
            if (hi < 0 || lo < 0 || n < 32 || n == 127)
                exit 1
        }
    }'
}

triton_hex_decode() {
	[ "$#" -eq 1 ] || return 1
	triton_hex_is_safe "$1" || return 1
	_triton_escapes=$(awk -v h="$1" 'BEGIN {
        digits = "0123456789abcdef"
        for (i = 1; i <= length(h); i += 2) {
            hi = index(digits, substr(h, i, 1)) - 1
            lo = index(digits, substr(h, i + 1, 1)) - 1
            printf "\\%03o", hi * 16 + lo
        }
    }') || return 1
	printf '%b' "$_triton_escapes"
}
