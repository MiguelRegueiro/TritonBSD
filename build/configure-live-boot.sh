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

mkdir -p /tmp/install_etc /tmp/triton-runtime
chown triton:triton /tmp/triton-runtime 2>/dev/null || true
chmod 700 /tmp/triton-runtime 2>/dev/null || true

service dbus onestart >> "$LOG" 2>&1 || true
service seatd onestart >> "$LOG" 2>&1 || true

clear
echo "TritonBSD live environment"
echo
echo "Autologin on ttyv0 will start the Triton desktop."
echo "Log: $LOG"
echo

exit 0
EOF
chmod 555 "$ROOT/etc/rc.local"

if [ -f "$ROOT/etc/gettytab" ] && ! grep -q '^triton-live|' "$ROOT/etc/gettytab"; then
    cat >> "$ROOT/etc/gettytab" <<'EOF'

# TritonBSD live user autologin
triton-live|TritonBSD live autologin:\
	:al=triton:ht:np:sp#115200:
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

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/triton-runtime}"
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=Hyprland
export XDG_CURRENT_DESKTOP=Hyprland
export QT_QPA_PLATFORM=wayland
export MOZ_ENABLE_WAYLAND=1
export LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-seatd}"
export WLR_RENDERER_ALLOW_SOFTWARE="${WLR_RENDERER_ALLOW_SOFTWARE:-1}"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

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
