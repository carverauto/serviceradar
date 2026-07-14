# pcap

This is a **Rust language** crate for accessing the packet sniffing capabilities of libpcap (or Npcap on Windows). If you need anything, feel free to post an issue or submit a pull request!

[![Linux](https://github.com/rust-pcap/pcap/actions/workflows/00-linux.yml/badge.svg)](https://github.com/rust-pcap/pcap/actions/workflows/00-linux.yml)
[![Mac OS](https://github.com/rust-pcap/pcap/actions/workflows/00-macos.yml/badge.svg)](https://github.com/rust-pcap/pcap/actions/workflows/00-macos.yml)
[![Windows](https://github.com/rust-pcap/pcap/actions/workflows/00-windows.yml/badge.svg)](https://github.com/rust-pcap/pcap/actions/workflows/00-windows.yml)
[![Coverage](https://rust-pcap.github.io/pcap/badges/flat.svg)](https://rust-pcap.github.io/pcap/index.html)
[![Crates.io](https://img.shields.io/crates/v/pcap.svg)](https://crates.io/crates/pcap)
[![Docs.rs](https://docs.rs/pcap/badge.svg)](https://docs.rs/pcap)

## Features:

* List devices
* Open capture handle on a device or savefiles
* Get packets from the capture handle
* Filter packets using BPF programs
* List/set/get datalink link types
* Configure some parameters like promiscuity and buffer length
* Write packets to savefiles
* Inject packets into an interface

See [examples](examples) for usage.

# Building

This crate requires the libpcap (or Npcap on Windows) library.

## Installing dependencies

### Windows

1. Install [Npcap](https://npcap.com/#download).
2. Download the [Npcap SDK](https://npcap.com/#download).
3. Add the SDK's `/Lib` or `/Lib/x64` folder to your `LIB` environment variable.

### Linux

Install the libraries and header files for the libpcap library. For example:

- On Debian based Linux: install `libpcap-dev`.
- On Fedora Linux: install `libpcap-devel`.

**Note:** If not running as root, you need to set capabilities like so: `sudo setcap cap_net_raw,cap_net_admin=eip path/to/bin`.

### Mac OS X

`libpcap` should be installed on Mac OS X by default.

**Note:** A timeout of zero may cause ```pcap::Capture::next``` to hang and never return (because it waits for the timeout to expire before returning). This can be fixed by using a non-zero timeout (as the libpcap manual recommends) and calling ```pcap::Capture::next``` in a loop.

## Linking

It is your responsibility, as the crate user, to configure linking with libpcap/wpcap to suit your needs (e.g. library version, static vs. dynamic linking, etc.) via your own [build script](https://doc.rust-lang.org/cargo/reference/build-scripts.html). For most setups, the defaults are most likely sufficient and you don't have to do anything special beyond installing libpcap as described above. The notes below are provided if the defaults are not suitable.

### Supporting different library versions

This crate supports several different versions of libpcap, such as wpcap, to ensure it can be compiled against older versions while still providing access to functionality available in newer versions. The build script will try to automatically detect the right version and configure pcap, but it may fail at this task. Especially, if you have an unusual build setup. If you are getting compilation error of the form
``` text
cannot find function `pcap_<some_function>` in module `raw`
```
then that is probably what is happening. It is likely that your libpcap does not support the newest libpcap API and pcap failed to query libpcap to find out which unsupported features it should exclude.

To solve this, you can try helping the pcap crate compile the correct feature set that is compatible with your libpcap using the following two approaches:

#### Library Location

If you are linking dynamically with libpcap, pcap will try to consult libpcap for its version. However, if your library is in an unconventional location and you had to customize `cargo:rustc-link-search=native` in your own build script, pcap's build script is unable to pick up on that and will default to the most recent API version. If you are not using the most recent library version, please communicate the library's location to pcap's build script using the `LIBPCAP_LIBDIR` environment variable.

If `LIBPCAP_LIBDIR` is unset, the build will attempt to find the library via `pkg-config` instead. On most setups, this is the easiest way to get things working and may even eliminate the need for any custom build scripts in your software.

#### Library Version

If setting the library location does not work or you are linking statically, you may need to set the libpcap version manually. You can do this by setting the environment variable `LIBPCAP_VER` to the desired version (e.g. `env LIBPCAP_VER=1.5.0`). By default, if pcap fails to query libpcap/wpcap for its API version, it will assume the newest API so this should only be necessary if you are using an old version of libpcap.

Note that `LIBPCAP_VER` is respected even if you haven't set `LIBPCAP_LIBDIR` and are using `pkg-config`. If it is unset, we'll find whatever available version as long as it's supported by the library.

## Optional Features

### `capture-stream`

Use the `capture-stream` feature to enable support for streamed packet captures.

```toml
[dependencies]
pcap = { version = "2", features = ["capture-stream"] }
```

## Unstable Features

Use at your own risk, we do not consider this our public API yet.

### `lending-iter`

Use the `lending-iter` feature to enable the lending packet iterator. See `lendingiterprint` example.

## Minimum Supported Rust Version (MSRV)

This crate uses Rust 2021 and requires a compiler version >= 1.64.

The feature `capture-stream` depends on `tokio = "1.0"`. Therefore, when `capture-stream` is enabled, this crate requires a compiler version new enough to compile the `tokio` crate.

Some dependencies no longer support our chosen MSRV. Since many crates do not consider this a breaking change there is not much that can be done to prevent this through semver requirements. However, users can protect themselves against such incompatibility with `Cargo.lock` file. We provide [`msrv.lock`](msrv.lock) which is the lockfile against which we test MSRV builds in our CI.

[Discuss the MSRV](https://github.com/rust-pcap/pcap/discussions/240).

# Documentation labels

Generating documentation with `cfg` labels requires a nightly toolchain.  To
use this feature set the environment variables:

```
RUSTFLAGS="--cfg docsrs"
RUSTDOCFLAGS="--cfg docsrs"
```

Then generate the documentation using `cargo +nightly doc --all-features`.

# License

Licensed under either of

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

# Contributing

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
