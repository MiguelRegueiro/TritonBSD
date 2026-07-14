#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMG="${1:-$PROJECT_DIR/artifacts/TritonBSD-15.1-RELEASE-amd64-bootstrap-memstick.img}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEM="${QEMU_MEM:-4096}"

if [ ! -f "$IMG" ]; then
    echo "Missing image: $IMG" >&2
    echo "Download the GitHub Actions artifact and decompress the .img.xz first." >&2
    exit 1
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "Missing QEMU binary: $QEMU_BIN" >&2
    exit 1
fi

KVM_ARGS="-enable-kvm -cpu host"
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Warning: /dev/kvm is not accessible; running without KVM acceleration." >&2
    KVM_ARGS="-cpu max"
fi

exec "$QEMU_BIN" \
    $KVM_ARGS \
    -machine q35 \
    -m "$QEMU_MEM" \
    -device qemu-xhci \
    -drive "if=none,id=stick,format=raw,readonly=on,file=$IMG" \
    -device usb-storage,drive=stick,bootindex=1 \
    -netdev user,id=net0 \
    -device e1000,netdev=net0

