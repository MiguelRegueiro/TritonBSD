# How TritonBSD Builds

TritonBSD should not fork FreeBSD. It should build from a selected FreeBSD
release branch, then add Triton desktop and installer files on top.

## Base System

FreeBSD publishes release source branches named like `releng/15.1`. Triton pins
one branch at a time in `build/triton.env`.

For the first build:

```sh
TRITON_FREEBSD_VERSION=15.1
TRITON_FREEBSD_RELEASE=15.1-RELEASE
TRITON_FREEBSD_SRC_BRANCH=releng/15.1
```

That source tree contains FreeBSD's release tooling under `release/`. The core
builder is:

```sh
/bin/sh release/release.sh -c /path/to/triton-release.conf
```

Run this on FreeBSD, not Linux. Linux can hold the repo and scripts, but the
real release build should happen on a FreeBSD 15.1 builder or VM.

Do not confuse the latest production release with FreeBSD-CURRENT. For Triton,
the base should be the latest production release branch, not `main`, unless the
goal is explicitly to build an unstable CURRENT image.

## Package Branch

FreeBSD release builds default toward conservative package choices. Triton wants
desktop packages from the `latest` branch, so the live image and installed
system get this repo override:

```conf
FreeBSD-ports: {
  url: "pkg+https://pkg.FreeBSD.org/${ABI}/latest"
}
```

This keeps the OS base pure FreeBSD while making Hyprland, QuickShell, portals,
and desktop apps track newer package builds.

## Image Flow

The intended pipeline is:

```text
FreeBSD src branch
  -> release.sh
  -> create installed-style live root
  -> install Triton desktop packages/config into live root
  -> add live boot glue and installer launcher
  -> produce TritonBSD ISO/memstick image
```

There are two possible implementation paths:

1. Source-build path: build the FreeBSD base from `releng/15.1`, then assemble a
   Triton live root and boot image. This is the clean, reproducible path.
2. Remix path: fetch the official FreeBSD memstick image, verify checksums,
   mount it, inject Triton files, and repack. This is faster for early testing,
   but it still follows the stock installer boot path and is not enough for the
   real live desktop.

Start with the source-build path unless iteration speed becomes a blocker.

The Triton overlay contains things that must exist before install:

```text
/usr/local/bin/triton-install
/usr/local/etc/pkg/repos/FreeBSD.conf
/usr/local/share/triton/pkglist
/usr/local/share/triton/skel
```

The live session must not depend on `/root/.profile`. The current implementation
uses the simpler TrueOS/GhostBSD-style handoff:

```text
/etc/rc.local
  -> starts required live services
  -> starts /usr/local/sbin/triton-live-start on ttyv0
/etc/gettytab + /etc/ttys
  -> fallback autologin triton on ttyv0
/home/triton/.profile
  -> fallback exec /usr/local/sbin/triton-live-start
/usr/local/sbin/triton-live-start
  -> run /home/triton/.start-hyprland
```

That should auto-login to a temporary `triton` user and start:

```sh
dbus-run-session Hyprland
```

The installed system should create the real user, copy the Triton skeleton into
that user's home directory, enable required services, and install packages from
the same pkg list.

## Installer Flow

Do not hand-roll disk installation first. Use FreeBSD tools underneath:

```text
triton-install
  -> select target disk
  -> select filesystem mode
  -> call bsdinstall partition/extract/boot steps
  -> chroot post-install
```

MVP order:

1. UEFI + GPT + UFS + swap.
2. User creation and Triton desktop copy.
3. Boot into installed Hyprland session.
4. Add ZFS.
5. Add a nicer UI.
6. Add broad hardware detection.

## What Must Be Tested

Each image needs these tests before trusting it:

- boots in a VM
- boots on target laptop
- live Hyprland starts
- Wi-Fi or wired network works enough for packages
- `triton-install` sees disks correctly
- installer refuses to continue without destructive confirmation
- installed system boots
- user can log in and start Triton desktop
- `pkg update` uses `latest`
