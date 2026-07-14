# Changelog

## [0.16.0] - 2026-06-08

### Breaking changes

- **Features:** `x509-source` now enables only `workload-api-x509`, and `jwt-source` only `workload-api-jwt`, so each source no longer pulls in the other SVID type's parsing dependencies.
- **Features:** Removed the redundant `workload-api-full` feature; use `workload-api` instead.
- **Re-exports:** Dropped the unprefixed `ReconnectConfig` and `ResourceLimits` re-exports at the crate root; use the `X509`/`Jwt`-prefixed aliases (`X509ReconnectConfig`, `X509ResourceLimits`, `JwtReconnectConfig`, `JwtResourceLimits`) or the `x509_source`/`jwt_source` module paths.
- **Source limits:** Marked `X509ResourceLimits` and `JwtResourceLimits` as non-exhaustive; construct resource limits with `new`, `default`, `default_limits`, or `unlimited`.
- **JwtSource:** Renamed `get_jwt_svid` to `fetch_jwt_svid` and `get_jwt_svid_with_id` to `fetch_jwt_svid_with_id`.
- **Source reconnect config:** Marked `X509ReconnectConfig` and `JwtReconnectConfig` as non-exhaustive; construct them with `ReconnectConfig::new(min_backoff, max_backoff)`, `default`, or the builder's `reconnect_backoff(...)`.

### Added

- **Re-exports:** Re-exported `Certificate` and `PrivateKey` at the crate root (previously only available under `spiffe::cert`).
- **Re-exports:** Re-exported the `BundleSource` and `SvidSource` traits at the crate root, so the trait no longer needs to be imported from `spiffe::bundle` / `spiffe::svid`.

## [0.15.1] - 2026-05-11

### Fixed

- **Trust bundles and federation:** Fail closed when trust-domain selection excludes all available bundles, instead of treating verification as successful (#350).
- **Certificates:** Return an error when a URI SAN exceeds size limits, instead of silently skipping it (#348).
- **X.509-SVID:** Avoid a panic when encoding a non-empty certificate chain whose leaf certificate was extracted separately (#349).
- **JWT source and Workload API:** Retry JWT-SVID fetches only for transient errors (#347).


## [0.15.0] – 2026-05-08

### Added

- **WorkloadApiClient:** Added `new_with_channel_and_interceptor(...)` for callers that need to inject custom per-RPC gRPC metadata.

## [0.14.0] – 2026-04-25

### Breaking changes

- `X509SourceError` and `JwtSourceError` are now `#[non_exhaustive]`; exhaustive matches must include a wildcard arm.
- `is_healthy()` is stricter and now returns `false` when the supervisor has stopped, the selected X.509 SVID is expired, or the JWT bundle set has no signing authorities.

### Added

- **X509Source / JwtSource:** Added `initial_sync_timeout(Duration)` builder support. The timeout applies only to construction-time initial sync and does not affect background reconnects.
- **X509Source / JwtSource:** Added `InitialSyncTimeout` error variants, returned only when `initial_sync_timeout()` is configured.

### Fixed

- **X509Source / JwtSource:** Dropping the last source handle now cancels the background supervisor.
- **X509Source / JwtSource:** `changed()` and `wait_for()` now return `Closed` after shutdown or supervisor exit instead of potentially blocking indefinitely.
- **X509Source / JwtSource:** Successful updates now notify subscribers before recording success metrics.

### Changed

- **JwtSource:** The on-demand JWT SVID client is now created lazily on the first `get_jwt_svid` call instead of during `build()`.


## [0.13.0] – 2026-04-18

### Breaking changes

- **JWT:** Added ES512 parsing support; offline verification errors are backend-specific (#322).

### Fixed

- **X509 source:** Only cancel the underlying source when the last `X509Source` is dropped (#327).
- **X.509-SVID:** Reject leaf certificates with multiple URI SAN entries (#325).
- **X.509-SVID:** Reject root-only leaf SPIFFE IDs.
- **SPIFFE ID:** Enforce trust domain length limits and adjust parse-time URI limits.
- **SPIFFE ID:** Accept the `spiffe:` scheme case-insensitively and canonicalize the trust domain (#320).


## [0.12.0] – 2026-02-24

### Breaking changes
- `WorkloadApiClient::validate_jwt_token` now accepts `audience: &str` instead of a generic `IntoIterator`, matching the protobuf `ValidateJWTSVIDRequest` schema (single `audience` field).
- JWT `parse_and_validate` leeway set to 0, enforcing the documented “no clock skew” behavior. Tokens previously accepted within 60 seconds of expiry are now rejected.

### Fixed
- Reject certificates with unparseable `BasicConstraints` or `KeyUsage` extensions instead of silently skipping validation (`X509SvidError::UnparseableExtension`).
- Reject trailing bytes in single-certificate DER parsing.
- Supervisor backoff improvements:
  - Reset backoff only after successfully processing a stream update.
  - Respect user-configured `max_backoff` in the no-identity policy.
  - Preserve jitter at maximum backoff to prevent thundering-herd reconnections.
- Retry `JwtSource` client creation with a short delay after initial sync succeeds.
- Enforce SPIFFE ID URI length limit (2048 bytes) in `SpiffeId::from_segments`.
- Reject password-only user info in endpoint URI validation.
- Require bracketed IPv6 addresses in TCP connector URIs.

### Changed
- Document plaintext security implications of the TCP transport.


## [0.11.4] – 2026-02-14

### Security
- Bumped `time` dependency to `>=0.3.47` to address RUSTSEC-2026-0009 / CVE-2026-25727.

### Changed
- MSRV raised from 1.87 to 1.88 (required by `time` 0.3.47+).
- Replaced `tokio-stream` with `futures` for stream types.
- Removed `once_cell` in favor of `std` equivalents.
- Promoted several public accessors and constructors to `const fn`.
- Workspace lints now inherited via `[lints] workspace = true`.
- Tightened rustdoc across modules.


## [0.11.3] – 2026-01-22

### Changed
- Tightened README and crate-level documentation for clarity and consistency; no functional changes.


## [0.11.2] – 2026-01-21

### Fixed
- Ensure observability macros always consume their arguments to avoid
  `unused_variable` warnings when neither `logging` nor `tracing` is enabled.
- Resolve clippy warnings in edge-case feature combinations.

### Notes
- No public API changes.


## [0.11.1] - 2026-01-11

### Fixed

* Fixed incorrect retry behavior when the Workload API returns `NoIdentityIssued`, avoiding tight retry loops and excessive log noise.
* Ensured consistent retry and backoff semantics across X.509 and JWT supervisors.

### Changed

* Refactored shared supervisor logic into a new `supervisor_common` module to remove duplication and improve maintainability.
* Improved supervisor diagnostics, including clearer lifecycle, recovery, and stream connectivity logging.

### Security / Hardening

* Enforced a maximum X.509 certificate chain length (16) to mitigate resource-exhaustion inputs.
* Clarified parsing behavior by allowing unbounded X.509 bundles while keeping certificate chains bounded.
* Enforced the SPIFFE spec maximum URI length (2048 bytes) for SPIFFE IDs.
* Capped JWT-SVID `aud` claim entries (32) during deserialization to limit pre-verification allocations.


## [0.11.0] - 2026-01-18

### Highlights
- **New: `JwtSource`** — high-level API for automatic JWT bundle watching and cached, on-demand JWT-SVID fetching.  
  Provides API parity with `X509Source` and aligns with the canonical SPIFFE implementation (go-spiffe).

### Added
- `JwtSource`, a managed source for JWT bundles and JWT-SVIDs backed by the Workload API.
- Automatic JWT bundle watching with in-memory caching and rotation handling.
- On-demand JWT-SVID fetching via `get_jwt_svid()` and `get_jwt_svid_with_id()`.
- Update notifications through the `updated()` handle.
- Configurable resource limits for bundle count and JWKS size.
- Optional metrics recorder integration.
- Health checks via `is_healthy()`.
- Graceful shutdown support (`shutdown()` and `shutdown_with_timeout()`).
- Automatic reconnection with exponential backoff on transient failures.

### Notes
- This is an additive change and does not introduce breaking API changes.
- `JwtSource` is opt-in and does not affect existing `X509Source` behavior.


## [0.10.2] – 2026-01-17

### Fixed

- Fixed `to_certificate_vec` to preserve original DER bytes when parsing certificate chains, ensuring byte-for-byte equality with input data.

### Changed

- Improved performance of URI SAN extraction by iterating directly over `general_names` and applying early filtering for SPIFFE IDs.
- Added security bounds to URI SAN processing: a maximum of 32 URI SAN entries and 2048 bytes per URI, preventing resource exhaustion from malformed or adversarial certificates.
- Changed `MissingX509Extension` error variant to use `Oid<'static>` instead of `String` for better type safety and consistency with `oid_registry` constants.

### Added

- Added `TooManyUriSanEntries` error variant to `CertificateError` for certificates exceeding the URI SAN entry limit.
- Added tests covering certificate parsing edge cases and error conditions.


## [0.10.1] – 2026-01-05

### Changed

- Improved performance of SPIFFE ID and TrustDomain parsing by switching to byte-level validation, reducing allocations, and optimizing common parsing paths.

### Added

- Added fuzz targets for SPIFFE ID and TrustDomain parsing to validate parser invariants and harden input handling.


## [0.10.0] – 2026-01-03

### Breaking changes

- Default feature set is now empty (`default = []`). Feature-gated capabilities (Workload API, X.509 parsing, JWT, etc.) must be explicitly enabled.
- `X509Source::new()` return type changed from `Arc<X509Source>` to `X509Source` (cloneable).
- Module layout changes: X.509 source moved to `spiffe::x509_source`; endpoint parsing moved under `spiffe::transport`.

### Added / Changed

- Clear feature matrix separating X.509, JWT, transport, and Workload API concerns.
- Heavy X.509 and JWT parsing dependencies are now fully feature-gated (`x509`, `jwt`).
- New Workload API tiers: `workload-api-core`, `workload-api-x509`, `workload-api-jwt`, `workload-api-full`
  (`workload-api` remains an alias for `-full`).
- Improved endpoint parsing: supports `tcp:IP:PORT`, IPv6, stricter unix path validation, and `FromStr`.
- Polished `X509Source` builder API and documentation.
- Integration tests are now feature-gated and `#[ignore]`.

**Migration:** see `docs/migration-spiffe-0.10.md`.


## [0.9.2] – 2025-12-30

### Changed

- Expose `Endpoint` and `EndpointError` in `transport` feature.


## [0.9.1] – 2025-12-30

### Changed

- Observability is now fully opt-in via features:
  - `logging` enables `log`
  - `tracing` enables `tracing`
  - precedence: `tracing` > `logging` > no-op
- `workload-api` no longer enables `log` implicitly (reduced default dependency surface).

### Documentation

- Documented observability feature precedence and clarified that features are additive / opt-in.

### Migration notes

- If you relied on `workload-api` enabling logging implicitly, enable `logging` explicitly:
  `spiffe = { version = "0.9.1", features = ["workload-api", "logging"] }`


## [0.9.0] – 2025-12-30

### Breaking changes

- Offline JWT verification is now feature-gated.
  - `JwtSvid::parse_and_validate` requires enabling a `jwt-verify-*` feature.
- `SvidPicker::pick_svid` now returns `Option<usize>` instead of a reference.
- Internal feature renamed: `grpc` → `transport`.
- `GrpcClientError` replaced by `WorkloadApiError` and `TransportError`.
- MSRV bumped from 1.83 to 1.85.

### Added

- X509Source hardening:
  - Resource limits (SVIDs, bundles, bundle size)
  - Graceful shutdown with timeout
  - Metrics hooks and categorized error reporting
- Optional `tracing` feature for structured logging.
- New `X509SourceUpdates` API for update notifications.
- Stricter and more defensive JWT / JWKS parsing.

### Changed

- `JwtBundleSet` now uses deterministic ordering (`BTreeMap`).
- Default dependency and cryptography surface reduced via feature gating.

### Deprecated

- `JwtBundleSet::bundle_for` (use `get` instead).


## [0.8.0] – 2025-12-26

### Breaking changes

- Removed the `spiffe-types` feature; core SPIFFE types are now always enabled.
- Refactored `WorkloadApiClient` to be non-mutable; all client methods now take `&self`.
- Removed legacy `Bundle`, `BundleRefSource`, `Svid`, and `SvidRefSource` traits.
- Introduced `BundleSource` and `SvidSource` returning shared `Arc` values.
- Standardized bundle lookup APIs (`get_bundle*` → `bundle_for*`).
- Replaced string-based socket handling with a typed `Endpoint` abstraction.
- Updated JWT-SVID parsing to use spec-correct `exp` handling.
- Refined `GrpcClientError` with explicit semantic variants and gRPC status mapping.

### Added

- First-class support for SVID hints for both X.509 and JWT identities.
- Multi-SVID fetch APIs and hint-based JWT SVID selection.
- Explicit Unix and TCP endpoint handling with strict validation.


## [0.7.4] – 2025-12-24

- Migrated to the Rust 2021 edition.
- Minimum supported Rust version (MSRV) is now 1.83.


## [0.7.3] – 2025-12-24

### Fixed

- Fixed compilation when building with `--no-default-features`.
- Correctly feature-gated public re-exports and error variants tied to optional dependencies.
- Prevented optional dependencies from being required in minimal builds.


## [0.7.2] – 2025-12-24

### Changed

- Moved protobuf code generation out of build scripts and into an explicit `xtask` workflow.
- Committed generated Workload API sources.

### Removed

- Removed build-time protobuf generation (`build.rs`) from the `spiffe` crate.


## [0.7.1] – 2025-12-23

### Added

- Added `JwtSvid::claims()` accessor to expose parsed JWT claims in a read-only, safe manner.
- Added `X509Source::x509_context()` convenience method to retrieve a snapshot of the current X.509 SVIDs and bundle set.

### Documentation

- Fixed doctest examples to correctly handle `Option`-returning APIs (`default_svid()`).
- Updated examples to use `bundle_set()` instead of non-existent `bundles()` accessor.
- Clarified `X509Source` as the primary entry point for X.509 workloads.
- Improved overall structure and readability of crate-level docs.

### Notes

- No breaking changes: existing APIs remain unchanged; additions are purely additive.


## [0.7.0] – 2025-12-23

### Breaking changes

- The `X509Source` construction API has changed from `default()` to `new()`.

### Added

- Automatic reconnection handling in `X509Source` when the SPIRE agent becomes unavailable and later recovers.

### Changed

- `X509Source::default()` has been replaced by `X509Source::new()` for clearer and more explicit construction.
- `X509Context` now includes federated bundles in addition to the trust domain bundle (#175).
- Updated `x509-parser` dependency from `0.17` to `0.18` (#171).
- Updated `jsonwebkey` dependency from `0.3` to `0.4` (#182).

### Migration notes

- Replace any usage of `X509Source::default()` with `X509Source::new()` when upgrading to v0.7.0.


## [0.6.7] – 2025-07-30

### Changed

- Bump tonic and prost dependencies to version 0.14 (#165)
- Bump protox dependency to 0.9.0 (#165)


## [0.6.6] – 2025-05-25

### Changed

- Bump tonic dependencies to version 0.13 (#144)
- Bump protox dependency to 0.8.0 (#151)


## [0.6.5] – 2025-03-04

### Changed

- Directly include generated Protobuf code from `OUT_DIR` (#138)


## [0.6.4] – 2025-01-31

### Changed

- Use protox to avoid the need to have `protoc` installed (#133)
- Bump Swatinem/rust-cache from 2.7.5 to 2.7.7 (#131)
- Bump coverallsapp/github-action from 2.3.4 to 2.3.6 (#134)
- Update x509-parser requirement from 0.16 to 0.17 (#135)


## [0.6.3] – 2024-11-07

### Changed

- Depend explicitly on tonic 0.12.3 (#120)
- Update thiserror requirement from 1 to 2 (#127)


## [0.6.2] – 2024-10-07

### Changed

- Bump tonic dependencies to latest tonic release `0.12` (#111)
- Remove `jwk-rs` as a runtime dependency (#115)


## [0.6.1] – 2024-09-11

### Changed

- Update Rust edition to 2021 (#82)
- Enhance usability with core type re-exports (#83)


## [0.5.0] – 2024-03-07

### Changed

- Updated `prost`, `prost-types`, and `prost-build` to 0.12 (#73)
- Updated `tonic` and `tonic-build` to 0.11 (#73)
- Updated `x509-parser` to 0.16 (#73)


## [0.4.0] – 2023-08-23

### Added

- Refactor of `spiffe` crate introducing `spiffe-types` and `workload-api` features (#44).
- Implemented `X509Source` for fetching X.509 materials (#50).
- Added dependencies `log` and `tokio-util` to the `workload-api` feature (#50, #51).

### Changed

- Renamed `stream_` methods in `WorkloadApiClient` (#44).
- Moved `SocketPathError` and `GrpcClientError` to `spiffe::errors` as part of `spiffe-types` (#44).
- Replaced `unreachable!()` in `find_spiffe_id` with `UnexpectedExtension` for SAN parsing robustness (#48).


## [0.3.1] – 2023-08-12

### Fixed

- Integrated `google/protobuf/Struct.proto`, removing the need for system versions (#36).


## [0.3.0] – 2023-08-08

### Breaking changes

- Workload API client methods transitioned from synchronous to asynchronous and now require `&mut self`.

### Added

- Support for watching and streaming updates for X.509 and JWT SVIDs and bundles.
- New integration tests covering watch / stream functionality.
- New dependencies: `tonic`, `prost`, `prost-types`, `tokio`, `tokio-stream`, and `tower`.

### Changed

- Code generation migrated from `protobuf` and `grpcio` to `tonic` and `prost`.

### Removed

- Removed `protobuf`, `grpcio`, and `futures` dependencies.


## [0.2.2] – 2023-08-05

- Added `watch_x509_context_stream` method to `WorkloadApiClient` (#28)
- Updated `grpcio` to 0.12.0 (#27)
- Updated dependencies (#26)
- Added error info to `grpcio::Error` (#25)


## [0.2.1] – 2022-04-22

- Fixed the `chrono` RUSTSEC advisory (#17)
- Replaced `chrono` with `time`.


## [0.2.0] – 2021-07-06

- Strict SPIFFE ID parsing (#8)
- `validate_jwt_token` now returns a parsed `JwtSvid` after validation via the Workload API (#9)


## [0.1.1] – 2021-06-18

- Added `validate_jwt_token` method to `WorkloadApiClient` (#2).


## [0.1.0] – 2021-06-14

- Initial implementation:
  - Workload API client with one-shot call methods
  - Certificate and private key types
  - X.509 SVID and bundle types
  - JWT SVID and bundle types
  - `TrustDomain` and `SpiffeId` types
