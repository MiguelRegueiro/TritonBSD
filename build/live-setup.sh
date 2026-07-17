#!/bin/sh
set -eu

ROOT="${1:-}"
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PKGLIST="$ROOT/usr/local/share/triton/live-pkglist"
DOTFILES_REPO="${TRITON_DOTFILES_REPO:-https://github.com/MiguelRegueiro/regueiro-hyprland.git}"
DOTFILES_BRANCH="${TRITON_DOTFILES_BRANCH:-freebsd}"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work/live-setup}"
DOTFILES_DIR="$WORK_DIR/regueiro-hyprland"
PKG_CACHE="$WORK_DIR/pkg-cache"
STOW_PACKAGES="hypr quickshell fish starship fastfetch kitty gtk xresources fontconfig mimeapps user-dirs desktop-overrides runin elio"
SPARSE_PACKAGES="$STOW_PACKAGES wallpapers fonts icons/Bibata-Modern-Classic"

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
mkdir -p "$PKG_CACHE"
env ASSUME_ALWAYS_YES=yes pkg -o "PKG_CACHEDIR=$PKG_CACHE" -r "$ROOT" bootstrap -y
env ASSUME_ALWAYS_YES=yes pkg -o "PKG_CACHEDIR=$PKG_CACHE" -r "$ROOT" update -f

echo "Installing Triton live packages"
xargs env ASSUME_ALWAYS_YES=yes pkg -o "PKG_CACHEDIR=$PKG_CACHE" -r "$ROOT" install -y < "$PKGLIST"
env ASSUME_ALWAYS_YES=yes pkg -o "PKG_CACHEDIR=$PKG_CACHE" -r "$ROOT" clean -ay
rm -rf "$PKG_CACHE"

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

if [ -x "$ROOT/usr/local/bin/fish" ]; then
    touch "$ROOT/etc/shells"
    grep -qxF /usr/local/bin/fish "$ROOT/etc/shells" || echo /usr/local/bin/fish >> "$ROOT/etc/shells"
    TRITON_SHELL=/usr/local/bin/fish
else
    TRITON_SHELL=/bin/sh
fi

if ! chroot "$ROOT" /usr/sbin/pw usershow triton >/dev/null 2>&1; then
    chroot "$ROOT" /usr/sbin/pw useradd triton -u 1000 -d /home/triton -m -s "$TRITON_SHELL"
else
    chroot "$ROOT" /usr/sbin/pw usermod triton -s "$TRITON_SHELL"
fi

for group in wheel operator video seatd realtime; do
    if chroot "$ROOT" /usr/sbin/pw groupshow "$group" >/dev/null 2>&1; then
        chroot "$ROOT" /usr/sbin/pw groupmod "$group" -m triton
    fi
done

mkdir -p "$ROOT/usr/local/etc"
cat > "$ROOT/usr/local/etc/doas.conf" <<'EOF'
permit nopass keepenv :wheel
EOF
chmod 0440 "$ROOT/usr/local/etc/doas.conf"

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

mkdir -p "$TRITON_HOME/.local/share/icons"
if [ -d "$DOTFILES_DIR/icons" ]; then
    tar -C "$DOTFILES_DIR/icons" -cf - . | tar -C "$TRITON_HOME/.local/share/icons" -xpf -
    mkdir -p "$TRITON_HOME/.icons"
    if [ -d "$TRITON_HOME/.local/share/icons/MacTahoe-dark" ]; then
        ln -sfn ../.local/share/icons/MacTahoe-dark "$TRITON_HOME/.icons/MacTahoe-dark"
    fi
    if [ -d "$TRITON_HOME/.local/share/icons/Bibata-Modern-Classic" ]; then
        ln -sfn ../.local/share/icons/Bibata-Modern-Classic "$TRITON_HOME/.icons/Bibata-Modern-Classic"
    fi
fi

mkdir -p "$TRITON_HOME/.config/fontconfig/conf.d"
cat > "$TRITON_HOME/.config/fontconfig/conf.d/99-triton-nerd-symbols.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias>
    <family>Symbols Nerd Font Mono</family>
    <prefer>
      <family>Symbols Nerd Font Mono</family>
      <family>Symbols Nerd Font</family>
      <family>JetBrainsMono Nerd Font</family>
      <family>Hack Nerd Font</family>
    </prefer>
  </alias>
</fontconfig>
EOF

if chroot "$ROOT" /usr/local/bin/fc-cache -f /usr/local/share/fonts /home/triton/.local/share/fonts >/dev/null 2>&1; then
    echo "Refreshed live user font cache"
else
    echo "Warning: failed to refresh live user font cache" >&2
fi

if [ -f "$TRITON_HOME/.config/hypr/conf/autostart.conf" ]; then
    sed -i '' 's/^exec-once = hypridle -q/# live: disabled hypridle auto-lock; no password-backed unlock in live media/' \
        "$TRITON_HOME/.config/hypr/conf/autostart.conf"
fi

STARSHIP_CONFIG="$TRITON_HOME/.config/starship.toml"
if [ -f "$STARSHIP_CONFIG" ] && ! grep -q '^scan_timeout[[:space:]]*=' "$STARSHIP_CONFIG"; then
    tmp_starship="${STARSHIP_CONFIG}.tmp"
    {
        echo 'scan_timeout = 200'
        cat "$STARSHIP_CONFIG"
    } > "$tmp_starship"
    mv "$tmp_starship" "$STARSHIP_CONFIG"
fi

for settings in \
    "$TRITON_HOME/.config/gtk-3.0/settings.ini" \
    "$TRITON_HOME/.config/gtk-4.0/settings.ini" \
    "$TRITON_HOME/.gtkrc-2.0" \
    "$TRITON_HOME/.config/hypr/scripts/apply-appearance.sh"; do
    if [ -f "$settings" ]; then
        sed -i '' 's/MacTahoe-dark/Adwaita/g' "$settings"
    fi
done

chroot "$ROOT" /usr/sbin/chown -R triton:triton /home/triton

echo "Enabling live desktop services"
sysrc -f "$ROOT/etc/rc.conf" dbus_enable=NO
sysrc -f "$ROOT/etc/rc.conf" seatd_enable=NO
sysrc -f "$ROOT/etc/rc.conf" devfs_enable=YES
sysrc -f "$ROOT/etc/rc.conf" devfs_system_ruleset=10
sysrc -f "$ROOT/etc/rc.conf" powerd_enable=YES
sysrc -f "$ROOT/etc/rc.conf" powerd_flags='-a hiadaptive -b adaptive -n adaptive'
sysrc -f "$ROOT/etc/rc.conf" kld_list="i915kms acpi_video ng_ubt ng_hci ng_l2cap ng_btsocket fusefs"
sysrc -f "$ROOT/etc/rc.conf" wlans_rtw880=wlan0
sysrc -f "$ROOT/etc/rc.conf" create_args_wlan0="country ES regdomain ETSI"
sysrc -f "$ROOT/etc/rc.conf" ifconfig_wlan0="WPA SYNCDHCP"
sysrc -f "$ROOT/etc/rc.conf" hcsecd_enable=YES
sysrc -f "$ROOT/etc/rc.conf" bthidd_enable=YES

"$PROJECT_DIR/build/configure-live-boot.sh" "$ROOT"

TEMPLATE="$ROOT/usr/local/share/triton/live-home-template"
rm -rf "$TEMPLATE"
mkdir -p "$(dirname "$TEMPLATE")"
mv "$TRITON_HOME" "$TEMPLATE"
mkdir -p "$TRITON_HOME"
chroot "$ROOT" /usr/sbin/chown -R triton:triton /usr/local/share/triton/live-home-template /home/triton
chroot "$ROOT" /bin/chmod 755 /home/triton

echo "Triton live setup complete"
