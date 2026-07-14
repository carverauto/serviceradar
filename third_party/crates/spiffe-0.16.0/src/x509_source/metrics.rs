use super::errors::MetricsErrorKind;

/// Trait for recording metrics from `X509Source`.
///
/// Implement this trait to integrate with your metrics system (e.g., Prometheus, `StatsD`).
/// Prefer stable, low-cardinality labels when recording metrics.
/// Implementations must not panic.
///
/// # Example
///
/// ```no_run
/// use spiffe::x509_source::{MetricsErrorKind, MetricsRecorder};
/// use std::sync::Arc;
///
/// struct MyMetrics;
///
/// impl MetricsRecorder for MyMetrics {
///     fn record_update(&self) {
///         // Record update metric
///     }
///
///     fn record_reconnect(&self) {
///         // Record reconnect metric
///     }
///
///     fn record_error(&self, kind: MetricsErrorKind) {
///         // Record error metric with kind label
///         println!("Error: {}", kind.as_str());
///     }
/// }
///
/// let metrics = Arc::new(MyMetrics);
/// // Use with X509SourceBuilder::with_metrics()
/// ```
pub trait MetricsRecorder: Send + Sync {
    /// Records that an X.509 context update occurred.
    fn record_update(&self);

    /// Records that a reconnection attempt is about to occur.
    ///
    /// This metric is recorded exactly once per backoff sleep cycle in steady-state
    /// operation (not during initial sync). It indicates that the source is about to
    /// sleep/backoff and retry after a failure in steady-state operation.
    ///
    /// **Note:** This is NOT recorded during initial synchronization, which uses
    /// the `InitialSyncFailed` umbrella metric instead.
    fn record_reconnect(&self);

    /// Records an error with a structured error kind.
    fn record_error(&self, kind: MetricsErrorKind);
}
