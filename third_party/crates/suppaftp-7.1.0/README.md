# SuppaFTP

<p align="center">
  <img src="/assets/images/suppaftp.svg" alt="logo" width="256" height="256" />
</p>
<p align="center">~ A super FTP/FTPS client library for Rust ~</p>
<p align="center">
  <a href="https://docs.rs/suppaftp" target="_blank">Documentation</a>
  ·
  <a href="https://crates.io/crates/suppaftp" target="_blank">Crates.io</a>
</p>

<p align="center">Developed by <a href="https://veeso.me/">veeso</a></p>
<p align="center">Current version: 7.0.7 (05/11/2025)</p>

<p align="center">
  <a href="https://opensource.org/licenses/MIT"
    ><img
      src="https://img.shields.io/crates/l/suppaftp.svg"
      alt="License-Apache-2.0/MIT"
  /></a>
  <a href="https://github.com/veeso/suppaftp/stargazers"
    ><img
      src="https://img.shields.io/github/stars/veeso/suppaftp?style=flat"
      alt="Repo stars"
  /></a>
  <a href="https://crates.io/crates/suppaftp"
    ><img
      src="https://img.shields.io/crates/d/suppaftp.svg"
      alt="Downloads counter"
  /></a>
  <a href="https://crates.io/crates/suppaftp"
    ><img
      src="https://img.shields.io/crates/v/suppaftp.svg"
      alt="Latest version"
  /></a>
  <a href="https://ko-fi.com/veeso">
    <img
      src="https://img.shields.io/badge/donate-ko--fi-red"
      alt="Ko-fi"
  /></a>
  <a href="https://conventionalcommits.org">
    <img
      src="https://img.shields.io/badge/Conventional%20Commits-1.0.0-%23FE5196?logo=conventionalcommits&logoColor=white"
      alt="conventional-commits"
  /></a>
</p>
<p align="center">
  <a href="https://github.com/veeso/suppaftp/actions"
    ><img
      src="https://github.com/veeso/suppaftp/actions/workflows/test.yml/badge.svg"
      alt="Lib-CI"
  /></a>
  <a href="https://github.com/veeso/suppaftp/actions"
    ><img
      src="https://github.com/veeso/suppaftp/workflows/cli-bin/badge.svg"
      alt="Cli-bin-ci"
  /></a>
  <a href="https://coveralls.io/github/veeso/suppaftp"
    ><img
      src="https://coveralls.io/repos/github/veeso/suppaftp/badge.svg"
      alt="Coveralls"
  /></a>
  <a href="https://docs.rs/suppaftp"
    ><img
      src="https://docs.rs/suppaftp/badge.svg"
      alt="Docs"
  /></a>
</p>

---

- [SuppaFTP](#suppaftp)
  - [Introduction 👋](#introduction-)
    - [Main differences between SuppaFTP and rust-ftp 🤔](#main-differences-between-suppaftp-and-rust-ftp-)
  - [Get started 🏁](#get-started-)
    - [Features](#features)
      - [SSL/TLS Support](#ssltls-support)
      - [Async support](#async-support)
      - [Deprecated methods](#deprecated-methods)
      - [Logging](#logging)
    - [Examples 📚](#examples-)
      - [Ftp with TLS (native-tls)](#ftp-with-tls-native-tls)
      - [Ftp with TLS (rustls)](#ftp-with-tls-rustls)
      - [Going Async](#going-async)
  - [Built-in CLI client 🖥️](#built-in-cli-client-️)
  - [Support the developer ☕](#support-the-developer-)
  - [Changelog ⌛](#changelog-)
  - [License 📜](#license-)
    - [Contribution 🤝](#contribution-)

---

## Introduction 👋

SuppaFTP is the main FTP/FTPS client library for Rust, with both support for sync/async programming and for all the FTP protocol features. It is a fork of the original ftp library "[rust-ftp](https://github.com/mattnenterprise/rust-ftp)", but since the original library is currently unmaintained, I decided to keep working on this library by myself. Currently, I consider myself as the only maintainer of this project, indeed I've already added some features to the library and improved it with better error handling and test units.

### Main differences between SuppaFTP and rust-ftp 🤔

- Replaced OpenSSL with **native-tls** or **rustls** as you prefer 🔒
- Added methods to work with streams (e.g. `put_with_stream`) ⬇️
- suppaftp supports **Active mode**
- Added `get_welcome_msg` method 👋
- Supports for both **sync/async** rust 🕙
- Supports for more commands 🌟
  - ABOR
  - APPE
  - REST
  - EPSV
  - EPRT
- Some extra features, such as the **LIST** command output parser
- Implementation of [RFC 2428](https://www.rfc-editor.org/rfc/rfc2428.html)
- Implementationb of [RFC 2389](https://www.rfc-editor.org/rfc/rfc2389)
- Removed deprecated statements ⚰️
- Better error handling 🐛
- Added test units keeping an eye on code coverage 👀

---

## Get started 🏁

To get started, first add **suppaftp** to your dependencies:

```toml
suppaftp = "^7"
```

### Features

These are all the possible features, by family

- **sync FTP**:
  - `native-tls`: enable FTPS support using [native-tls](https://crates.io/crates/native-tls) as backend for TLS
  - `native-tls-vendored`: enable vendored FTPS support using [native-tls](https://crates.io/crates/native-tls)
  - `rustls`: enable FTPS support using [rustls](https://crates.io/crates/rustls) as backend for TLS
- **Async FTP**:
  - **Async-std**:
    - `async-std`: enable async client using [async-std](https://crates.io/crates/async-std) as async backend
    - `async-std-async-native-tls`: enable FTPS support using [async-native-tls](https://crates.io/crates/async-native-tls)
    - `async-std-async-native-tls-vendored`: enable vendored FTPS support using [async-native-tls](https://crates.io/crates/async-native-tls)
    - `async-std-async-rustls`: enable FTPS support using [async-rustls](https://crates.io/crates/async-rustls)
  - **Tokio**:
    - `tokio`: enable async client using [tokio](https://crates.io/crates/tokio) as async backend
    - `tokio-async-native-tls`: enable FTPS support using [async-native-tls](https://crates.io/crates/async-native-tls)
    - `tokio-async-native-tls-vendored`: enable vendored FTPS support using [async-native-tls](https://crates.io/crates/async-native-tls)
    - `tokio-async-rustls`: enable FTPS support using [async-rustls](https://crates.io/crates/async-rustls)
- **Misc**:
  - `deprecated`: enable deprecated FTP/FTPS methods
  - `no-log`: disable logging

In more details:

#### SSL/TLS Support

If you want to enable **support for FTPS**, you must enable the `native-tls` or `rustls` feature in your cargo dependencies, based on the TLS provider you prefer.

```toml
suppaftp = { version = "^7", features = ["native-tls"] }
# or
suppaftp = { version = "^7", features = ["rustls"] }
```

> [!NOTE]
> 💡 If you don't know what to choose, `native-tls` should be preferred for compatibility reasons.  
> ❗ If you want to link libssl statically, enable feature `native-tls-vendored`

#### Async support

If you want to enable **async** support, you must enable either `async-std` feature, to use [async-std](https://crates.io/crates/async-std) or `tokio` feature, to use [tokio](https://crates.io/crates/tokio) as backend, in your cargo dependencies.

```toml
suppaftp = { version = "^7", features = ["tokio"] }
```

> [!CAUTION]
> ⚠️ If you want to enable both **native-tls** and **async-std** you must use the **async-std-async-native-tls** feature ⚠️  
> ⚠️ If you want to enable both **native-tls** and **tokio** you must use the **tokio-async-native-tls** feature ⚠️
> ⚠️ If you want to enable both **rustls** and **async** you must use the **async-rustls** feature ⚠️  
> ❗ If you want to link libssl statically with `async-std`, enable feature `async-std-async-native-tls-vendored`
> ❗ If you want to link libssl statically with `tokio`, enable feature `tokio-async-native-tls-vendored`

#### Deprecated methods

If you want to enable deprecated methods of FTPS, please enable the `deprecated` feature in your cargo dependencies.

This feature enables these methods:

- `connect_secure_implicit()`: used to connect via implicit FTPS

#### Logging

By default, the library will log if there is any `log` crate consumer on the user implementation.
Logging can be if preferred, disabled via the `no-log` feature.

### Examples 📚

```rust
use std::str;
use std::io::Cursor;
use suppaftp::FtpStream;

fn main() {
    // Create a connection to an FTP server and authenticate to it.
    let mut ftp_stream = FtpStream::connect("127.0.0.1:21").unwrap();
    let _ = ftp_stream.login("username", "password").unwrap();

    // Get the current directory that the client will be reading from and writing to.
    println!("Current directory: {}", ftp_stream.pwd().unwrap());

    // Change into a new directory, relative to the one we are currently in.
    let _ = ftp_stream.cwd("test_data").unwrap();

    // Retrieve (GET) a file from the FTP server in the current working directory.
    let data = ftp_stream.retr_as_buffer("ftpext-charter.txt").unwrap();
    println!("Read file with contents\n{}\n", str::from_utf8(&data.into_inner()).unwrap());

    // Store (PUT) a file from the client to the current working directory of the server.
    let mut reader = Cursor::new("Hello from the Rust \"ftp\" crate!".as_bytes());
    let _ = ftp_stream.put_file("greeting.txt", &mut reader);
    println!("Successfully wrote greeting.txt");

    // Terminate the connection to the server.
    let _ = ftp_stream.quit();
}
```

#### Ftp with TLS (native-tls)

```rust
use suppaftp::{NativeTlsFtpStream, NativeTlsConnector};
use suppaftp::native_tls::{TlsConnector, TlsStream};

fn main() {
    let ftp_stream = NativeTlsFtpStream::connect("test.rebex.net:21").unwrap();
    // Switch to the secure mode
    let mut ftp_stream = ftp_stream.into_secure(NativeTlsConnector::from(TlsConnector::new().unwrap()), "test.rebex.net").unwrap();
    ftp_stream.login("demo", "password").unwrap();
    // Do other secret stuff
    assert!(ftp_stream.quit().is_ok());
}
```

#### Ftp with TLS (rustls)

You can also find and run this example in the `suppaftp/examples/` directory (`cargo run --example rustls --features rustls`).

```rust
use std::sync::Arc;
use suppaftp::{RustlsFtpStream, RustlsConnector};
use suppaftp::rustls;
use suppaftp::rustls::ClientConfig;

fn main() {
    let root_store = rustls::RootCertStore::from_iter(
        webpki_roots::TLS_SERVER_ROOTS
            .iter()
            .cloned(),
    );

    let config = ClientConfig::builder()
        .with_root_certificates(root_store)
        .with_no_client_auth();

    // Create a connection to an FTP server and authenticate to it.
    let mut ftp_stream = RustlsFtpStream::connect("test.rebex.net:21")
        .unwrap()
        .into_secure(RustlsConnector::from(Arc::new(config)), "test.rebex.net")
        .unwrap();

    // Terminate the connection to the server.
    let _ = ftp_stream.quit();
}
```

#### Going Async

```rust
use suppaftp::{AsyncNativeTlsFtpStream, AsyncNativeTlsConnector};
use suppaftp::async_native_tls::{TlsConnector, TlsStream};
let ftp_stream = AsyncNativeTlsFtpStream::connect("test.rebex.net:21").await.unwrap();
// Switch to the secure mode
let mut ftp_stream = ftp_stream.into_secure(AsyncNativeTlsConnector::from(TlsConnector::new()), "test.rebex.net").await.unwrap();
ftp_stream.login("demo", "password").await.unwrap();
// Do other secret stuff
assert!(ftp_stream.quit().await.is_ok());
```

## Built-in CLI client 🖥️

SuppaFTP comes also with a built-in command-line FTP client. This CLI application provides all the commands to interact with a remote FTP server and supports FTPS too. You can also use it as a reference to implement your project. You can find it in the `cli/` directory.

You can simply install as any other rust application via **Cargo**:

```sh
cargo install suppaftp-cli
suppaftp --version
```

---

## Support the developer ☕

If you like **SuppaFTP**, please consider a little donation 🥳

[![ko-fi](https://img.shields.io/badge/Ko--fi-F16061?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/veeso)
[![PayPal](https://img.shields.io/badge/PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://www.paypal.me/chrisintin)

---

## Changelog ⌛

[View Changelog here](CHANGELOG.md)

---

## License 📜

Licensed under either of

- Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or <http://opensource.org/licenses/MIT>)

at your option.

---

### Contribution 🤝

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.

If you want to contribute to this project, please read the [Contributing guide](CONTRIBUTING.md) first 🙂.
