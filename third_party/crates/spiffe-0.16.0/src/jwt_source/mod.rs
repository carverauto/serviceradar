//! JWT Source: high-level watcher/caching abstraction for JWT bundles.
//!
//! Provides the [`JwtSource`] type and related configuration types
//! for automatic JWT bundle watching and caching, plus on-demand JWT SVID fetching.
//!
//! Available with the `jwt-source` feature.
//!
//! `JwtSource` performs an initial synchronization before becoming usable, then watches the
//! Workload API for bundle rotations. Transient failures are handled by reconnecting with backoff.
//!
//! Unlike X.509 SVIDs which are streamed continuously, JWT SVIDs are fetched on-demand with
//! specific audiences. Use [`JwtSource::fetch_jwt_svid`] to fetch JWT SVIDs as needed.
//!
//! Use [`JwtSource::updated`] to subscribe to bundle change notifications, and [`JwtSource::shutdown`]
//! to stop background tasks.
//!
//! Primary types are re-exported at the crate root. For advanced configuration types
//! (e.g., `LimitKind`, `MetricsErrorKind`, `MetricsRecorder`), import from this module.
//!
//! # Example
//!
//! ```no_run
//! # #[cfg(feature = "jwt-source")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use spiffe::{TrustDomain, JwtSource};
//! use spiffe::BundleSource;
//!
//! let source = JwtSource::new().await?;
//!
//! // Fetch a JWT SVID for a specific audience
//! let jwt_svid = source.fetch_jwt_svid(&["service-a", "service-b"]).await?;
//!
//! let td = TrustDomain::new("example.org")?;
//! let bundle = source
//!     .bundle_for_trust_domain(&td)?
//!     .ok_or("missing bundle")?;
//!
//! # Ok(())
//! # }
//! ```

mod builder;
mod errors;
mod limits;
mod metrics;
mod source;
mod supervisor;
mod types;

pub use builder::{JwtSourceBuilder, ReconnectConfig, ResourceLimits};
pub use errors::{JwtSourceError, LimitKind, MetricsErrorKind};
pub use metrics::MetricsRecorder;
pub use source::{JwtSource, JwtSourceUpdates};
