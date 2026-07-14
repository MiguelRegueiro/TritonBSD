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

## Next Milestone: Live Desktop Bootstrap

The next image should still be based on official FreeBSD media, but it should
boot to a `triton` live user and start Hyprland.

Required pieces:

1. Install or stage desktop packages into the live root.
2. Create a `triton` live user in the image.
3. Copy the desktop skeleton into `/home/triton`.
4. Enable required services in the image.
5. Configure the live boot path to start the Triton session instead of dropping
   straight into the stock installer.

## Risk

The official memstick root filesystem is small. Installing Hyprland, QuickShell,
Qt, fonts, GPU firmware, and portals may exceed the existing image size.

If that happens, the next build step must grow the image and filesystem before
installing packages, or switch from remixing the official memstick to building a
larger release image with FreeBSD's release tooling.

