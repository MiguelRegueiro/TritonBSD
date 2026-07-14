#!/bin/sh
set -eu

PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIVE_IMG="$PROJECT_DIR/artifacts/TritonBSD-15.1-RELEASE-amd64-live-memstick.img"
BOOTSTRAP_IMG="$PROJECT_DIR/artifacts/TritonBSD-15.1-RELEASE-amd64-bootstrap-memstick.img"
if [ "$#" -gt 0 ]; then
    IMG="$1"
elif [ -f "$LIVE_IMG" ]; then
    IMG="$LIVE_IMG"
else
    IMG="$BOOTSTRAP_IMG"
fi
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEM="${QEMU_MEM:-4096}"
QEMU_BOOT_MODE="${QEMU_BOOT_MODE:-virtio}"
QEMU_SERIAL="${QEMU_SERIAL:-none}"
QEMU_SERIAL_LOG="${QEMU_SERIAL_LOG:-$PROJECT_DIR/artifacts/qemu-serial.log}"

if [ ! -f "$IMG" ]; then
    echo "Missing image: $IMG" >&2
    echo "Download the GitHub Actions artifact and decompress the .img.xz first." >&2
    exit 1
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "Missing QEMU binary: $QEMU_BIN" >&2
    exit 1
fi

KVM_MODE="enabled"
KVM_ARGS="-enable-kvm -cpu host"
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "Warning: /dev/kvm is not accessible; running without KVM acceleration." >&2
    KVM_MODE="disabled"
    KVM_ARGS="-cpu max"
fi

case "$QEMU_SERIAL" in
    none|stdio|log)
        ;;
    *)
        echo "Unsupported QEMU_SERIAL: $QEMU_SERIAL" >&2
        echo "Use QEMU_SERIAL=none, QEMU_SERIAL=stdio, or QEMU_SERIAL=log." >&2
        exit 1
        ;;
esac

IMAGE_SIZE=$(du -h "$IMG" | awk '{ print $1 }')

echo "TritonBSD QEMU runner"
echo "  image:      $IMG"
echo "  size:       $IMAGE_SIZE"
echo "  boot mode:  $QEMU_BOOT_MODE"
echo "  memory:     ${QEMU_MEM} MiB"
echo "  kvm:        $KVM_MODE"
echo "  serial:     $QEMU_SERIAL"
if [ "$QEMU_SERIAL" = "none" ]; then
    echo "  debug:      use QEMU_SERIAL=stdio or QEMU_SERIAL=log for guest serial output"
elif [ "$QEMU_SERIAL" = "stdio" ]; then
    echo "  note:       guest serial output will appear in this terminal if enabled"
elif [ "$QEMU_SERIAL" = "log" ]; then
    mkdir -p "$(dirname "$QEMU_SERIAL_LOG")"
    : > "$QEMU_SERIAL_LOG"
    echo "  serial log: $QEMU_SERIAL_LOG"
    echo "  follow:     tail -f $QEMU_SERIAL_LOG"
fi
echo
echo "Starting QEMU. Watch the VM window for boot progress."
echo "Close the VM window or stop QEMU to return to this shell."
echo

run_qemu() {
    set +e
    "$@"
    status=$?
    set -e

    echo
    echo "QEMU exited with status $status."
    exit "$status"
}

case "$QEMU_BOOT_MODE" in
    virtio)
        case "$QEMU_SERIAL" in
            none)
                run_qemu "$QEMU_BIN" \
                    $KVM_ARGS \
                    -machine q35 \
                    -m "$QEMU_MEM" \
                    -vga virtio \
                    -drive "if=none,id=stick,format=raw,file=$IMG" \
                    -device virtio-blk-pci,drive=stick,bootindex=1 \
                    -netdev user,id=net0 \
                    -device e1000,netdev=net0
                ;;
            stdio)
                run_qemu "$QEMU_BIN" \
                    $KVM_ARGS \
                    -machine q35 \
                    -m "$QEMU_MEM" \
                    -vga virtio \
                    -drive "if=none,id=stick,format=raw,file=$IMG" \
                    -device virtio-blk-pci,drive=stick,bootindex=1 \
                    -netdev user,id=net0 \
                    -device e1000,netdev=net0 \
                    -serial stdio
                ;;
            log)
                run_qemu "$QEMU_BIN" \
                    $KVM_ARGS \
                    -machine q35 \
                    -m "$QEMU_MEM" \
                    -vga virtio \
                    -drive "if=none,id=stick,format=raw,file=$IMG" \
                    -device virtio-blk-pci,drive=stick,bootindex=1 \
                    -netdev user,id=net0 \
                    -device e1000,netdev=net0 \
                    -serial "file:$QEMU_SERIAL_LOG"
                ;;
        esac
        ;;
    usb)
        case "$QEMU_SERIAL" in
            none)
                run_qemu "$QEMU_BIN" \
                    $KVM_ARGS \
                    -machine q35 \
                    -m "$QEMU_MEM" \
                    -device qemu-xhci \
                    -drive "if=none,id=stick,format=raw,file=$IMG" \
                    -device usb-storage,drive=stick,bootindex=1 \
                    -netdev user,id=net0 \
                    -device e1000,netdev=net0
                ;;
            stdio)
                run_qemu "$QEMU_BIN" \
                    $KVM_ARGS \
                    -machine q35 \
                    -m "$QEMU_MEM" \
                    -device qemu-xhci \
                    -drive "if=none,id=stick,format=raw,file=$IMG" \
                    -device usb-storage,drive=stick,bootindex=1 \
                    -netdev user,id=net0 \
                    -device e1000,netdev=net0 \
                    -serial stdio
                ;;
            log)
                run_qemu "$QEMU_BIN" \
                    $KVM_ARGS \
                    -machine q35 \
                    -m "$QEMU_MEM" \
                    -device qemu-xhci \
                    -drive "if=none,id=stick,format=raw,file=$IMG" \
                    -device usb-storage,drive=stick,bootindex=1 \
                    -netdev user,id=net0 \
                    -device e1000,netdev=net0 \
                    -serial "file:$QEMU_SERIAL_LOG"
                ;;
        esac
        ;;
    *)
        echo "Unsupported QEMU_BOOT_MODE: $QEMU_BOOT_MODE" >&2
        echo "Use QEMU_BOOT_MODE=virtio or QEMU_BOOT_MODE=usb." >&2
        exit 1
        ;;
esac
