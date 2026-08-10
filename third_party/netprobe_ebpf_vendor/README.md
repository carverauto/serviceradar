# netprobe eBPF vendored crates

The committed Cargo vendor tree (56 crates, ~29M) for
`//rust/netprobe/ebpf:netprobe_ebpf_object`.

It holds both the eBPF crate's own dependencies (`aya-ebpf` and friends) and the
crates `-Z build-std=core` needs to compile `core` from source
(`rustc-literal-escaper`, `libc`, `object`, `hashbrown`, ...).

## Why it is committed

The eBPF object is built hermetically: a pinned nightly Rust toolchain from
`MODULE.bazel` (`@netprobe_ebpf_*`), a pinned static `bpf-linker`, and this
tree. `cargo` runs with `--offline --locked`, so the build touches no system
toolchain and no network. That is what makes it correct under Bazel remote
execution, where neither exists. Pins and rationale:
`openspec/changes/add-hermetic-netprobe-ebpf-build/`.

## Regenerating

From `rust/netprobe/ebpf/`, with the pinned nightly's `rust-src` component
available:

```
cargo vendor --sync <nightly-rust-src>/library/Cargo.toml \
  ../../../third_party/netprobe_ebpf_vendor
```

`cargo vendor` prints a `[source]` replacement stanza; ignore it. The
`ebpf_object` rule writes that stanza itself, with an absolute path to this
directory, into the staged workspace at build time. Nothing on disk needs a
`.cargo/config.toml`.

Each crate carries a `.cargo-checksum.json` that `cargo` verifies file by file.
`//.gitattributes` marks this tree `-text` so Git line-ending normalization
cannot silently invalidate those checksums.
