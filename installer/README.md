# Triton installer

`triton-install` is currently a non-destructive installer prototype. The Rust
frontend owns the terminal while a fixed-verb POSIX shell bridge handles state,
read-only disk discovery, target snapshots, and plan validation.

It contains no partitioning, formatting, mounting, privilege-escalation, account
mutation, package-installation, or reboot backend.

## Layout

- `src/`: Ratatui/Crossterm frontend, terminal lifecycle, and bridge client.
- `lib/`: validated state, disk discovery, and plan model.
- `libexec/triton/triton-model-bridge`: allowlisted frontend/model boundary.
- `fixtures/`: FreeBSD GEOM, mount, swap, and identity scenarios.
- `tests/`: model, discovery, bridge, plan, and static safety tests.
- `triton-install`: source-tree launcher and installed `/usr/local/bin/triton-install` entry point.

## Checks

```sh
cargo fmt --check --manifest-path installer/Cargo.toml
cargo clippy --locked --all-targets --manifest-path installer/Cargo.toml -- -D warnings
cargo test --locked --manifest-path installer/Cargo.toml
installer/tests/run.sh
```

Build the FreeBSD 15.1 amd64 artifact from Linux or FreeBSD:

```sh
build/build-installer.sh
build/test-installer-layout.sh
```

The output is `installer/dist/triton-installer-ui`. Image builds stage it with
`build/install-installer.sh` and expose the product command as
`/usr/local/bin/triton-install`.
