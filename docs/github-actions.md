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

