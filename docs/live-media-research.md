# Live Media Research

## Why The Current Image Boots To The Installer

The current TritonBSD live attempt remixes the official FreeBSD memstick image.
That image is built to run the FreeBSD installer. Adding packages, users, and
root shell profile hooks does not change the early boot contract enough: the
installer startup path still owns the boot flow.

That is why the test image reaches the FreeBSD boot loader, then drops into the
normal installer instead of starting Hyprland.

## GhostBSD Pattern

GhostBSD does not treat the stock installer root as the live desktop. Its build
tool creates a separate live system image:

- build a complete installed-style root with packages and desktop config
- snapshot that root with ZFS
- write the snapshot to `cd_root/data/system.img`
- create a small rescue ramdisk with a custom `/init.sh` and `/etc/rc`
- boot the ramdisk, mount the ISO, restore `system.img` into a swap-backed ZFS
  pool, set `vfs.root.mountfrom=zfs:livecd`, and reroot into that pool
- configure console autologin for the live user, then start X from the user's
  shell startup file

Relevant upstream files:

- `ghostbsd/ghostbsd-build:init.sh.in`
- `ghostbsd/ghostbsd-build:rc.in`
- `ghostbsd/ghostbsd-build:common_config/autologin.sh`
- `ghostbsd/ghostbsd-build:build.sh`

The useful lesson is the split between a tiny boot environment and a real live
root. The live desktop starts after reroot, not from the stock installer shell.

## TrueOS / PC-BSD Pattern

TrueOS and older PC-BSD media also avoid relying on a root login profile as the
main boot decision. Their install media wires the installer choice into the boot
system:

- `trueos/build` copies `iso-files/rc.install` into the image as `/etc/rc.local`
  for rc.d systems, or uses a custom `/etc/rc` when OpenRC is present
- `rc.install` presents Install, Live CD, and Shell choices
- the installer backend is `pc-sysinstall`, with GUI and dialog frontends
- older PC-BSD overlays autologin root on `ttyv0` and run `startx` for the
  graphical installer path

Relevant upstream files:

- `trueos/build:iso-files/openrc`
- `trueos/build:iso-files/rc.install`
- `trueos/build:scripts/build.sh`
- `trueos/pc-sysinstall`
- `trueos/pcbsd:overlays/install-overlay`

The useful lesson is that the live/install choice belongs in `/etc/rc` or
`/etc/rc.local`, not in an interactive shell profile that may never run.

## TritonBSD Direction

The next TritonBSD milestone should be a real live media builder, not another
stock memstick hook.

Recommended MVP:

1. Keep `Build Bootstrap Image` only as a smoke test for image mounting.
2. Replace the live workflow internals with a new live image path:
   - create a FreeBSD root filesystem tree
   - install FreeBSD base plus packages into that root
   - add Triton desktop config, live user, services, and `triton-install`
   - build boot media around that root
3. For first success, use a simple rc.d path:
   - mount writable tmpfs for volatile paths
   - autologin `triton` on `ttyv0`
   - run `dbus-run-session Hyprland` from the live user's startup
4. Once the live desktop starts reliably, replace the installer placeholder with
   a real `triton-install` frontend that drives FreeBSD install primitives.

Longer term, the GhostBSD ZFS-in-RAM model is the cleaner live experience, but
it requires more memory and more build plumbing. A smaller first Triton version
can use an installed-style UFS root or a writable overlay, then move to the
GhostBSD model once the desktop and installer are proven.
