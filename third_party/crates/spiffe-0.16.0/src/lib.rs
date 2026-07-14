//! Client library for the [SPIFFE Workload API](https://github.com/spiffe/spiffe/blob/main/standards/SPIFFE_Workload_API.md).
//!
//! Provides standards-compliant access to SPIFFE identities and trust material.
//! Supports fetching and watching X.509 and JWT SVIDs and trust bundles using
//! strongly typed APIs aligned with the SPIFFE specifications.
//!
//! ## Quick Start
//!
//! For X.509-based workloads, use [`X509Source`] (requires the `x509-source` feature):
//!
//! ```no_run
//! # #[cfg(feature = "x509-source")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use spiffe::{BundleSource, TrustDomain, X509Source};
//!
//! let source = X509Source::new().await?;
//! let _svid = source.svid()?;
//! let trust_domain = TrustDomain::try_from("example.org")?;
//! let _bundle = source
//!     .bundle_for_trust_domain(&trust_domain)?
//!     .ok_or("missing bundle")?;
//! # Ok(())
//! # }
//! ```
//!
//! For JWT-based workloads, use [`JwtSource`] (requires the `jwt-source` feature):
//!
//! ```no_run
//! # #[cfg(feature = "jwt-source")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use spiffe::{BundleSource, TrustDomain, JwtSource};
//!
//! let source = JwtSource::new().await?;
//! let _jwt_svid = source.fetch_jwt_svid(&["service-a", "service-b"]).await?;
//! let trust_domain = TrustDomain::try_from("example.org")?;
//! let _bundle = source
//!     .bundle_for_trust_domain(&trust_domain)?
//!     .ok_or("missing bundle")?;
//! # Ok(())
//! # }
//! ```
//!
//! For direct Workload API access, use [`WorkloadApiClient`] (requires a `workload-api-*` feature):
//!
//! ```no_run
//! # #[cfg(feature = "workload-api-jwt")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use spiffe::WorkloadApiClient;
//!
//! let client = WorkloadApiClient::connect_env().await?;
//! let _jwt_svid = client.fetch_jwt_svid(&["audience"], None).await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Feature Matrix
//!
//! The crate has **no default features** — everything is opt-in.
//!
//! Most users should enable `x509-source` (for X.509 workloads), `jwt-source` (for JWT workloads),
//! or a `workload-api-*` bundle (for direct Workload API access). The granular features exist to
//! let you minimize dependency surface when you only need X.509 or only need JWT.
//!
//! | Feature | Description |
//! |---------|-------------|
//! | `x509` | X.509 SVID and bundle types + parsing (gates heavy ASN.1/X.509 deps) |
//! | `transport` | Endpoint parsing (no runtime deps) |
//! | `transport-grpc` | gRPC connector |
//! | `jwt` | JWT SVID and bundle types + parsing |
//! | `jwt-verify-rust-crypto` | Offline JWT verification (rust-crypto backend) |
//! | `jwt-verify-aws-lc-rs` | Offline JWT verification (aws-lc-rs backend) |
//! | `logging` | Log-based observability |
//! | `tracing` | Tracing-based observability |
//!
//! ### Workload API bundles
//!
//! These features enable the async Workload API client (`WorkloadApiClient`). Choose the smallest
//! bundle that matches your use case:
//!
//! | Feature | Includes |
//! |---------|----------|
//! | `workload-api-x509` | Workload API client + X.509 support (no JWT) |
//! | `workload-api-jwt` | Workload API client + JWT support (no X.509) |
//! | `workload-api` | Workload API client with both X.509 + JWT support |
//!
//! ### Advanced / compositional
//!
//! | Feature | Description |
//! |---------|-------------|
//! | `workload-api-core` | Workload API infrastructure only (transport/proto/client plumbing; no X.509/JWT parsing/types) |
//! | `x509-source` | High-level X.509 watcher/caching built on the Workload API |
//! | `jwt-source` | High-level JWT watcher/caching built on the Workload API |
//!
//! **Notes:**
//!
//! - The `x509` feature gates heavy X.509 parsing dependencies.
//! - For direct Workload API usage, use `workload-api-x509` or `workload-api-jwt` when you only need one,
//!   and `workload-api` when you need both.
//!
//! For advanced configuration, see the [`x509_source`] and [`jwt_source`] modules.

// "logging" and "tracing" can both be enabled, causing logging to be unused.
//
// "workload-api" can be enabled without "x509-source" or "jwt-source", causing
// arc-swap, fastrand, and tokio-util to be unused.
//
// There are probably others.
#![allow(
    unused_crate_dependencies,
    reason = "optional dependencies and features are not well factored"
)]

pub mod bundle;
#[cfg(feature = "x509")]
pub mod cert;
pub mod constants;
pub mod spiffe_id;
pub mod svid;

mod observability;
mod prelude;

/// Transport primitives (endpoint parsing, optional gRPC connector).
///
/// Enabled with `transport` (parsing only) or `transport-grpc` (parsing + gRPC connector).
#[cfg(any(feature = "transport", feature = "transport-grpc"))]
pub mod transport;

// Compile-time guards for feature combinations
#[cfg(all(feature = "jwt-verify-rust-crypto", feature = "jwt-verify-aws-lc-rs"))]
compile_error!(
    "Cannot enable both JWT verification backends simultaneously. \
     Choose exactly one: `jwt-verify-rust-crypto` or `jwt-verify-aws-lc-rs`."
);

#[cfg(any(feature = "workload-api-x509", feature = "workload-api-jwt"))]
pub mod workload_api;

#[cfg(feature = "x509-source")]
pub mod x509_source;

#[cfg(feature = "jwt-source")]
pub mod jwt_source;

// Core identifiers
pub use crate::spiffe_id::{SpiffeId, SpiffeIdError, TrustDomain};

// SVIDs
#[cfg(feature = "jwt")]
pub use crate::svid::jwt::{JwtSvid, JwtSvidError};
#[cfg(feature = "x509")]
pub use crate::svid::x509::{X509Svid, X509SvidError};

// Bundles
#[cfg(feature = "jwt")]
pub use crate::bundle::jwt::{JwtBundle, JwtBundleError, JwtBundleSet};
#[cfg(feature = "x509")]
pub use crate::bundle::x509::{X509Bundle, X509BundleError, X509BundleSet};

// Certificate and private key types
#[cfg(feature = "x509")]
pub use crate::cert::{Certificate, PrivateKey};

// Source traits
pub use crate::bundle::BundleSource;
pub use crate::svid::SvidSource;

// Workload API - Common types
//
// WorkloadApiClient and X509Context. Available with `workload-api` feature.
#[cfg(feature = "workload-api-x509")]
pub use crate::workload_api::X509Context;
#[cfg(any(feature = "workload-api-x509", feature = "workload-api-jwt"))]
pub use crate::workload_api::{InterceptorFn, WorkloadApiClient, WorkloadApiError};

// X.509 Source
//
// High-level watcher/caching abstraction. Available with `x509-source` feature.
// Primary types are re-exported at the crate root. Configuration types are re-exported with
// `X509`-prefixed names (mirroring the `Jwt`-prefixed JWT aliases) so the two sources do not
// collide at the crate root; the unprefixed names remain available via the [`x509_source`] module.
#[cfg(feature = "x509-source")]
pub use crate::x509_source::{
    ReconnectConfig as X509ReconnectConfig, ResourceLimits as X509ResourceLimits, X509Source,
    X509SourceBuilder, X509SourceError, X509SourceUpdates,
};

// JWT Source
//
// High-level watcher/caching abstraction for JWT bundles. Available with `jwt-source` feature.
// Primary types are re-exported at the crate root. Configuration types are re-exported with
// `Jwt`-prefixed names (mirroring the `X509`-prefixed X.509 aliases) so the two sources do not
// collide at the crate root; the unprefixed names remain available via the [`jwt_source`] module.
#[cfg(feature = "jwt-source")]
pub use crate::jwt_source::{
    JwtSource, JwtSourceBuilder, JwtSourceError, JwtSourceUpdates,
    ReconnectConfig as JwtReconnectConfig, ResourceLimits as JwtResourceLimits,
};
