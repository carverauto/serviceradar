use crate::workload_api::error::WorkloadApiError;
use std::fmt;
use thiserror::Error;

/// Errors returned by `JwtSource`.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum JwtSourceError {
    /// Failed to retrieve or refresh JWT material from the source.
    #[error("jwt source error: {0}")]
    Source(#[from] WorkloadApiError),

    /// Failed to fetch a JWT SVID.
    ///
    /// This can occur when:
    /// - The Workload API returns no SVIDs for the requested audience
    /// - The SVID cannot be parsed
    #[error("failed to fetch jwt svid: {0}")]
    FetchJwtSvid(WorkloadApiError),

    /// The source was closed.
    #[error("source is closed")]
    Closed,

    /// Initial synchronization timeout exceeded.
    ///
    /// This error occurs when `JwtSourceBuilder::initial_sync_timeout()` is configured
    /// and the initial synchronization performed during source construction does not
    /// complete within the specified timeout.
    #[error("initial synchronization timed out")]
    InitialSyncTimeout,

    /// The workload API stream ended.
    ///
    /// This error occurs when the gRPC stream from the Workload API terminates
    /// normally (returns `None`). This is distinct from `Source(WorkloadApiError)`,
    /// which represents actual errors during stream operations.
    ///
    /// **When this occurs:**
    /// - The stream reaches end-of-stream (normal termination)
    /// - The connection is closed by the server
    ///
    /// **Not to be confused with:**
    /// - `Source(WorkloadApiError::EmptyResponse)` - occurs when the API returns
    ///   empty data, not when the stream ends
    /// - `Source(WorkloadApiError::Transport(...))` - occurs for transport-level errors
    #[error("workload api stream ended")]
    StreamEnded,

    /// Resource limit exceeded.
    ///
    /// This error indicates that a received JWT bundle set exceeds one of the configured
    /// resource limits. The error includes the kind of limit, the configured limit, and
    /// the actual value that exceeded it.
    #[error("resource limit exceeded: {kind} (limit={limit}, actual={actual})")]
    ResourceLimitExceeded {
        /// The kind of limit that was exceeded.
        kind: LimitKind,
        /// The configured limit value.
        limit: usize,
        /// The actual value that exceeded the limit.
        actual: usize,
    },

    /// Shutdown timeout exceeded.
    ///
    /// This error occurs when `shutdown_with_timeout()` is called and the background
    /// tasks do not complete within the specified timeout.
    #[error("shutdown timeout exceeded")]
    ShutdownTimeout,
}

/// The kind of resource limit that was exceeded.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum LimitKind {
    /// Maximum number of bundles exceeded.
    MaxBundles,
    /// Maximum bundle JWKS bytes exceeded.
    MaxBundleJwksBytes,
}

impl LimitKind {
    /// Returns a stable string representation of the limit kind.
    ///
    /// This is useful for error messages, metrics labels, and logging.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::MaxBundles => "max_bundles",
            Self::MaxBundleJwksBytes => "max_bundle_jwks_bytes",
        }
    }
}

impl fmt::Display for LimitKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Error kinds for structured metrics reporting.
///
/// Use these stable, low-cardinality labels when recording metrics.
#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash)]
pub enum MetricsErrorKind {
    /// Failed to create a Workload API client.
    ClientCreation,
    /// Failed to connect to the Workload API stream.
    StreamConnect,
    /// Error occurred while reading from the stream.
    StreamError,
    /// The Workload API stream ended unexpectedly.
    StreamEnded,
    /// Initial synchronization with the Workload API failed.
    InitialSyncFailed,
    /// Resource limit exceeded: maximum bundle count.
    LimitMaxBundles,
    /// Resource limit exceeded: maximum bundle JWKS bytes.
    LimitMaxBundleJwksBytes,
    /// A JWT bundle set update was rejected (validation failed).
    UpdateRejected,
    /// Failed to join supervisor task during shutdown.
    SupervisorJoinFailed,
}

impl MetricsErrorKind {
    /// Returns a string representation of the error kind.
    ///
    /// This is useful for metrics systems that require string labels.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ClientCreation => "client_creation",
            Self::StreamConnect => "stream_connect",
            Self::StreamError => "stream_error",
            Self::StreamEnded => "stream_ended",
            Self::InitialSyncFailed => "initial_sync_failed",
            Self::LimitMaxBundles => "limit_max_bundles",
            Self::LimitMaxBundleJwksBytes => "limit_max_bundle_jwks_bytes",
            Self::UpdateRejected => "update_rejected",
            Self::SupervisorJoinFailed => "supervisor_join_failed",
        }
    }
}

impl fmt::Display for MetricsErrorKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
