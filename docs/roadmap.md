# Roadmap

## Current State

The current GitHub Actions artifact is a bootstrap image. It is intentionally
still the normal FreeBSD installer UI with a small Triton overlay injected.

It proves:

- GitHub Actions can run a FreeBSD VM.
- The workflow can download and verify official FreeBSD media.
- The workflow can mount the memstick root filesystem.
- Triton files can be injected into the image.

It does not yet prove:

- live graphical desktop boot
- Hyprland package availability inside the image
- auto-login
- installer UI
- post-install desktop setup

A later live-image experiment proved that packages and a live user can be added
to the remixed memstick, but it still booted into the stock installer. See
`docs/live-media-research.md` for the source-study notes from GhostBSD and
TrueOS.

## Next Milestone: Real Live Desktop Media

The next image should stop depending on the stock FreeBSD installer startup path.
It should build a real live root, then boot to a `triton` live user and start
Hyprland.

Required pieces:

1. Create an installed-style FreeBSD root filesystem tree.
2. Install or stage desktop packages into that live root.
3. Create a `triton` live user in the image.
4. Copy the desktop skeleton into `/home/triton`.
5. Enable required services in the image.
6. Configure `/etc/rc.local`, `gettytab`, and `ttys` so the live boot path starts
   the Triton session instead of the stock installer.
7. Keep `triton-install` as an application launched from inside the live
   desktop.

## Risk

The official memstick root filesystem is small. Installing Hyprland, QuickShell,
Qt, fonts, GPU firmware, and portals may exceed the existing image size.

If that happens, the next build step must switch from remixing the official
memstick to building a larger release image with FreeBSD's release tooling or a
GhostBSD-style live root image.

## Workflow

The next test workflow is `Build Live Desktop Image`. It is manual because it is
larger and slower than the bootstrap build.

It sets:

```text
TRITON_WITH_LIVE_DESKTOP=1
TRITON_IMAGE_FLAVOR=live
TRITON_IMAGE_SIZE=12G
```

Expected first artifact:

```text
TritonBSD-15.1-RELEASE-amd64-live-memstick.img.xz
```

Expected boot path:

```text
FreeBSD boot loader
  -> rc.local starts dbus/seatd and does not run bsdinstall
  -> ttyv0 autologins as triton
  -> /usr/local/sbin/triton-live-start starts Hyprland
```
