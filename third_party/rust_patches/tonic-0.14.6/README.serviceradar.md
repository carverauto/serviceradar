# tonic 0.14.6, patched to zstd 0.14.3

This directory is the published `tonic-0.14.6.crate` from crates.io (checksum
`ac2a5518c70fa84342385732db33fb3f44bc4cc748936eb5833d2df34d6445ef`), with two changes:

- `Cargo.toml`: `[dependencies.zstd] version = "0.13.0"` becomes `"0.14.3"`. This is the
  only change to tonic itself. `Cargo.toml.orig` is left as published.
- The crate's own `Cargo.lock` is removed. Cargo never reads a dependency's lockfile, and
  `scripts/ci/rustsec-audit.sh` audits every tracked `Cargo.lock`, so the published one would
  report the zstd 0.13 advisories this patch exists to remove.

The root `Cargo.toml` still lists this path under `[patch.crates-io]`. `Cargo.lock` records
that entry as `[patch.unused]`: dependents resolve registry `tonic` 0.14.9, and this path
crate is 0.14.6, so it does not replace them. Cargo and Bazel follow that lock, which
vendored `third_party/crate_mirror/tonic-0.14.9.crate`. This 0.14.6 tree stays a path and
has no mirror archive.

## Why

zstd 0.14.3, zstd-safe 8.2.0 and zstd-sys 2.1.2 are the first releases fixed for:

- [RUSTSEC-2026-0391](https://rustsec.org/advisories/RUSTSEC-2026-0391.html) (zstd)
- RUSTSEC-2026-0395 through
  [RUSTSEC-2026-0406](https://rustsec.org/advisories/RUSTSEC-2026-0406.html) (zstd-safe)
- [RUSTSEC-2026-0410](https://rustsec.org/advisories/RUSTSEC-2026-0410.html) (zstd-sys)

No fixed release exists on the zstd 0.13 / zstd-safe 7 line. tonic 0.14.6 required
`zstd ^0.13`. Published tonic 0.14.9 depends on `zstd` 0.14.3, which is the crate
`Cargo.lock` resolves. `rust/addon-sdk` enables tonic's `zstd` feature, and the
OTLP collector (`rust/otel`) accepts zstd-compressed gRPC exports from the network.

tonic only calls `zstd::stream::read::{Encoder, Decoder}::new`, whose signatures are the same
in 0.14, so no tonic source change is needed.

## When to delete it

Delete this directory and the `[patch.crates-io]` entry. tonic 0.14.9 depends on zstd
0.14.3, and `Cargo.lock` already resolves that registry crate. Upstream is
<https://github.com/grpc/grpc-rust> (formerly `hyperium/tonic`). After deleting the unused
patch, refresh the mirror using the platform-specific instructions in
[sync.py](../../crate_mirror/sync.py).
