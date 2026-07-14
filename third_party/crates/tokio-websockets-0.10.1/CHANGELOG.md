# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.1] - 2024-09-13

### Added

- The new `rustls-bring-your-own-connector` feature allows for creating a `Connector::Rustls` instance without pulling in any other certificate roots
- The sink flush threshold is now configurable via `Config::flush_threshold`

### Changed

- `Config::frame_size` now panics when the frame size is set to 0
- Reduced the number of allocations which was caused by a misunderstanding of `BytesMut::reserve` internals, improving throughput by up to 30%
- The number of pending bytes to be written is no longer calculated in a potentially expensive loop in `poll_ready`, but rather tracked as messages are queued

### Fixed

- Fixed a case of possible UB in the UTF-8 validator discovered by the new fuzzer (@finnbear)
- The UTF-8 validator now uses the faster validation for partial codepoints as intended, earlier this was only the case if the number of bytes available matched the number expected

## [0.10.0] - 2024-09-04

### Added

- `Error::NoNativeRootCertificatesFound` was added and is returned in `TlsConnector::new` if no native root certificates were found and the rustls-webpki-roots feature is not enabled

### Changed

- If no crypto provider is specified via crate features, tokio-websockets will now try to use the installed default provider in rustls
- `TlsConnector::new` is now always available
- **[breaking]** `Error::NoTlsConnectorConfigured` was removed and replaced by `Error::NoCryptoProviderConfigured`
- `rustls-native-certs` was updated to 0.8

### Fixed

- Fixed an issue where connecting to an IPv6 address would fail
- Specify the actual minimum version required of rustls-platform-verifier

## [0.9.0] - 2024-08-05

### Added

- `Payload` now implements `From<Vec<u8>>`
- `Payload` now also implements `Into<BytesMut>`, which is a cheap conversion unless multiple references to the backing buffer exist

### Changed

- **[breaking]** The MSRV is now 1.79, allowing use of `split_at_mut_unchecked` to make some unsafe code less error prone
- **[breaking]** The minimum required version of bytes is now 1.7
- **[breaking]** The `Resolver` trait now uses async fn syntax
- The `From<String>` implementation on `Payload` now uses `BytesMut` internally, improving performance in some cases
- The `From<Bytes>` implementation on `Payload` now uses `BytesMut` internally if cheaply possible, improving performance in some cases

## [0.8.3] - 2024-05-24

### Fixed

- Fixed an unsafe precondition violation triggered upon receiving close messages with empty reason

## [0.8.2] - 2024-04-16

### Fixed

- Yet another docs.rs build fix

## [0.8.1] - 2024-04-16

### Added

- Added support for `rustls-platform-verifier` via a feature with the same name

### Fixed

- Fixed the docs.rs build

## [0.8.0] - 2024-04-15

### Added

- Support for `aws_lc_rs` as a SHA1 and crypto provider was added via the `aws_lc_rs` feature, optionally also FIPS-compliant via the `fips` feature
- The new `rustls-tls12` feature will enable TLS1.2 support in rustls

### Changed

- **[breaking]** The rustls dependency was updated to 0.23 and tokio-rustls to 0.26
- **[breaking]** The minimum required version of tokio-util is now 0.7.3
- A bunch of leftover unused `Encoder` implementations and the associated write buffers were removed
- The `client` feature no longer depends on `tokio/rt`

### Fixed

- The `nightly` feature now enables the `stdarch_x86_avx512` nightly feature only on x86_64 instead of all architectures
- The documentation for `Config::frame_size` was ambiguous about whether it affected the payload size or the entire frame size, this has been clarified to be the payload size

### Removed

- The `http-integration` feature and associated `upgrade_request` method were removed, it offered little to no value over manually crafting a request and bloated the dev-dependency stack unnecessarily

## [0.7.0] - 2024-02-27

### Changed

- **[breaking]** The future returned from `Resolver::resolve` is now required to be `Send`. This restores backwards compatibility with 0.5.x

## [0.6.0] - 2024-02-27

### Added

- `Payload` now implements `From<&'static [u8]>` and `From<&'static str>`
- The `ClientBuilder` now allows specifying a DNS resolver that implements the `Resolver` trait via `ClientBuilder::resolver`, stored as a generic on the builder. It defaults to `resolver::Gai`, which matches behavior on previous versions

### Changed

- **[breaking]** `ClientBuilder::connect` now returns an `Error::UnsupportedScheme` if the URI does not set the scheme to `ws` or `wss`
- **[breaking]** `ClientBuilder::connect` will no longer unconditionally use the specified custom connector, instead it will always use a plain connector for the `ws` scheme
- **[breaking]** The `nightly` feature now uses the new `stdsimd` feature instead of `stdarch_x86_avx512`, which was removed in recent nightly compiler versions

### Fixed

- The `Debug` implementation of `Connector` now prints the correct name of the `Rustls` variant
- The header buffer size in the built-in server was increased to 64, which allows clients sending larger amounts of headers to connect
- Fixed a case of UB when a message was constructed via `Message::text` with invalid UTF-8 and then converted to a `&str` via `Message::as_text`. This will now cause a panic

## [0.5.1] - 2023-12-29

### Changed

- `Message::text` now takes `Into<Payload>` instead of `String`, which now implements `Into<Payload>`

## [0.5.0] - 2023-12-11

### Dependencies

- Updated `http` to 1.0 and `rustls`-related dependencies to those compatible with `rustls` 0.22
- **[breaking]** `ring` is now an optional dependency with `rustls` and different crypto providers can be used
- Optimized `simdutf8` feature flags for aarch64

### Changed

- **[breaking]** `upgrade_request` no longer uses an explicit body type, now it only requires the body to implement `Default`
- **[breaking]** `WebsocketStream` has been renamed to `WebSocketStream`
- **[breaking]** `Message` payloads are now exposed as `Payload` and it is possible to create messages from `Bytes`-backed payloads
- Removed a few excess allocations in hot paths

### Fixed

- Fixed issues with the close sequence handling

## [0.4.1] - 2023-11-23

### Fixed

- Fixed invalid opcode errors when intermediate control frames were received

## [0.4.0] - 2023-09-10

### Dependencies

- Update `webpki` to 0.24, `webpki-roots` to 0.25 and `rust-webpki` to 0.101

### Added

- Added support for NEON-accelerated frame (un)masking
- Added support for AVX512-accelerated frame (un)masking, gated behind the `nightly` feature flag and requires a nightly compiler
- Limits for payload length can be applied via `{ClientBuilder, ServerBuilder}::limits` to protect against malicious peers
- The websocket stream can now be configured via `{ClientBuilder, ServerBuilder}::config`. This currently only supports changing the frame payload size that outgoing messages are chunked into

### Changed

- The crate now specifies and validates a MSRV of Rust 1.64
- The library now validates UTF-8 in partial continuation frames to a text message
- Several types now implement `Debug`
- The performance of the decoder has been improved
- The encoder is now usually zero-copy and operates in-place when possible
- Reduced the amount of calls to `fastrand`
- `upgrade::Error` is now publicly accessible and can thus be matched on
- **[breaking]** `ClientBuilder` methods which perform a handshake now return a tuple of `(WebsocketStream, Response)` to retrieve e.g. response headers
- **[breaking]** `WebsocketStream` is now fully cancellation safe and implements `Stream`, therefore using `WebsocketStream::next` now requires having `StreamExt` in scope
- **[breaking]** `CloseCode` is now a wrapper around a `NonZeroU16` instead of an enum. Enum variants have been moved to associated constants. This fixes possible creation of disallowed close codes by the user
- **[breaking]** All error types are now marked as `non_exhaustive` to prevent consumer build breakage when new variants are added
- **[breaking]** Emptied default features

### Removed

- **[breaking]** `{ClientBuilder, ServerBuilder}::fail_fast_on_invalid_utf8` has been removed and is now always enabled because our implementation for streaming UTF-8 validation is already efficient enough, benchmarks show no gains anymore
- **[breaking]** Some error variants have been removed and coalesced into other variants (mostly into `InvalidOpcode`). `ConnectionClosed` has been entirely removed in favor of returning `None` from `poll_next` because it is more idiomatic
- **[breaking]** `WebsocketStream::close` has been removed. The `SinkExt::close` implementation will send a default close message and properly shut down the sink. Custom close messages can be sent via `SinkExt::send` followed by `SinkExt::close`
- The `futures-util` dependency has been removed

### Fixed

- A few inconsistencies with the websocket RFC have been fixed
