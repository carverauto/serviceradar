# tokio-websockets

[![Crates.io](https://img.shields.io/crates/v/tokio-websockets.svg?maxAge=2592000)](https://crates.io/crates/tokio-websockets)
![GitHub Workflow Status (with event)](https://img.shields.io/github/actions/workflow/status/Gelbpunkt/tokio-websockets/ci.yml)
[![Documentation](https://img.shields.io/docsrs/tokio-websockets)](https://docs.rs/tokio-websockets)

High performance, strict, tokio-util based WebSockets implementation.

## Why use tokio-websockets?

- Built with tokio-util, intended to be used with tokio from the ground up
- Minimal dependencies: The base only requires:
  - `tokio`, `tokio-util`, `bytes`, `futures-core`, `futures-sink`
  - SHA1 backend, e.g. `sha1_smol` (see [Feature flags](#feature-flags))
- Big selection of features to tailor dependencies to any project (see [Feature flags](#feature-flags))
- SIMD support: AVX2, SSE2 or NEON for frame (un)masking and accelerated UTF-8 validation
- Strict conformance with the WebSocket specification, passes the [Autobahn test suite](https://github.com/crossbario/autobahn-testsuite) without relaxations [by default](https://gelbpunkt.github.io/tokio-websockets/index.html)
- TLS support
- Reusable TLS connectors
- Uses widely known crates from the ecosystem for types, for example `Uri` from `http` in the client
- Cheaply clonable messages due to `Bytes` as payload storage
- Tuned for performance (see [the benchmarks](./benches/README.md))

## Feature flags

Feature flags in tokio-websockets are added to allow tailoring it to your needs.

- `simd` will enable AVX2, SSE2 or NEON accelerated masking and UTF-8 validation. Additionally enabling the `nightly` feature when using a nightly compiler will also enable AVX512 accelerated masking
- `client` enables a tiny client implementation
- `server` enables a tiny server implementation

TLS is supported via any of the following feature flags:

- `native-tls` for a [`tokio-native-tls`](https://docs.rs/tokio-native-tls/latest/tokio_native_tls/) backed implementation
- `rustls-webpki-roots` for a [`tokio-rustls`](https://docs.rs/tokio-rustls/latest/tokio_rustls/) backed implementation with [`webpki-roots`](https://docs.rs/webpki-roots/latest/webpki_roots/)
- `rustls-native-roots` for a [`tokio-rustls`](https://docs.rs/tokio-rustls/latest/tokio_rustls/) backed implementation with [`rustls-native-certs`](https://docs.rs/rustls-native-certs/latest/rustls_native_certs/)
- `rustls-platform-verifier` for a [`tokio-rustls`](https://docs.rs/tokio-rustls/latest/tokio_rustls/) backed implementation with [`rustls-platform-verifier`](https://docs.rs/rustls-platform-verifier/latest/rustls_platform_verifier/)
- `rustls-bring-your-own-connector` for a [`tokio-rustls`](https://docs.rs/tokio-rustls/latest/tokio_rustls/) backed implementation that requires you to create your own `Connector::Rustls` - the `Connector::new` method will return a plain connector

The `rustls-*-roots` and `rustls-platform-verifier` features require a crypto provider for `rustls`. You can either enable the `aws_lc_rs` (optionally also FIPS-compliant via the `fips` feature) or `ring` features to use these crates as the providers and then use `TlsConnector::new()`, or bring your own with `TlsConnector::new_rustls_with_crypto_provider()`.

One SHA1 implementation is required, usually provided by the TLS implementation:

- [`ring`](https://docs.rs/ring/latest/ring/) or [`aws_lc_rs`](https://docs.rs/aws-lc-rs/latest/aws_lc_rs/) are used if the `ring` or `aws_lc_rs` features are enabled (recommended when `rustls` is used)
- The `openssl` feature will use [`openssl`](https://docs.rs/openssl/latest/openssl/), usually preferred on most Linux/BSD systems with `native-tls`
- The [`sha1_smol`](https://docs.rs/sha1_smol/latest/sha1_smol/) feature can be used as a fallback if no TLS is needed

The `client` feature requires enabling one random number generator:

- [`fastrand`](https://docs.rs/fastrand/latest/fastrand) can be used as a `PRNG`
- [`getrandom`](https://docs.rs/getrandom/latest/getrandom) can be used as a cryptographically secure RNG
- [`rand`](https://docs.rs/rand/latest/rand) can be used as an alternative to `fastrand` and should be preferred if it is already in the dependency tree

## Example

This is a simple WebSocket echo server without any proper error handling.

More examples can be found in the [examples folder](https://github.com/Gelbpunkt/tokio-websockets/tree/main/examples).

```rust
use futures_util::{SinkExt, StreamExt};
use http::Uri;
use tokio::net::TcpListener;
use tokio_websockets::{ClientBuilder, Error, Message, ServerBuilder};

#[tokio::main]
async fn main() -> Result<(), Error> {
  let listener = TcpListener::bind("127.0.0.1:3000").await?;

  tokio::spawn(async move {
    while let Ok((stream, _)) = listener.accept().await {
      let mut ws_stream = ServerBuilder::new()
        .accept(stream)
        .await?;

      tokio::spawn(async move {
        // Just an echo server, really
        while let Some(Ok(msg)) = ws_stream.next().await {
          if msg.is_text() || msg.is_binary() {
            ws_stream.send(msg).await?;
          }
        }

        Ok::<_, Error>(())
      });
    }

    Ok::<_, Error>(())
  });

  let uri = Uri::from_static("ws://127.0.0.1:3000");
  let (mut client, _) = ClientBuilder::from_uri(uri).connect().await?;

  client.send(Message::text("Hello world!")).await?;

  while let Some(Ok(msg)) = client.next().await {
    if let Some(text) = msg.as_text() {
      assert_eq!(text, "Hello world!");
      // We got one message, just stop now
      client.close().await?;
    }
  }

  Ok(())
}
```

## MSRV

The current MSRV for all feature combinations is Rust 1.79.

## Caveats / Limitations / ToDo

WebSocket compression is currently unsupported.
