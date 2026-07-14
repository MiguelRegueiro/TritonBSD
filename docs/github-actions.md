# GitHub Actions Builds

GitHub Actions does not provide native FreeBSD hosted runners. The workflows in
this repo use `vmactions/freebsd-vm`, which boots a FreeBSD VM under an Ubuntu
runner.

## Workflows

`FreeBSD Check`

Runs shell syntax checks inside a FreeBSD 15.1 VM.

`Build Bootstrap Image`

Manually triggered. It downloads the official FreeBSD 15.1 memstick image,
verifies the SHA512 checksum, mounts it with FreeBSD tools, injects the Triton
overlay, compresses the result, and uploads it as a workflow artifact.

The artifact is a `.img.xz` memstick image, not a final desktop ISO yet.
It still shows the normal FreeBSD installer. That is expected for the bootstrap
stage.

## Why Bootstrap First

Standard GitHub-hosted runners have limited disk space. A full FreeBSD
`release.sh` source build is likely too large and slow for the free/default
runner. The bootstrap image proves the CI path and gives us something bootable
to test before we invest in the full live desktop image.

## Expected First Artifact

```text
TritonBSD-15.1-RELEASE-amd64-bootstrap-memstick.img.xz
```

This should boot like FreeBSD's normal memstick image, but with:

```text
/usr/local/bin/triton-install
/usr/local/etc/pkg/repos/FreeBSD.conf
/usr/local/share/triton/pkglist
/usr/local/share/triton/docs
```

It will not yet boot straight into Hyprland. That comes after we add desktop
package installation into the live root and configure live-user startup.

## Download And Test An Artifact

Use the helper script instead of downloading artifacts from the browser. It uses
the GitHub API plus `curl --progress-bar`, then extracts and decompresses the
image with verbose `xz` output.

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
QEMU_GL=1 ./scripts/run-bootstrap-qemu.sh artifacts/$RUN/TritonBSD-15.1-RELEASE-amd64-live-memstick.img
```

For boot logs in a file:

```fish
QEMU_GL=1 QEMU_SERIAL=log ./scripts/run-bootstrap-qemu.sh artifacts/$RUN/TritonBSD-15.1-RELEASE-amd64-live-memstick.img
tail -f artifacts/qemu-serial.log
```

## Full Image Later

For the real TritonBSD image, use one of these:

1. A self-hosted FreeBSD runner with enough disk.
2. A paid/larger GitHub runner.
3. A separate FreeBSD build server.

Then run the source-build path:

```sh
./build/fetch-freebsd-src.sh
./build/build-release.sh
```
