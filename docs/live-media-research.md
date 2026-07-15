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
2. Use a TrueOS-style handoff for the next test image:
   - replace the stock installer `/etc/rc.local`
   - start live services there
   - start the Triton live desktop directly on `ttyv0`
   - keep `gettytab` and `ttys` autologin as a fallback path
3. Replace the live workflow internals with a new live image path:
   - create a FreeBSD root filesystem tree
   - install FreeBSD base plus packages into that root
   - add Triton desktop config, live user, services, and `triton-install`
   - build boot media around that root
4. Once the live desktop starts reliably, replace the installer placeholder with
   a real `triton-install` frontend that drives FreeBSD install primitives.

Longer term, the GhostBSD ZFS-in-RAM model is the cleaner live experience, but
it requires more memory and more build plumbing. A smaller first Triton version
can use an installed-style UFS root or a writable overlay, then move to the
GhostBSD model once the desktop and installer are proven.

## Hyprland Live Session Notes

The FreeBSD Handbook's Wayland chapter says `seatd` must be enabled and running
before starting the compositor because it brokers non-root access to shared
devices, including graphics devices. It also calls out `XDG_RUNTIME_DIR` as a
runtime directory that must be writable and suitable for Wayland clients.

The live image preflights DRM/KMS before launching Hyprland. During rc startup it
tries the packaged native laptop/desktop kernel modules (`i915kms`, `amdgpu`,
`radeonkms`) and waits briefly for `/dev/dri/card*`. If no DRM device appears,
it leaves a clean diagnostic in `/tmp/triton-live.log` and drops to the live
shell instead of showing Aquamarine backend noise.

The QEMU helper is currently useful for boot and shell-flow testing, not for a
visible Hyprland desktop. FreeBSD's packaged `drm-kmod` set used here does not
include a `virtio_gpu` or `vmwgfx` DRM/KMS driver, so QEMU `virtio-vga` and
`virtio-vga-gl` do not produce `/dev/dri/card*` for Hyprland. Triton uses the
newest packaged DRM branch available to widen real hardware coverage, but desktop
validation still needs physical hardware with a supported Intel/AMD/Radeon GPU,
or a later VM path with a real supported DRM device.

Hyprland's upstream documentation warns that VM usage needs a virtual GPU with
DRM/KMS support. The QEMU helper now uses virtio graphics by default and also
supports:

```sh
QEMU_GL=1 ./scripts/run-bootstrap-qemu.sh path/to/image.img
```

That switches to `virtio-vga-gl` with `gtk,gl=on`, but it is not sufficient for
Hyprland on current FreeBSD packages because no guest DRM/KMS driver binds to it.
In fish, export it first with `set -x QEMU_GL 1`, run the helper, then clear it
with `set -e QEMU_GL`.
