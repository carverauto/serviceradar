# Bazel distdir

Place pre-downloaded archives here to avoid repeated downloads during Bazel
repository fetches. Bazel will reuse files that match the archive basename.

Bazel matches by the URL's basename and still verifies the `sha256` from the
`http_archive`, so a stale or wrong file here is rejected rather than trusted.

The contents are gitignored (`.gitignore`: `third_party/distdir/*`) -- this is a cache, not
vendored source. CI restores it through the `actions/cache` entry that lists
`third_party/distdir`, so a warm runner does not re-download either.

Examples (current tooling):
- v1.19.4.tar.gz (Elixir)
- otp_src_28.1.tar.gz (Erlang/OTP)
- bpf-linker-x86_64-unknown-linux-musl.tar.gz (aya-rs bpf-linker v0.10.3, used by
  //rust/netprobe/ebpf). Worth having locally: it is **229 MB** because it statically links
  LLVM, and it is the single largest external fetch in the build. Populate with:

      curl -fsSL -o third_party/distdir/bpf-linker-x86_64-unknown-linux-musl.tar.gz \
        https://github.com/aya-rs/bpf-linker/releases/download/v0.10.3/bpf-linker-x86_64-unknown-linux-musl.tar.gz

  Note there is no upstream mirror for it: `mirror.bazel.build` 404s, since that only
  carries artifacts Google explicitly mirrors (mostly `bazelbuild/*`).
