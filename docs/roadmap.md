# Roadmap

## Current State

The supported image artifact is the TritonBSD live desktop memstick. The old
bootstrap image and its stock FreeBSD installer path have been retired.

The live-image path provides:

- a `triton` live user and desktop session
- Hyprland, QuickShell, services, firmware, and desktop packages
- patched live-kernel support
- the commit-matched installer prototype

It still requires physical-hardware validation for:

- GPU and Wi-Fi coverage
- reliable graphical startup
- the complete installation path once a destructive backend exists

## Next Milestone: Validate Live Desktop Media

Validate the current live image on supported Intel, AMD, and Radeon hardware:

1. Confirm boot, live-user autologin, and Hyprland startup.
2. Verify GPU firmware, input, networking, audio, and portals.
3. Launch `triton-install` from the desktop and verify read-only hardware probes.
4. Exercise shell fallback and collect useful diagnostics when graphical startup
   fails.
5. Keep the installation backend separate until disk-safety behavior is proven.

## Risk

The official memstick root filesystem is small. Installing Hyprland, QuickShell,
Qt, fonts, GPU firmware, and portals may exceed the existing image size.

If that happens, the next build step must switch from remixing the official
memstick to building a larger release image with FreeBSD's release tooling or a
GhostBSD-style live root image.

## Workflow

`Build Live Desktop Image` remains manual because image construction is large and
slow. Regular CI builds and verifies the installer artifact without building an
image.

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
