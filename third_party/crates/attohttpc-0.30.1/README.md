# attohttpc
[Documentation](https://docs.rs/attohttpc) | [Crates.io](https://crates.io/crates/attohttpc) | [Repository](https://github.com/sbstp/attohttpc)

## Why attohttpc?
This project's goal is to provide a lightweight and simple HTTP client for the Rust ecosystem. The intended use is for
projects that have HTTP needs where performance is not critical or when HTTP is not the main purpose of the application.
Note that the project still tries to perform well and avoid allocation where possible, but stays away from Rust's
asynchronous stack to provide a crate that's as small as possible. Features are provided behind feature flags when
possible to allow users to get just what they need. Here are the goals of the project:

* Lightweight
* Secure
* Easy to use
* Modular
* HTTP/1.1
* Use quality crates from the ecosystem (`http`, `url`, `encoding_rs`), not reinventing the wheel.

## Features
* `charsets` support for decoding more text encodings than just UTF-8
* `compress` support for decompressing response bodies using `miniz_oxide` (**default**)
* `compress-zlib` support for decompressing response bodies using `zlib` instead of `miniz_oxide` (see [flate2 backends](https://github.com/rust-lang/flate2-rs#backends))
* `compress-zlib-ng` support for decompressing response bodies using `zlib-ng` instead of `miniz_oxide` (see [flate2 backends](https://github.com/rust-lang/flate2-rs#backends))
* `json` support for serialization and deserialization
* `form` support for url encoded forms (does not include support for multipart)
* `multipart-form` support for multipart forms (does not include support for url encoding)
* `tls-native` support for tls connections using the `native-tls` crate (**default**)
* `tls-native-vendored` activate the `vendored` feature of `native-tls`
* `tls-rustls-webpki-roots` support for TLS connections using `rustls` instead of `native-tls` with Web PKI roots
* `tls-rustls-native-roots` support for TLS connections using `rustls` with root certificates loaded from the `rustls-native-certs` crate

## Usage
See the `examples/` folder in the repository for more use cases.
```rust
let resp = attohttpc::post("https://my-api.com/do/something").json(&request)?.send()?;
if resp.is_success() {
    let response = resp.json()?;
    // ...
}
```

## Current feature set
* Query parameters, Request headers, Bodies, etc.
* TLS, adding trusted certificates, disabling verification, etc. for both `native-tls` and `rustls`
* Automatic redirection
* Streaming response body
* Multiple text encodings
* Automatic compression/decompression with gzip or deflate
* Transfer-Encoding: chunked
* serde/json support
* HTTP Proxies & `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` environment variables.
* [Happy Eyeballs](https://en.wikipedia.org/wiki/Happy_Eyeballs)
* Authentication (partial support)

## License
This project is licensed under the `MPL-2.0`.
