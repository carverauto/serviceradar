# spiffe

[![Crates.io](https://img.shields.io/crates/v/spiffe.svg)](https://crates.io/crates/spiffe)
[![Docs.rs](https://docs.rs/spiffe/badge.svg)](https://docs.rs/spiffe/)
[![Safety](https://img.shields.io/badge/unsafe-forbidden-success.svg)](https://github.com/rust-secure-code/safety-dance)
[![Rust 1.88+](https://img.shields.io/badge/rust-1.88+-orange.svg)](https://www.rust-lang.org)

Core SPIFFE identity types and Workload API sources.

This crate provides SPIFFE identity primitives (`SpiffeId`, `TrustDomain`) and clients for the
SPIFFE Workload API (`X509Source`, `JwtSource`, `WorkloadApiClient`). It handles X.509 and JWT
SVIDs, trust bundles, and streaming updates. All cryptography and TLS integration are intentionally delegated to other crates.

---

## Installation

Add `spiffe` to your `Cargo.toml`. All features are opt-in:

```toml
[dependencies]
# Minimal: only SPIFFE primitives 
spiffe = "0.15"

# OR X.509 workloads (recommended)
# spiffe = { version = "0.15", features = ["x509-source"] }

# OR JWT workloads (recommended)
# spiffe = { version = "0.15", features = ["jwt-source"] }

# OR Direct Workload API usage
# spiffe = { version = "0.15", features = ["workload-api"] }
```

---

## Quick start

### Create a Workload API client

Using an explicit socket path:

```rust
use spiffe::WorkloadApiClient;

let client = WorkloadApiClient::connect_to(
    "unix:/tmp/spire-agent/public/api.sock",
).await?;
```

Or via the `SPIFFE_ENDPOINT_SOCKET` environment variable:

```rust
use spiffe::WorkloadApiClient;

let client = WorkloadApiClient::connect_env().await?;
```

---

## X.509 identities

The Workload API client exposes low-level access to X.509 materials.

```rust
use spiffe::{TrustDomain, X509Context};

let context: X509Context = client.fetch_x509_context().await?;

let trust_domain = TrustDomain::new("example.org")?;
let bundle = context
    .bundle_set()
    .get(&trust_domain)
    .ok_or("missing bundle")?;
```

### Watch for updates

```rust
use futures_util::StreamExt;

let mut stream = client.stream_x509_contexts().await?;

while let Some(update) = stream.next().await {
    let context = update?;
    // react to updated SVIDs and bundles
}
```

---

## `X509Source` (recommended)

`X509Source` is a higher-level abstraction built on top of the Workload API.

It maintains a locally cached, automatically refreshed view of X.509 SVIDs and bundles,
handling reconnections and rotations transparently.

```rust
use spiffe::{TrustDomain, X509Source};

let source = X509Source::new().await?;

// Snapshot of current materials
let context = source.x509_context()?;

// Selected SVID (default or picker)
let svid = source.svid()?;

// Bundle for a trust domain
let trust_domain = TrustDomain::new("example.org")?;
let bundle = source
    .bundle_for_trust_domain(&trust_domain)?
    .ok_or("missing bundle")?;
```

For most X.509-based workloads, `X509Source` provides a higher-level API.

---

## `JwtSource` (recommended)

`JwtSource` is a higher-level abstraction built on top of the Workload API for JWT workloads.

It maintains a locally cached, automatically refreshed view of JWT bundles,
handling reconnections and rotations transparently. JWT SVIDs are fetched on-demand
with specific audiences.

```rust
use spiffe::{TrustDomain, JwtSource};

let source = JwtSource::new().await?;

// Fetch JWT SVID for specific audiences
let jwt_svid = source.fetch_jwt_svid(&["service-a", "service-b"]).await?;

// Fetch JWT SVID for a specific SPIFFE ID
let spiffe_id = "spiffe://example.org/my-service".parse()?;
let jwt_svid = source.fetch_jwt_svid_with_id(&["audience"], Some(&spiffe_id)).await?;

// Bundle for a trust domain
let trust_domain = TrustDomain::new("example.org")?;
let bundle = source
    .bundle_for_trust_domain(&trust_domain)?
    .ok_or("missing bundle")?;
```

For most JWT-based workloads, `JwtSource` provides a higher-level API.

---

## SVID hints

When multiple SVIDs are returned by the Workload API, SPIRE may attach an
**operator-defined hint** (for example, `internal` or `external`) to guide selection.

Hints are **not part of the cryptographic identity**. They are metadata
returned by the Workload API and are exposed by this crate for convenience.

* X.509 hints are attached to `X509Svid`
* JWT hints are attached to `JwtSvid`

Higher-level abstractions like `X509Source` preserve hints and allow custom
selection logic via `SvidPicker`.

---

## JWT identities

### Using `JwtSource` (recommended)

For most JWT workloads, use `JwtSource` which provides automatic bundle caching and on-demand SVID fetching:

```rust
use spiffe::JwtSource;

let source = JwtSource::new().await?;

// Fetch JWT SVID
let jwt_svid = source.fetch_jwt_svid(&["audience1", "audience2"]).await?;
```

See the [`JwtSource`](#jwtsource-recommended) section above for more details.

### Direct Workload API access

For direct access without caching, use the Workload API client:

```rust
use spiffe::{SpiffeId, WorkloadApiClient};

let client = WorkloadApiClient::connect_env().await?;

let spiffe_id = SpiffeId::try_from("spiffe://example.org/my-service")?;

let jwt = client
    .fetch_jwt_svid(&["audience1", "audience2"], Some(&spiffe_id))
    .await?;
```

### Fetch and watch JWT bundles

```rust
use futures_util::StreamExt;
use spiffe::TrustDomain;
use spiffe::WorkloadApiClient;

let client = WorkloadApiClient::connect_env().await?;

let bundles = client.fetch_jwt_bundles().await?;
let trust_domain = TrustDomain::try_from("example.org")?;
let bundle = bundles.get(&trust_domain);

let mut stream = client.stream_jwt_bundles().await?;
while let Some(update) = stream.next().await {
    let bundles = update?;
    // react to updated JWT authorities
}
```

---

## JWT verification modes

This crate supports **three distinct JWT-SVID usage patterns**, depending on where
verification happens.

### 1. Trusted by construction (no verification)

JWT-SVIDs **fetched directly from the SPIFFE Workload API** are trusted by construction.
The SPIRE agent already authenticated the workload and issued the token.

```rust
use spiffe::JwtSvid;

let svid = JwtSvid::from_workload_api_token(token_str)?;
```

No additional features are required.

---

### 2. Validation via the Workload API (recommended when available)

The Workload API exposes a validation RPC.
`WorkloadApiClient::validate_jwt_token` delegates verification to the SPIRE agent
and returns a parsed `JwtSvid`.

```rust
use spiffe::WorkloadApiClient;

let client = WorkloadApiClient::connect_env().await?;

let svid = client
    .validate_jwt_token("my-audience", jwt_token)
    .await?;
```

Characteristics:

* Signature verification is performed **by the SPIRE agent**
* No local cryptography required
* **Does not require any JWT verification feature**
* Recommended whenever the Workload API is reachable

---

### 3. Offline verification (explicit backend selection required)

If you need to validate **untrusted JWTs** locally (for example, tokens received
over the network), enable offline JWT verification with an explicit cryptographic
backend.

#### Using the pure-Rust backend (portable, recommended)

```toml
[dependencies]
spiffe = { version = "0.15", features = ["jwt-verify-rust-crypto"] }
```

#### Using the AWS-LC backend

```toml
[dependencies]
spiffe = { version = "0.15", features = ["jwt-verify-aws-lc-rs"] }
```

This enables local signature verification using JWT authorities from bundles:

```rust
use spiffe::JwtSvid;

let svid = JwtSvid::parse_and_validate(
    token_str,
    &bundle_source,
    &["expected-audience"],
)?;
```

Use this mode when:

* The Workload API is not available
* Tokens are received from external peers
* Fully offline validation is required

---

## Features

All features are additive and opt-in. The crate has **no default features** (`default = []`).

### Core features

#### `x509`

Enables X.509 SVID and bundle types plus parsing. Gates heavy ASN.1/X.509 dependencies (`asn1`, `x509-parser`, `pkcs8`).

**Note:** Most users should enable `x509-source` instead, which includes this feature automatically.

#### `transport`

Lightweight endpoint parsing and normalization. No runtime dependencies (pure parsing logic).

#### `transport-grpc`

gRPC connector for Unix/TCP endpoints. Requires `transport` and adds tokio/tonic/tower dependencies.

#### `workload-api`

Enables the async SPIFFE Workload API client. Requires `transport-grpc` and `x509`.

Provides:

* `WorkloadApiClient` and streaming APIs
* X.509 and JWT SVID and bundle retrieval
* Streaming watch semantics
* Agent-side JWT validation (`validate_jwt_token`)

#### `x509-source`

High-level X.509 watcher and caching abstraction. Requires `workload-api` (and transitively `x509`).

Provides:

* `X509Source` for automatic SVID/bundle watching and caching
* Automatic reconnection and rotation handling
* Recommended for most X.509-based workloads

#### `jwt-source`

High-level JWT watcher and caching abstraction. Requires `workload-api` and `jwt`.

Provides:

* `JwtSource` for automatic bundle watching and caching
* On-demand JWT SVID fetching with audience specification
* Automatic reconnection and rotation handling
* Recommended for most JWT-based workloads

#### `jwt`

Enables JWT SVID and bundle types plus parsing. Gates JWT-related dependencies (`serde`, `serde_json`, `time`,
`base64ct`).

**Note:** JWT verification requires an additional backend feature (see below).

---

### JWT verification backends

#### `jwt-verify-rust-crypto`

Enables **offline JWT-SVID verification** using a **pure Rust cryptography backend**.

* Portable and dependency-light
* Recommended default for offline verification
* Required only when validating untrusted JWTs locally

When enabled, [`JwtSvid::parse_and_validate`] performs JWT-SVID validation:

- **Signature verification** using keys from the trust domain's JWT bundle
- **`exp` claim**: tokens must not be expired
- **`aud` claim**: must intersect the `expected_audience` parameter
  (empty audience arrays are rejected)
- **`sub` claim**: must be present and parse as a valid SPIFFE ID
- **`kid` header**: must be present and match a key in the bundle

Note: `nbf`, `iat`, and `iss` claims are not validated. See the
[`JwtSvid::parse_and_validate`] documentation for complete details.

```rust
use spiffe::{BundleSource, JwtBundle, JwtSvid};

fn validate_token<B: BundleSource<Item = JwtBundle>>(
    token: &str,
    bundles: &B,
) -> Result<JwtSvid, spiffe::JwtSvidError> {
    JwtSvid::parse_and_validate(token, bundles, &["my-service"])
}
```

---

### `jwt-verify-aws-lc-rs`

Enables **offline JWT-SVID verification** using **AWS-LC** via `aws-lc-rs`.

* Alternative cryptography backend
* Mutually exclusive with `jwt-verify-rust-crypto`

Validation semantics are identical to `jwt-verify-rust-crypto`; only the cryptographic
backend differs.

---

### Observability features

The crate supports optional observability through two mutually compatible features:
`logging` and `tracing`. Both features are optional and can be enabled independently
or together.

#### Feature precedence

When multiple observability features are enabled, the following precedence applies:

1. **`tracing`** (highest priority) — If enabled, all events are emitted via `tracing`
2. **`logging`** — If `tracing` is not enabled, events are emitted via the `log` crate
3. **No observability** — If neither feature is enabled, observability calls are no-ops

#### `logging`

Enables observability using the [`log`](https://crates.io/crates/log) crate.

This is a lightweight option suitable for applications that use the standard `log`
facade. Events are emitted via `log::debug!`, `log::info!`, `log::warn!`, and `log::error!`.

```toml
[dependencies]
spiffe = { version = "0.15", features = ["logging"] }
```

**Note:** The `logging` feature is not included in the default `workload-api` feature.
You must explicitly enable it if you want log output.

#### `tracing`

Enables structured observability using the [`tracing`](https://crates.io/crates/tracing) crate.

This is recommended for production environments that use structured logs, spans,
or distributed tracing systems. When both `tracing` and `logging` features are enabled,
**`tracing` takes precedence** and all events are emitted via `tracing` macros.

```toml
[dependencies]
spiffe = { version = "0.15", features = ["tracing"] }
```

**Note:** The `tracing` and `logging` features are not mutually exclusive. When both
features are enabled, events are emitted via `tracing`.

---

### Workload API core (advanced)

In addition to the higher-level bundles (`workload-api-x509`, `workload-api-jwt`,
`workload-api`), the crate exposes a lower-level
`workload-api-core` feature:

```toml
[dependencies]
spiffe = { version = "0.15", features = ["workload-api-core"] }
```

This feature includes:

- **Transport layer** (`transport-grpc`): endpoint parsing and gRPC connector
- **Runtime dependencies**: `tokio`, `tonic`, `tokio-stream`, `tokio-util`
- **Protobuf types**: generated Workload API message definitions

**Excluded** (not included in `workload-api-core`):

- X.509 parsing (`x509` feature)
- JWT parsing (`jwt` feature)
- High-level client methods that require parsed SVIDs/bundles

Use `workload-api-core` if you want to build a custom client or integrate with
alternative SVID/bundle representations while reusing the transport layer.

---

### Notes on JWT verification features

* Each backend feature (`jwt-verify-rust-crypto`, `jwt-verify-aws-lc-rs`) is self-contained and automatically includes
  the `jwt` feature
* Exactly **one** offline verification backend must be selected (mutually exclusive)
* Offline verification features are **not required** when using `WorkloadApiClient::validate_jwt_token`
* X.509-based functionality is unaffected by JWT verification features

---

## Performance

Performance characteristics:

- **Zero-copy parsing** where possible (X.509 DER, JWT parsing)
- **Atomic updates** in `X509Source` and `JwtSource` (no locks on read path)
- **Streaming APIs** for real-time updates without polling
- **Minimal allocations** in hot paths

The `X509Source` and `JwtSource` maintain cached views of SVIDs and bundles, updating atomically when the Workload API delivers new
material. This eliminates the need for polling and ensures new handshakes always use the latest credentials.

---

## Architecture

The crate is organized into several layers:

1. **Core primitives** (`SpiffeId`, `TrustDomain`) — Always available, no dependencies
2. **Transport layer** (`transport`, `transport-grpc`) — Endpoint parsing and gRPC connectivity
3. **Workload API client** (`workload-api-*`) — Low-level client for SPIFFE Workload API
4. **High-level abstractions** (`x509-source`, `jwt-source`) — Automatic caching and rotation handling

This layered design allows you to use only what you need, minimizing dependencies and compile times.

---

## Troubleshooting

### Common Issues

#### "Workload API connection failed"

- **Cause**: SPIRE agent not running or socket path incorrect
- **Solution**: Verify `SPIFFE_ENDPOINT_SOCKET` environment variable or socket path

#### "Empty response from Workload API"

- **Cause**: Workload not registered with SPIRE agent
- **Solution**: Ensure your workload is properly attested and registered

---

## Security Best Practices

- **Always validate JWT tokens** when received from untrusted sources (use `jwt-verify-*` features)
- **Use `X509Source` or `JwtSource`** for automatic rotation instead of manual polling
- **Enable observability** (`logging` or `tracing`) in production for monitoring

For security vulnerabilities, see [SECURITY.md](../SECURITY.md).

### Dependency advisories (cargo audit)

This project runs `cargo audit` in CI. Some advisories may appear only when enabling optional features
(e.g., offline JWT verification). At the time of writing, `cargo audit` may report `RUSTSEC-2023-0071`
(the `rsa` crate “Marvin Attack” advisory) via `jsonwebtoken`, and there is currently no fixed upgrade
available upstream.

If you require a clean audit, avoid enabling offline JWT verification unless needed, or temporarily ignore
the advisory until upstream releases a fix.

## License

Licensed under the Apache License, Version 2.0.
See [LICENSE](../LICENSE) for details.
