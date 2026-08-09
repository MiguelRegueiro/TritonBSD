# Triton Live Notes

This live image is a FreeBSD base system with the Triton overlay applied.

On the live desktop image, run:

```sh
triton-install
```

The current Rust installer is a non-destructive installer prototype. It discovers disks,
blocks live or mounted media, collects installation choices, and validates an
exact target snapshot. It cannot partition, format, mount, or install yet.

