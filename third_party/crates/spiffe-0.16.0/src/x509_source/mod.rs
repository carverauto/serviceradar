//! X.509 Source: high-level watcher/caching abstraction.
//!
//! Provides the [`X509Source`] type and related configuration types
//! for automatic SVID/bundle watching and caching.
//!
//! Available with the `x509-source` feature.
//!
//! `X509Source` performs an initial synchronization before becoming usable, then watches the
//! Workload API for rotations. Transient failures are handled by reconnecting with backoff.
//!
//! If multiple X.509 SVIDs are available, `X509Source` selects one using the configured picker
//! (or the Workload API "default" SVID if no picker is set).
//!
//! Use [`X509Source::updated`] to subscribe to change notifications, and [`X509Source::shutdown`]
//! to stop background tasks.
//!
//! Primary types are re-exported at the crate root. For advanced configuration types
//! (e.g., `LimitKind`, `MetricsErrorKind`, `MetricsRecorder`), import from this module.
//!
//! # Example
//!
//! ```no_run
//! # #[cfg(feature = "x509-source")]
//! # async fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
//! use spiffe::{TrustDomain, X509Source};
//! use spiffe::BundleSource;
//!
//! let source = X509Source::new().await?;
//!
//! // Selected SVID (default or picker).
//! let svid = source.svid()?;
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

pub use builder::{ReconnectConfig, ResourceLimits, X509SourceBuilder};
pub use errors::{LimitKind, MetricsErrorKind, X509SourceError};
pub use metrics::MetricsRecorder;
pub use source::{X509Source, X509SourceUpdates};
pub use types::SvidPicker;
