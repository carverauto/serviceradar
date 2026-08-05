# netprobe fingerprint corpora

Vendored, separately-licensed fingerprint databases consumed by
`//rust/netprobe`. Each is a replaceable data corpus pinned to an upstream
release, with its own README recording source URL, commit/tag, checksums and
license.

| Corpus | Upstream | License | Consumed by |
| --- | --- | --- | --- |
| `p0f` | p0f-3.09b (frozen 2014) | LGPL-2.1 | `build.rs` at build time, plus `include_str!` in `src/p0f_matcher.rs` |
| `recog` | rapid7/recog v3.1.25 | BSD-2-Clause | `build.rs`, which walks `recog/xml/` and generates match tables |
| `satori` | xnih/satori, pinned commit | **GPL-2.0** | Loaded at **runtime** from a directory — never embedded |
| `muonfp` | sundruid/muonfp, pinned commit | MIT | Nothing — a format/reference audit only, not an embedded database |

ServiceRadar-authored signatures go in the `serviceradar-*` files alongside the
frozen upstream data, never into the upstream file itself. See each corpus's
`CONTRIBUTING.md`.

## The Satori boundary is load-bearing

The Satori XML is GPLv2 and is redistributable here only as *replaceable data*.
`scripts/check-netprobe-fingerprint-licenses.sh` enforces two things about it:
`satori/` may contain nothing but XML, a license and a readme (so no BUILD file
goes in there — see this package's `BUILD.bazel`), and no source file may reach
it with `include_str!`/`include_bytes!`. Keep both invariants.

Every other corpus is embeddable; only Satori is not.

## Path coupling

`rust/netprobe/build.rs` resolves each corpus by trying the cargo-relative path
(cwd = the crate dir) and falling back to the Bazel one (cwd = execroot), so
both paths must be updated together when anything here moves. The
`include_str!` sites resolve relative to the *source file*, which is a third
spelling of the same path. `//rust/netprobe:BUILD.bazel` lists the files in both
`data` (for the build script) and `compile_data` (for `include_str!`).
