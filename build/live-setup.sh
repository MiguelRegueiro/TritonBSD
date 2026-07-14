#!/bin/sh
set -eu

ROOT="${1:-}"
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PKGLIST="$ROOT/usr/local/share/triton/live-pkglist"
DOTFILES_REPO="${TRITON_DOTFILES_REPO:-https://github.com/MiguelRegueiro/regueiro-hyprland.git}"
DOTFILES_BRANCH="${TRITON_DOTFILES_BRANCH:-freebsd}"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work/live-setup}"
DOTFILES_DIR="$WORK_DIR/regueiro-hyprland"
STOW_PACKAGES="hypr quickshell fish starship fastfetch kitty gtk xresources fontconfig mimeapps user-dirs desktop-overrides runin elio"
SPARSE_PACKAGES="$STOW_PACKAGES wallpapers fonts"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "usage: $0 /mounted/freebsd/root" >&2
    exit 1
fi

if [ "$(uname -s)" != "FreeBSD" ]; then
    echo "live-setup.sh must run on FreeBSD." >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "live-setup.sh must run as root." >&2
    exit 1
fi

if [ ! -f "$PKGLIST" ]; then
    echo "Missing live package list: $PKGLIST" >&2
    exit 1
fi

echo "Bootstrapping pkg inside live root"
env ASSUME_ALWAYS_YES=yes pkg -r "$ROOT" bootstrap -y
env ASSUME_ALWAYS_YES=yes pkg -r "$ROOT" update -f

echo "Installing Triton live packages"
xargs env ASSUME_ALWAYS_YES=yes pkg -r "$ROOT" install -y < "$PKGLIST"

if ! command -v git >/dev/null 2>&1; then
    echo "Installing git on the builder for sparse dotfile checkout"
    env ASSUME_ALWAYS_YES=yes pkg install -y git
fi

rm -rf "$DOTFILES_DIR"
mkdir -p "$WORK_DIR"

echo "Fetching Triton desktop skeleton from $DOTFILES_REPO#$DOTFILES_BRANCH"
git clone --depth 1 --filter=blob:none --sparse --branch "$DOTFILES_BRANCH" \
    "$DOTFILES_REPO" "$DOTFILES_DIR"

git -C "$DOTFILES_DIR" sparse-checkout set $SPARSE_PACKAGES

if ! chroot "$ROOT" /usr/sbin/pw usershow triton >/dev/null 2>&1; then
    chroot "$ROOT" /usr/sbin/pw useradd triton -u 1000 -d /home/triton -m -s /bin/sh
fi

for group in wheel operator video; do
    if chroot "$ROOT" /usr/sbin/pw groupshow "$group" >/dev/null 2>&1; then
        chroot "$ROOT" /usr/sbin/pw groupmod "$group" -m triton
    fi
done

TRITON_HOME="$ROOT/home/triton"
mkdir -p "$TRITON_HOME"

echo "Copying desktop skeleton into /home/triton"
for package in $STOW_PACKAGES; do
    if [ -d "$DOTFILES_DIR/$package" ]; then
        tar -C "$DOTFILES_DIR/$package" -cf - . | tar -C "$TRITON_HOME" -xpf -
    fi
done

mkdir -p "$TRITON_HOME/regueiro-hyprland"
for package in $SPARSE_PACKAGES; do
    if [ -d "$DOTFILES_DIR/$package" ]; then
        tar -C "$DOTFILES_DIR" -cf - "$package" | tar -C "$TRITON_HOME/regueiro-hyprland" -xpf -
    fi
done

mkdir -p "$TRITON_HOME/.local/share/fonts"
if [ -d "$DOTFILES_DIR/fonts" ]; then
    tar -C "$DOTFILES_DIR/fonts" -cf - . | tar -C "$TRITON_HOME/.local/share/fonts" -xpf -
fi

chroot "$ROOT" /usr/sbin/chown -R triton:triton /home/triton

echo "Enabling live desktop services"
sysrc -f "$ROOT/etc/rc.conf" dbus_enable=YES
sysrc -f "$ROOT/etc/rc.conf" seatd_enable=YES
sysrc -f "$ROOT/etc/rc.conf" powerd_enable=YES
sysrc -f "$ROOT/etc/rc.conf" powerd_flags="-a hiadaptive -b adaptive -n adaptive"

mkdir -p "$ROOT/root"
if [ -f "$ROOT/root/.profile" ] && [ ! -f "$ROOT/root/.profile.freebsd-installer" ]; then
    cp "$ROOT/root/.profile" "$ROOT/root/.profile.freebsd-installer"
fi

cat > "$ROOT/root/.profile" <<'EOF'
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
export PATH

if [ -x /usr/local/sbin/triton-live-start ]; then
    exec /usr/local/sbin/triton-live-start
fi

exec bsdinstall
EOF

echo "Triton live setup complete"
