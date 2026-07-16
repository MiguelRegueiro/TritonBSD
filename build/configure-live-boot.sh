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

mkdir -p \
    /tmp/install_etc \
    /tmp/triton-runtime \
    /tmp/triton-cache/hyprland \
    /tmp/triton-state \
    /tmp/triton-data
chown -R triton:triton \
    /tmp/triton-runtime \
    /tmp/triton-cache \
    /tmp/triton-state \
    /tmp/triton-data 2>/dev/null || true
chmod 700 \
    /tmp/triton-runtime \
    /tmp/triton-cache \
    /tmp/triton-cache/hyprland \
    /tmp/triton-state \
    /tmp/triton-data 2>/dev/null || true

service dbus onestart >> "$LOG" 2>&1 || true
service seatd onestart >> "$LOG" 2>&1 || true

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

cat > "$TRITON_HOME/.start-hyprland" <<'EOF'
#!/bin/sh

PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

export HOME="${HOME:-/home/triton}"
export USER="${USER:-triton}"
export LOGNAME="${LOGNAME:-triton}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/triton-runtime}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/triton-cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/tmp/triton-data}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-/tmp/triton-state}"
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Hyprland
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_ID="${XDG_SESSION_ID:-triton-live}"
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1
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
