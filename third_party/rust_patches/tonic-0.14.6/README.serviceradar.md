# tonic 0.14.6, patched to zstd 0.14.3

This directory is the published `tonic-0.14.6.crate` from crates.io (checksum
`ac2a5518c70fa84342385732db33fb3f44bc4cc748936eb5833d2df34d6445ef`), with two changes:

- `Cargo.toml`: `[dependencies.zstd] version = "0.13.0"` becomes `"0.14.3"`. This is the
  only change to tonic itself. `Cargo.toml.orig` is left as published.
- The crate's own `Cargo.lock` is removed. Cargo never reads a dependency's lockfile, and
  `scripts/ci/rustsec-audit.sh` audits every tracked `Cargo.lock`, so the published one would
  report the zstd 0.13 advisories this patch exists to remove.

The root `Cargo.toml` selects it with `[patch.crates-io]`. rules_rs reads the same `[patch]`
entry and builds this source as `@crates//:tonic`, so Cargo and Bazel compile the same tonic.
As a path dependency, it has no registry checksum in `Cargo.lock` and no archive in
`third_party/crate_mirror`.

## Why

zstd 0.14.3, zstd-safe 8.2.0 and zstd-sys 2.1.2 are the first releases fixed for:

- [RUSTSEC-2026-0391](https://rustsec.org/advisories/RUSTSEC-2026-0391.html) (zstd)
- RUSTSEC-2026-0395 through
  [RUSTSEC-2026-0406](https://rustsec.org/advisories/RUSTSEC-2026-0406.html) (zstd-safe)
- [RUSTSEC-2026-0410](https://rustsec.org/advisories/RUSTSEC-2026-0410.html) (zstd-sys)

No fixed release exists on the zstd 0.13 / zstd-safe 7 line, and tonic 0.14.6, the latest
release, requires `zstd ^0.13`. `rust/addon-sdk` enables tonic's `zstd` feature, and the
OTLP collector (`rust/otel`) accepts zstd-compressed gRPC exports from the network.

tonic only calls `zstd::stream::read::{Encoder, Decoder}::new`, whose signatures are the same
in 0.14, so no tonic source change is needed.

## When to delete it

Delete this directory and the `[patch.crates-io]` entry once tonic publishes a release that
depends on zstd 0.14 or later. Upstream is <https://github.com/grpc/grpc-rust> (formerly
`hyperium/tonic`). Then bump `tonic` in the root `Cargo.toml` if needed, run
`cargo update -p tonic`, and refresh the mirror using the platform-specific instructions
in [sync.py](../../crate_mirror/sync.py).
