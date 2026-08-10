# netprobe eBPF vendored crates

The committed Cargo vendor tree (56 crates, ~29M) for
`//rust/netprobe/ebpf:netprobe_ebpf_object`.

It holds both the eBPF crate's own dependencies (`aya-ebpf` and friends) and the
crates `-Z build-std=core` needs to compile `core` from source
(`rustc-literal-escaper`, `libc`, `object`, `hashbrown`, ...).

## Why it is committed

The eBPF object is built hermetically from a pinned nightly Rust toolchain and a
pinned static `bpf-linker`, both supplied by `//third_party/rules_aya_ebpf`
through toolchain resolution, plus this tree. `cargo` runs with
`--offline --locked`, so the build touches no system
toolchain and no network. That is what makes it correct under Bazel remote
execution, where neither exists. Pins and rationale:
`openspec/changes/add-hermetic-netprobe-ebpf-build/`.

## Regenerating

Re-vendoring is coupled to the nightly pin in `//third_party/rules_aya_ebpf`:
`-Z build-std` resolves the whole sysroot, so the std workspace's own crates.io
dependencies are vendored here too and move whenever the nightly moves. Bump the
pin and regenerate in the same commit.

Two things the obvious command gets wrong:

- **The crate must be vendored in isolation.** It is not a member of the root
  Cargo workspace and has no `[workspace]` table of its own — the `ebpf_object`
  rule appends one to its staged copy at build time. Run `cargo vendor` from the
  crate directory as-is and it fails with "current package believes it's in a
  workspace when it's not". Stage it the same way the rule does.
- **`cargo vendor` manages its destination**, so pointing it straight at this
  directory deletes `BUILD.bazel` and this README. Vendor elsewhere and swap.

```sh
stage=$(mktemp -d)
cp -R rust/netprobe/ebpf/. "$stage/"
rm -f "$stage/BUILD.bazel"
printf '\n[workspace]\n' >> "$stage/Cargo.toml"

out=$(mktemp -d)
src="$(rustc +nightly-<DATE> --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
(cd "$stage" && cargo +nightly-<DATE> vendor --sync "$src" "$out")

v=third_party/netprobe_ebpf_vendor
find "$v" -mindepth 1 -maxdepth 1 -not -name BUILD.bazel -not -name README.md -exec rm -rf {} +
cp -R "$out/." "$v/"
```

Expect a large diff for a small change: `cargo vendor` names a crate directory
without its version when only one version is in the graph, so a crate that moved
version shows up as hundreds of modified files rather than an add plus a delete.

`cargo vendor` prints a `[source]` replacement stanza; ignore it. The
`ebpf_object` rule writes that stanza itself, with an absolute path to this
directory, into the staged workspace at build time. Nothing on disk needs a
`.cargo/config.toml`.

Each crate carries a `.cargo-checksum.json` that `cargo` verifies file by file.
`//.gitattributes` marks this tree `-text` so Git line-ending normalization
cannot silently invalidate those checksums.
