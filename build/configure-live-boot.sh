#!/bin/sh
set -eu

ROOT="${1:-}"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "usage: $0 /mounted/freebsd/root" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "configure-live-boot.sh must run as root." >&2
    exit 1
fi

backup_once() {
    file="$1"
    backup="$2"

    if [ -f "$file" ] && [ ! -f "$backup" ]; then
        cp -p "$file" "$backup"
    fi
}

TRITON_HOME="$ROOT/home/triton"

mkdir -p "$ROOT/etc" "$ROOT/root" "$TRITON_HOME"

echo "Configuring TrueOS/GhostBSD-style live boot handoff"

backup_once "$ROOT/etc/rc.local" "$ROOT/etc/rc.local.freebsd-installer"
cat > "$ROOT/etc/rc.local" <<'EOF'
#!/bin/sh

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

LOG=/tmp/triton-live.log
touch "$LOG"
chown triton:triton "$LOG" 2>/dev/null || true
chmod 664 "$LOG" 2>/dev/null || true

{
    echo "==== Triton live rc.local $(date) ===="
    uname -a
    echo "Preparing writable runtime paths"
} >> "$LOG" 2>&1

prepare_live_home() {
    template=/usr/local/share/triton/live-home-template
    if ! mount | grep -q ' on /home/triton '; then
        echo "Preparing writable live home" >> "$LOG"
        mdmfs -s 1024m -p 0755 -w triton:triton auto /home/triton >> "$LOG" 2>&1 || \
            echo "Warning: failed to mount writable /home/triton" >> "$LOG"
        if mount | grep -q ' on /home/triton ' && [ -d "$template" ]; then
            tar -C "$template" -cf - . 2>> "$LOG" | tar -C /home/triton -xpf - 2>> "$LOG" || true
        fi
    fi
    mkdir -p \
        /tmp/triton-runtime \
        /home/triton/.cache/hyprland \
        /home/triton/.cache/hyprland/crashreports \
        /home/triton/.local/state \
        /home/triton/.local/share
    chown -R triton:triton /home/triton /tmp/triton-runtime 2>/dev/null || true
    chmod 700 /tmp/triton-runtime /home/triton/.cache /home/triton/.local/state /home/triton/.local/share 2>/dev/null || true
}

mkdir -p /tmp/install_etc /tmp/triton-runtime 2>/dev/null || true
prepare_live_home

service dbus onestart >> "$LOG" 2>&1 || true
service seatd onestart >> "$LOG" 2>&1 || true
service powerd onestart >> "$LOG" 2>&1 || true

for module in \
    fusefs \
    wlan wlan_ccmp wlan_tkip wlan_wep \
    if_rtw88 if_iwlwifi if_iwm if_iwx if_ath if_rtwn if_run if_rum if_uath \
    ng_ubt ng_hci ng_l2cap ng_btsocket; do
    kldload -n "$module" >> "$LOG" 2>&1 || true
done

wifi_parent=""
if ! ifconfig wlan0 >/dev/null 2>&1; then
    wifi_parent="$(sysctl -n net.wlan.devices 2>/dev/null | awk '{ print $1 }')"
    if [ -z "$wifi_parent" ]; then
        for parent in rtw880 rtw8800 iwlwifi0 iwm0 iwx0 ath0 rtwn0 rum0 run0 uath0; do
            if ifconfig "$parent" >/dev/null 2>&1; then
                wifi_parent="$parent"
                break
            fi
        done
    fi
    if [ -n "$wifi_parent" ]; then
        echo "Creating wlan0 from $wifi_parent" >> "$LOG"
        ifconfig wlan0 create wlandev "$wifi_parent" >> "$LOG" 2>&1 || true
    fi
fi
if ifconfig wlan0 >/dev/null 2>&1; then
    if [ -n "${wifi_parent:-}" ]; then
        sysrc "wlans_${wifi_parent}=wlan0" >> "$LOG" 2>&1 || true
    fi
    sysrc ifconfig_wlan0="WPA SYNCDHCP" >> "$LOG" 2>&1 || true
    ifconfig wlan0 country ES regdomain ETSI up >> "$LOG" 2>&1 || true
fi

service hcsecd onestart >> "$LOG" 2>&1 || true
service bthidd onestart >> "$LOG" 2>&1 || true

if [ -x /usr/local/sbin/triton-gpu-preflight ]; then
    /usr/local/sbin/triton-gpu-preflight --load >> "$LOG" 2>&1 || true
fi

clear
echo "TritonBSD live environment"
echo
echo "Starting the Triton desktop on ttyv0."
echo "Log: $LOG"
echo

exec /usr/local/sbin/triton-live-start
EOF
chmod 555 "$ROOT/etc/rc.local"

if [ -f "$ROOT/etc/gettytab" ] && ! grep -q '^triton-live|' "$ROOT/etc/gettytab"; then
    cat >> "$ROOT/etc/gettytab" <<'EOF'

# TritonBSD live user autologin
triton-live|TritonBSD live autologin:\
	:al=triton:ht:np:sp#115200:
EOF
fi

touch "$ROOT/etc/devfs.rules"
if ! grep -q '^\[triton_live=' "$ROOT/etc/devfs.rules"; then
    cat >> "$ROOT/etc/devfs.rules" <<'EOF'

[triton_live=10]
add path 'dri' unhide mode 0755
add path 'dri/*' unhide mode 0660 group video
add path 'drm' unhide mode 0755
add path 'drm/*' unhide mode 0660 group video
add path 'input' unhide mode 0755
add path 'input/*' unhide mode 0660 group video
EOF
fi

if [ -f "$ROOT/etc/ttys" ]; then
    backup_once "$ROOT/etc/ttys" "$ROOT/etc/ttys.freebsd-installer"
    awk '
        BEGIN { done = 0 }
        $1 == "ttyv0" {
            print "ttyv0\t\"/usr/libexec/getty triton-live\"\txterm\ton  secure"
            done = 1
            next
        }
        { print }
        END {
            if (done == 0) {
                print "ttyv0\t\"/usr/libexec/getty triton-live\"\txterm\ton  secure"
            }
        }
    ' "$ROOT/etc/ttys" > "$ROOT/etc/ttys.triton"
    mv "$ROOT/etc/ttys.triton" "$ROOT/etc/ttys"
fi

backup_once "$ROOT/root/.profile" "$ROOT/root/.profile.freebsd-installer"
cat > "$ROOT/root/.profile" <<'EOF'
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

echo "TritonBSD live root shell."
echo "Run triton-install to start the installer."
echo "Run /usr/local/sbin/triton-live-start to retry the live desktop."
EOF

backup_once "$ROOT/root/.login" "$ROOT/root/.login.freebsd-installer"
cat > "$ROOT/root/.login" <<'EOF'
setenv PATH /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

echo "TritonBSD live root shell."
echo "Run triton-install to start the installer."
echo "Run /usr/local/sbin/triton-live-start to retry the live desktop."
EOF

cat > "$TRITON_HOME/.profile" <<'EOF'
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

if [ "$(tty 2>/dev/null || true)" = "/dev/ttyv0" ] &&
    [ -x /usr/local/sbin/triton-live-start ] &&
    [ ! -f /tmp/.triton-live-started ]; then
    touch /tmp/.triton-live-started
    exec /usr/local/sbin/triton-live-start
fi
EOF

cat > "$TRITON_HOME/.config/fish/conf.d/triton-live-start.fish" <<'EOF'
if test (tty 2>/dev/null) = /dev/ttyv0
    and test -x /usr/local/sbin/triton-live-start
    and not test -f /tmp/.triton-live-started
    set -gx HOME /home/triton
    set -gx USER triton
    set -gx LOGNAME triton
    set -gx XDG_CONFIG_HOME /home/triton/.config
    set -gx XDG_CACHE_HOME /home/triton/.cache
    set -gx XDG_DATA_HOME /home/triton/.local/share
    set -gx XDG_STATE_HOME /home/triton/.local/state
    mkdir -p $XDG_CONFIG_HOME $XDG_CACHE_HOME $XDG_DATA_HOME $XDG_STATE_HOME 2>/dev/null
    touch /tmp/.triton-live-started
    exec /usr/local/sbin/triton-live-start
end
EOF

cat > "$TRITON_HOME/.start-hyprland" <<'EOF'
#!/bin/sh

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

export HOME="${HOME:-/home/triton}"
export USER="${USER:-triton}"
export LOGNAME="${LOGNAME:-triton}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/triton-runtime}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/home/triton/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/home/triton/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-/home/triton/.local/state}"
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Hyprland
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_ID="${XDG_SESSION_ID:-triton-live}"
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1
export XCURSOR_THEME="${XCURSOR_THEME:-Bibata-Modern-Classic}"
export XCURSOR_SIZE="${XCURSOR_SIZE:-24}"
export HYPRCURSOR_THEME="${HYPRCURSOR_THEME:-Bibata-Modern-Classic}"
export HYPRCURSOR_SIZE="${HYPRCURSOR_SIZE:-24}"
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-seatd}"
export WLR_RENDERER_ALLOW_SOFTWARE="${WLR_RENDERER_ALLOW_SOFTWARE:-1}"

mkdir -p \
    "$XDG_RUNTIME_DIR" \
    "$XDG_CONFIG_HOME" \
    "$XDG_CACHE_HOME" \
    "$XDG_CACHE_HOME/hyprland" \
    "$XDG_CACHE_HOME/hyprland/crashreports" \
    "$XDG_DATA_HOME" \
    "$XDG_STATE_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

if command -v triton-gpu-preflight >/dev/null 2>&1; then
    if ! triton-gpu-preflight --check; then
        echo
        echo "Triton desktop cannot start: no DRM/KMS GPU is available."
        echo "QEMU: current FreeBSD drm-kmod packages do not expose virtio-gpu KMS here."
        echo "QEMU: the helper can test boot and shell flow, but not Hyprland yet."
        echo "Hardware: the matching drm-kmod driver/firmware must load."
        echo
        exit 78
    fi
elif ! ls /dev/dri/card* >/dev/null 2>&1; then
    echo "No /dev/dri/card* device present; Hyprland cannot start."
    echo "QEMU: current FreeBSD drm-kmod packages do not expose virtio-gpu KMS here."
    exit 78
fi

if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
    export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"
fi

echo "==== Triton Hyprland launch environment ===="
echo "user: $(id)"
echo "tty: $(tty 2>/dev/null || true)"
echo "HOME=$HOME"
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo "XDG_CACHE_HOME=$XDG_CACHE_HOME"
echo "LIBSEAT_BACKEND=$LIBSEAT_BACKEND"
echo "WLR_RENDERER_ALLOW_SOFTWARE=$WLR_RENDERER_ALLOW_SOFTWARE"
echo "LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-}"
ls -ld "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CACHE_HOME/hyprland" "$XDG_CACHE_HOME/hyprland/crashreports"
ls -l /dev/dri 2>/dev/null || echo "No /dev/dri devices present"
service seatd onestatus 2>/dev/null || true
echo "Hyprland: $(command -v Hyprland 2>/dev/null || command -v hyprland 2>/dev/null || echo missing)"
echo

cd "$HOME" 2>/dev/null || true

if command -v start-hyprland >/dev/null 2>&1; then
    exec dbus-run-session start-hyprland
fi

if command -v Hyprland >/dev/null 2>&1; then
    exec dbus-run-session Hyprland
fi

if command -v hyprland >/dev/null 2>&1; then
    exec dbus-run-session hyprland
fi

echo "Hyprland executable not found."
exit 127
EOF
chmod 755 "$TRITON_HOME/.start-hyprland"

mkdir -p "$TRITON_HOME/.config/hypr"
if [ ! -f "$TRITON_HOME/.config/hypr/hyprland.conf" ]; then
    cat > "$TRITON_HOME/.config/hypr/hyprland.conf" <<'EOF'
debug:disable_logs = false

monitor=,preferred,auto,1

exec-once = sh -c "quickshell || kitty || xterm"

input {
    kb_layout = us
}

bind = SUPER, RETURN, exec, sh -c "kitty || xterm"
bind = SUPER, Q, killactive
bind = SUPER, M, exit
EOF
fi

chroot "$ROOT" /usr/sbin/chown -R triton:triton /home/triton

echo "Triton live boot handoff configured"
