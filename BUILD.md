# Building the project

* Currently, only linux on x86_64 is supported.
* The recommended linux distro is Ubuntu 24_04.
* The build process uses Bazel via Bazelisk.
* The repository currently pins Bazel via `.bazelversion` to `9.0.0`.

When configuring a VM, have at least 12 GB of RAM and 8 CPU cores available.

### Install Bazelisk

wget https://github.com/bazelbuild/bazelisk/releases/download/v1.27.0/bazelisk-linux-amd64

chmod +x bazelisk-linux-amd64

sudo mv bazelisk-linux-amd64 /usr/local/bin/bazel

**check bazelisk is installed**

which bazel
bazel --version

### Install system dependencies

* git
* clang-18
* build-essential
* openjdk-25-jdk
* bubblewrap
* rsync
* libgmp-dev 
* liblz4-dev 
* libzstd-dev 
* pkg-config
* libev-dev 
* libssl-dev
* musl-tools
* musl cross-linkers for netprobe static builds:
  * `x86_64-linux-musl-gcc`
  * `aarch64-linux-musl-gcc`

`
sudo apt install -y git clang-18 build-essential openjdk-25-jdk bubblewrap rsync libgmp-dev liblz4-dev libzstd-dev pkg-config libev-dev libssl-dev musl-tools
`

### Clone the project

git clone https://github.com/carverauto/serviceradar.git


### Build the project 

`
bazel build //... 
`

## Netprobe eBPF BTF header

`rust/netprobe/ebpf/include/vmlinux.h` is vendored for BTF CO-RE builds from
the earliest supported netprobe eBPF kernel floor: Ubuntu 20.04
`5.8.0-23-generic` x86_64.

Source:

* Repository: `https://github.com/aquasecurity/btfhub-archive`
* Commit: `10b72a6c436c20f9e8281ea995c7240e6246cb2a`
* Archive path: `ubuntu/20.04/x86_64/5.8.0-23-generic.btf.tar.xz`
* Archive SHA256:
  `2facb2cff7906dbd27991e05a661e6d0e8ac90e4e412e33cd2634c3a4fae8734`
* Generated `vmlinux.h` SHA256:
  `54f22b5fa97c0bde74315d62a1f216d80a43646bc20996d88fc6eb7be270a73a`

Regenerate it from a Linux host with `bpftool`:

```bash
tmpdir=$(mktemp -d)
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/aquasecurity/btfhub-archive.git "$tmpdir/btfhub-archive"
cd "$tmpdir/btfhub-archive"
git sparse-checkout set --no-cone \
  /ubuntu/20.04/x86_64/5.8.0-23-generic.btf.tar.xz
tar -xf ubuntu/20.04/x86_64/5.8.0-23-generic.btf.tar.xz
bpftool btf dump file 5.8.0-23-generic.btf format c \
  > /path/to/serviceradar/rust/netprobe/ebpf/include/vmlinux.h
sha256sum /path/to/serviceradar/rust/netprobe/ebpf/include/vmlinux.h
```

## Netprobe fingerprint corpus maintenance

The license-clean fingerprint stack uses:

* Frozen upstream p0f signatures in `rust/netprobe/p0f-corpus/p0f.fp`.
* ServiceRadar-curated p0f additions in
  `rust/netprobe/p0f-corpus/serviceradar-additions.fp`.
* JA4 base TLS ClientHello fingerprinting pinned by `rust/netprobe/LICENSE-JA4`
  and the `JA4_BASE_SPEC_REVISION` constant.

### Regenerate the upstream p0f corpus

Only refresh `p0f.fp` when deliberately bumping the upstream corpus. Keep the
file separate and preserve the upstream LGPL notice.

```bash
tmpdir=$(mktemp -d)
curl -L https://lcamtuf.coredump.cx/p0f3/releases/p0f-3.09b.tgz \
  -o "$tmpdir/p0f-3.09b.tgz"
sha256sum "$tmpdir/p0f-3.09b.tgz"
tar -C "$tmpdir" -xzf "$tmpdir/p0f-3.09b.tgz"
cp "$tmpdir/p0f-3.09b/p0f.fp" rust/netprobe/p0f-corpus/p0f.fp
sha256sum rust/netprobe/p0f-corpus/p0f.fp
```

After changing the corpus:

1. Update `rust/netprobe/p0f-corpus/README.md` with the source URL, timestamp,
   tarball hash, corpus hash, and license notes.
2. Update `P0F_CORPUS_REVISION` in `rust/netprobe/src/fingerprint.rs`.
3. Run:

```bash
sfw cargo test -p serviceradar-netprobe --no-default-features --offline p0f
bazel test //rust/netprobe:netprobe_test
```

### Curate ServiceRadar additions

Do not patch the upstream corpus for local signatures. Add ServiceRadar-owned
entries to `rust/netprobe/p0f-corpus/serviceradar-additions.fp` following
`rust/netprobe/p0f-corpus/CONTRIBUTING.md`.

Before merge:

```bash
make lint-p0f-additions
```

When the additions file changes, update `SERVICERADAR_ADDITIONS_REVISION` in
`rust/netprobe/src/fingerprint.rs` so agent status reports the exact corpus
revision that produced a fingerprint.

### Bump the JA4 base spec revision

JA4 base is the only FoxIO JA4-family algorithm implemented in netprobe. To
bump it:

1. Review the upstream JA4 base license at
   `https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE-JA4`.
2. Confirm the broader JA4+ license at
   `https://github.com/FoxIO-LLC/ja4/blob/main/LICENSE` still does not apply to
   the base JA4 ClientHello algorithm we ship.
3. Update `rust/netprobe/LICENSE-JA4` and the local JA4 reference vectors.
4. Update `JA4_BASE_SPEC_REVISION` in `rust/netprobe/src/fingerprint.rs`.
5. Run the netprobe JA4 tests and `openspec validate
   add-host-network-visibility-sidecar --strict`.
