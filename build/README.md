# Build Notes

This directory describes the FreeBSD image build.

The repo can live anywhere, including Linux. The actual release media build
should run on FreeBSD.

## Step 1: Fetch FreeBSD Source

On the FreeBSD builder:

```sh
cd /path/to/TritonBSD
./build/fetch-freebsd-src.sh
```

This clones the branch configured in `build/triton.env`:

```sh
TRITON_FREEBSD_SRC_BRANCH="releng/15.1"
```

That is the FreeBSD 15.1 release engineering branch. It gives Triton a stable
production base instead of tracking unstable FreeBSD-CURRENT.

## Step 2: Build Stock FreeBSD Media

After source exists:

```sh
./build/build-release.sh
```

This calls FreeBSD's own:

```sh
/bin/sh release/release.sh -c build/triton-release.conf
```

The initial goal is to produce a normal FreeBSD amd64 release image first. Once
that is working, the next script will mount the image and apply
`build/overlay`.

## Step 3: Apply Triton Overlay

The overlay currently contains:

```text
/usr/local/bin/triton-install
/usr/local/etc/pkg/repos/FreeBSD.conf
/usr/local/share/triton/pkglist
```

Next we need to add:

```text
live user setup
desktop skeleton
autologin or graphical startup
post-install scripts
```

## Latest FreeBSD vs Latest Packages

These are different:

- FreeBSD base: use the latest production release branch, currently
  `releng/15.1`.
- Third-party packages: use the official FreeBSD `latest` pkg repository.

Do not use FreeBSD `main` for TritonBSD unless you intentionally want an
unstable CURRENT-based image.

