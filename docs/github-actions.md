# GitHub Actions Builds

GitHub Actions does not provide native FreeBSD hosted runners. The live-image
workflow uses `vmactions/freebsd-vm` to boot FreeBSD under an Ubuntu runner.

## Workflows

`CI`

Runs formatting, Clippy, Rust tests, installer model tests, safety checks, and
shell syntax checks on pull requests and pushes to `main`. Pull requests stop
after those fast checks. Pushes to `main` also cross-build the FreeBSD installer
and upload it as a commit-specific artifact.

`Build Live Desktop Image`

Manually triggered. It requires the verified installer artifact produced by CI
for the same commit, then boots a FreeBSD VM and builds the TritonBSD live desktop
memstick. This is the only supported image workflow.

The image workflow is intentionally manual because installing the desktop and
building the compressed image is slow. Ordinary pull requests never build an
image or start a FreeBSD VM.

## Installer Artifact Handoff

CI uploads:

```text
triton-installer-freebsd-amd64-<commit SHA>
```

The live-image workflow accepts only a successful `main` push artifact for the
exact commit being built. This prevents a stale installer binary from entering
the image.

The image workflow uploads:

```text
TritonBSD-15.1-RELEASE-amd64-live-memstick.img.xz
```

## Download And Test An Artifact

Use the helper script instead of downloading artifacts from the browser. It uses
resumable parallel `aria2c` downloads when available, with a resumable `curl`
fallback. It verifies the workflow result, artifact size, ZIP and XZ integrity,
prints SHA-256 for both image forms, and decompresses the flashable `.img`. It
never writes to a disk device.

```sh
./scripts/download-live-artifact.sh 29367425435
./scripts/run-bootstrap-qemu.sh artifacts/29367425435/TritonBSD-15.1-RELEASE-amd64-live-memstick.img
```

Or download, decompress, and boot in one command:

```sh
./scripts/download-live-artifact.sh --boot 29367425435
```

With fish:

```fish
set RUN 29367425435
./scripts/download-live-artifact.sh --boot $RUN
```

Hyprland may need 3D acceleration in QEMU. If the image reaches the Triton live
shell but Hyprland exits, retry the same decompressed image with GL enabled:

```fish
set RUN 29367425435
set -x QEMU_GL 1
./scripts/run-bootstrap-qemu.sh artifacts/$RUN/TritonBSD-15.1-RELEASE-amd64-live-memstick.img
set -e QEMU_GL
```

For boot logs in a file:

```fish
set -x QEMU_GL 1
set -x QEMU_SERIAL log
./scripts/run-bootstrap-qemu.sh artifacts/$RUN/TritonBSD-15.1-RELEASE-amd64-live-memstick.img
set -e QEMU_GL
set -e QEMU_SERIAL
tail -f artifacts/qemu-serial.log
```
