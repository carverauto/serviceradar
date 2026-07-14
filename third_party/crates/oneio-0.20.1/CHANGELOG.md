# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## v0.20.1 -- 2025-12-18

### Changed
- `rustls` feature now enables both `rustls-tls-native-roots` and `rustls-tls-webpki-roots` for reqwest
  - Provides support for system certificates (including those installed by Cloudflare WARP or corporate VPNs)
  - Falls back to bundled Mozilla certificates in minimal environments
  - Both certificate stores are merged, providing maximum compatibility

## v0.20.0 -- 2025-10-29

### Added
- New `crypto` module with `ensure_default_provider()` helper function to initialize rustls crypto providers
  - Automatically tries AWS-LC first, then falls back to ring
  - Called automatically from all HTTPS/S3/FTP code paths
  - Can be called explicitly at startup for better control over initialization
  - Fully thread-safe and idempotent
  - Prevents "Could not automatically determine the process-level CryptoProvider" panic
- GitHub Copilot custom instructions file (`.github/copilot-instructions.md`) documenting development practices

### Changed
- All HTTPS, S3, and FTP operations now automatically initialize the rustls crypto provider on first use
- Added comprehensive documentation and examples for crypto provider initialization
- `rustls` feature now explicitly includes `dep:rustls_sys` dependency
- Simplified redundant feature flag checks (since `https` → `rustls`, only check `rustls`)
- Split CI workflow: formatting check now runs as separate independent job for faster feedback
- Updated `remote_file_exists()` to use `ensure_default_provider()` helper

## v0.19.2 -- 2025-10-17

### Changed

- Updated `flate2` dependency minimum version to `1.1.0` to include more recent fixes for `zlib-rs` backend.
- Add more backends for `flate2`:
  - `gz-zlib-ng` feature for `flate2/zlib-rs-ng`
  - `gz-zlib-cloudflare` feature for `flate2/cloudflare_zlib`

## v0.19.1 -- 2025-10-15

### Changed
- Gzip backend selection via feature flags:
  - Default feature `gz` switched to use flate2 with the `gz-zlib-rs` backend for improved performance.
  - New selectors and aliases:
    - `gz-zlib-rs` — enables `flate2/zlib-rs` (Rust, fast)
    - `gz-miniz` — enables `flate2/miniz_oxide` (pure Rust, most portable)
  - Disabled `flate2` default-features to allow explicit backend choice.

### Added
- Criterion benchmark `benches/gzip_decompress.rs` to measure gzip decompression throughput across backends.

### Usage
- Default (zlib-rs):
  - cargo build
  - cargo bench --bench gzip_decompress --features gz
- zlib-rs:
  - cargo build --no-default-features --features gz-zlib-rs
  - cargo bench --bench gzip_decompress --no-default-features --features gz-zlib-rs
- miniz_oxide (explicit):
  - cargo build --no-default-features --features gz-miniz
  - cargo bench --bench gzip_decompress --no-default-features --features gz-miniz

## v0.19.0 -- 2025-08-31

### Breaking Changes

#### Feature Flag Simplification

- Removed complex nested feature structure (`lib-core`, `remote`, `compressions`)
- Introduced flat structure: `gz`, `bz`, `lz`, `xz`, `zstd`, `http`, `ftp`, `s3`, `async`
- Changed default features from `["lib-core", "rustls"]` to `["gz", "bz", "http"]`

**Migration guide:**

```
# Before (v0.18.x)
oneio = { version = "0.18", features = ["lib-core", "rustls"] }

# After (v0.19.0)  
oneio = { version = "0.19", features = ["gz", "bz", "http"] }
```

#### Error System Consolidation

- Simplified from 10+ error variants to 3 essential categories:
    - `Io(std::io::Error)` - File system errors
    - `Network(Box<dyn Error>)` - Network/remote errors
    - `NotSupported(String)` - Feature is not compiled or unsupported operation

#### Removed Components

- Removed `build.rs` - No longer needed with simplified feature structure
- Removed `OneIOCompression` trait - Replaced with direct function calls

### New Features

#### Progress Tracking

- Added `get_reader_with_progress()` for tracking download/read progress
- Works with both known and unknown file sizes
- Tracks raw bytes read before decompression
- Callback-based API: `|bytes_read, total_bytes| { ... }`

#### Async Support (Feature: `async`)

- Added `get_reader_async()`, `read_to_string_async()`, `download_async()`
- True async support for HTTP and local files
- Compression support for gzip, bzip2, and zstd via async-compression
- LZ4 and XZ return `NotSupported` errors (no native async support)
- FTP/S3 protocols return clear "not supported" errors

#### CLI Enhancements

- Added LZ/XZ compression support to CLI tool
- Fixed typos in CLI option descriptions

### Improvements

#### Code Quality

- Replaced unsafe `unwrap()` calls in path parsing with safe alternatives
- Improved FTP login and file operation error handling
- Simplified HTTP stream error mapping
- Enhanced LZ4 error handling with better context
- Removed `eprintln` from library code in progress tracking

#### S3 Improvements

- Replaced fragile string matching with HTTP status code parsing in `s3_exists()`
- Fixed S3 upload hanging on non-existent files (issue #48)
- Made S3 documentation tests conditional on s3 feature

#### Testing and Examples

- Tests now work with any feature combination, including no features
- Updated progress tracking example to use indicatif
- Replaced unreliable `httpbin.org` endpoint with stable `spaces.bgpkit.org` endpoint
- Fixed doctest compilation with appropriate `ignore` flags

#### Documentation

- Updated lib.rs documentation for v0.19 changes
- Clarified `http` vs `https` feature distinctions:
  - `http` - HTTP-only support (no TLS)
  - `https` - HTTP/HTTPS with rustls (equivalent to `http` + `rustls`)
  - Custom TLS: Use `http` + `rustls` or `http` + `native-tls`
- Regenerated README from lib.rs documentation
- Added clear migration guide and feature explanations

### Dependencies

#### Updated

- Upgraded bzip2 to 0.6.0
- Added indicatif to dev-dependencies

#### Added (for async feature)

- tokio
- async-compression
- futures

### Code Simplification

- Removed trait-based compression system in favor of direct function calls
- Eliminated nested feature dependencies with a flat structure
- Simplified async implementation without spawn_blocking patterns
- Streamlined error types from 10+ variants to 3 categories

## v0.18.2 -- 2025-06-06

### Hot Fix

* Make `rustls_sys` dependency optional and exclude from `rustls` feature flag

## v0.18.1 -- 2025-05-31

### ✨ Added

- **New build script**: Added `build.rs` to enforce that at least one TLS backend (`rustls` or `native-tls`) is enabled
  if any of the remote features (`http`, `ftp`, or `remote`) are enabled.
- **Module documentation**: Added detailed Rust doc comments to the compression modules (gzip, bzip2, lz4, xz, zstd) and
  `utils.rs` for improved usability and understanding.
- **`get_protocol` function**: Utility for extracting protocol from file paths, now used across remote file access
  functions.

### 🛠️ Changed

- **Feature dependencies**: The `ftp` feature now explicitly depends on the `http` feature in `Cargo.toml`.
- **Error handling**: Updated `OneIoError` enum to more accurately gate error variants with corresponding features (
  `http`, `ftp`).
- **Module structure**:
    - `compressions` is now a public module.
    - Refactored how the crate distinguishes between local and remote file access, using `get_protocol`.
    - `get_reader_raw` and related functions now determine protocol and select the appropriate file reader accordingly.
- **Compression interface**:
    - Added a unified trait `OneIOCompression` and `get_compression_reader`/`get_compression_writer` utilities for
      consistent handling of all supported compression algorithms.
    - Updated file open logic to use these helpers based on file suffix.

### 🧹 Cleaned up and Improved

- Removed legacy or redundant code paths (e.g., `get_reader_raw_remote`, old error gates).
- Moved protocol detection and remote file reading logic into more modular and maintainable forms.
- Several function signatures and internal APIs have been updated for clarity and maintainability.

---

### 📝 Developer Notes

- All compression modules (`gzip`, `bzip2`, `lz4`, `xz`, `zstd`) now include clear documentation and consistent
  interfaces for reading and writing compressed files.
- Users enabling remote protocol features must ensure at least one TLS backend is also enabled.

## v0.18.0 -- 2025-05-30

### Highlights

* split `remote` features into `http` and `ftp`, allowing users who only need HTTP or FTP support to use the
  corresponding feature flag
    * in most cases, users will likely not need to use the `ftp` feature
* add `create_client_with_headers` function to allow creating a `reqwest::blocking::Client` with custom headers
    * this simplifies the process of creating a client with custom headers for HTTP requests
    * this also allows users to create custom clients without importing `reqwest` crate directly
* add `rustls_sys` dependency to support `rustls` as the default TLS backend

### Documentation improvements

* update examples on custom HTTP request function `oneio::get_http_reader` to use `create_client_with_headers`

## v0.17.0 -- 2024-08-04

### Highlights

* add support for `zstd` (zstandard) compression
* allow setting `ONEIO_ACCEPT_INVALID_CERTS=true` to disable SSL checking
* revised custom HTTP request function `oneio::get_http_reader` to allow specifying custom `request::blocking::Client`
  for any request customizations to allow specifying custom `request::blocking::Client` for any request customizations.

### Breaking changes

1. rename `oneio::get_remote_reader` to `oneio::get_http_reader`
2. rename `get_remote_ftp_raw` to `get_ftp_reader_raw`
3. change signatures of `oneio::download`, `oneio::download_with_retry`, `oneio::get_http_reader`'s optional HashMap
   parameter for headers to optional `reqwest::blocking::Client`.

## v0.16.8 -- 2024-05-22

### Highlights

* `s3_url_parse` allow parsing different protocols like `r2://` or `b2://`
    * previously, if the URL did not start with `s3://` it would return an error

## v0.16.7 -- 2024-03-26

### Highlights

* make `compressions` mod always enabled and allow making all compression algorithms optional
    * to enable all compression algorithms,
      use `oneio = { version = "0.16", default-features = false, features = ["compressions"] }`
    * to enable specific compression algorithms,
      use `oneio = { version = "0.16", default-features = false, features = ["gz", "bz", "lz", "xz"] }`

## v0.16.6 -- 2024-03-26

### Highlights

* make `digest` feature optional and disabled by default

## v0.16.5 -- 2024-03-20

### Highlights

* add `CONTENT_LENGTH=0` to headers to address some queries where the server request `Content-Length` field

## v0.16.4 -- 2024-03-20

### Hot fix

* add `http2` and `charset` feature flags to `reqwest`
    * the feature flags for `reqwest` has changed a lot between `0.11` and `0.12` and the `http2` and `charset` features
      are necessary now

## v0.16.3 -- 2024-03-20

* switch `flate2` to `rust-backend` default feature as the `zlib-ng` feature requires `cmake` to build and offers no
  performance improvement over the `rust-backend` feature
* update `reqwest` to version `0.12`

## v0.16.2 -- 2024-02-23

### Highlights

* switching to `flate2` with `zlib-ng` as the compression library for handling `gzip` files
    * `zlib-ng` is a drop-in replacement for `zlib` with better performance

## v0.16.1 -- 2024-02-10

### Highlights

* add `oneio::exists(path: &str)` function to check if a local or remote file exists.
    * currently support local file, http(s) remote and s3 remote files checking

### Example usages

```rust
assert!(!oneio::exists("https://spaces.bgpkit.org/oneio/test_data_NOT_EXIST.json").unwrap());
assert!(oneio::exists("https://spaces.bgpkit.org/oneio/test_data.json").unwrap());
```

## v0.16.0 - 2024-01-29

### Breaking changes

- switch to `rustls` as the default TLS backend
- clean up the feature flags
    - removed `no-cache` and `vendored-openssl` flags
    - removed `openssl` optional dependency
    - add `digest` feature flag to allow calculating SHA256 digest of a file, enabled by default

### Library changes

- add `oneio::download_with_retry` function to allow retrying download
- add `oneio::get_sha256_digest` function to the library to calculate SHA256 digest of a file

### CLI changes

- add `oneio digest FILE` command to calculate file SHA256 digest

## v0.15.10 - 2024-01-26

### Hot fix

- fixed issue where `oneio s3 list BUCKET PREFIX` command not showing files match the prefix unless they are on the same
  directory as the prefix
- fixed issue where running `oneio` without argument causing program to panic

## v0.15.9 - 2024-01-26

### Highlights

- add support for installing via [`cargo binstall`](https://github.com/cargo-bins/cargo-binstall)
- `s3_list` now accepts a new forth parameter, `dirs` boolean flag, to allow returning only the matching directories
- add `oneio s3 list` and `oneio s3 upload` commands to the CLI

### Breaking changes

The signature of `s3_list` function is now changed to:

```rust
pub fn s3_list(
    bucket: &str,
    prefix: &str,
    delimiter: Option<String>,
    dirs: bool,
) -> Result<Vec<String>, OneIoError> {}
```

This includes changes of:

1. `delimiter` changed from `Option<&str>` to `Option<String>`
2. new `dirs` boolean flag to allow returning only matching directories in the specified prefix
    - the `delimiter` is also automatically forced to `Some("/".to_string())` if `dirs` is specified and `delimiter` is
      specified as `None`.

### Misc

- "cargo publish" process is now automated with GitHub actions
- test process now makes sure `s3` modules' doc-tests must compile

## v0.15.8 - 2023-12-18

### Highlights

* Added `vendored-openssl` flag to enable GitHub actions builds for different systems.
* Automatically builds CLI binary for macOS (Universal), and linux (arm and amd64) during GitHub release

## v0.15.8-beta.1 - 2023-12-16

### Highlights

* GitHub actions use vendored openssl instead of system openssl.

## v0.15.7 - 2023-12-16

### Highlights

* Module Refactoring: A dedicated module has been created for remote and utils.
  (ec80e0236170f13e9eec2450eeaa8334e255a1ee)
* Improvements in Caching Control: The HTTP caching is now controllable and disabled for CLI requests.
  (69de57c5f9a7003edecde2fe6641c438abe233a5)
* Improved Error Handling: We have improved error handling in line reads. The application no longer attempts to read
  further if a line read fails, preventing any stalls. (fd1352fa2cb701e3fb336a4b6f99014d76d64788)

## v0.15.6 - 2023-12-16

### Added

- support getting oneio reader directly by supplying an S3 URL: https://github.com/bgpkit/oneio/pull/31
