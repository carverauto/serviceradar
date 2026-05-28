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
