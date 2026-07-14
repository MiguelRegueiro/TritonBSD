# TritonBSD

TritonBSD is a FreeBSD desktop remix: stock FreeBSD under the hood, plus a
Triton live environment, installer wrapper, and Hyprland + QuickShell desktop
setup.

As of 2026-07-14, the base target is FreeBSD 15.1-RELEASE from the
`releng/15.1` source branch.

## How It Works

The build has four layers:

1. Fetch the FreeBSD source branch for the selected production release.
2. Use FreeBSD's release tools to build standard install media.
3. Apply the Triton overlay to the image.
4. Boot into the Triton live desktop and run `triton-install`.

The first implementation should target:

- amd64
- FreeBSD 15.1-RELEASE
- official FreeBSD `latest` package branch
- live Hyprland + QuickShell session
- installer MVP with UEFI + GPT + UFS first
- ZFS after the UFS installer path is proven

Read [docs/how-it-works.md](docs/how-it-works.md) before writing installer code.

GitHub Actions notes live in [docs/github-actions.md](docs/github-actions.md).
