#!/bin/sh
set -eu

ROOT="${1:-}"

if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "usage: $0 /mounted/freebsd/root" >&2
    exit 1
fi

cat >&2 <<'EOF'
live-setup.sh is a placeholder for the next milestone.

It will:
  1. install Triton desktop packages into the mounted image root
  2. create the triton live user
  3. copy desktop/skel into /home/triton
  4. enable dbus, seatd, and desktop services
  5. configure Hyprland startup
EOF

exit 1

