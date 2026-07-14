use super::errors::X509SourceError;
use super::metrics::MetricsRecorder;
use super::source::X509Source;
use crate::workload_api::WorkloadApiClient;
use crate::x509_source::types::{ClientFactory, SvidPicker};
use std::fmt::Debug;
use std::sync::Arc;
use std::time::Duration;

/// Reconnect/backoff configuration.
///
/// When the Workload API connection fails, the source will retry with exponential
/// backoff between `min_backoff` and `max_backoff`. The backoff includes small jitter
/// to prevent synchronized reconnect storms in high-concurrency scenarios.
///
/// If `min_backoff > max_backoff`, they will be swapped to ensure valid configuration.
#[non_exhaustive]
#[derive(Clone, Copy, Debug)]
pub struct ReconnectConfig {
    /// Initial delay before retrying.
    pub min_backoff: Duration,
    /// Maximum delay between retries.
    pub max_backoff: Duration,
}

impl Default for ReconnectConfig {
    fn default() -> Self {
        Self {
            min_backoff: Duration::from_millis(200),
            max_backoff: Duration::from_secs(10),
        }
    }
}

impl ReconnectConfig {
    /// Creates a `ReconnectConfig` with explicit backoff bounds.
    ///
    /// `min_backoff` is the initial retry delay and `max_backoff` is the cap. If
    /// `min_backoff > max_backoff`, the values are swapped when the source is built.
    #[must_use]
    pub const fn new(min_backoff: Duration, max_backoff: Duration) -> Self {
        Self {
            min_backoff,
            max_backoff,
        }
    }

    /// Normalizes the configuration to ensure `min_backoff <= max_backoff`.
    ///
    /// If `min_backoff > max_backoff`, they are swapped. This ensures valid
    /// configuration regardless of how the config was constructed.
    pub(crate) fn normalize(mut self) -> Self {
        if self.min_backoff > self.max_backoff {
            std::mem::swap(&mut self.min_backoff, &mut self.max_backoff);
        }
        self
    }
}

/// Normalizes a `ReconnectConfig` to ensure `min_backoff <= max_backoff`.
///
/// This is the single authoritative normalization function used by `X509Source::new_with()`.
/// All construction paths should normalize through this function to ensure consistency.
pub(super) fn normalize_reconnect(reconnect: ReconnectConfig) -> ReconnectConfig {
    reconnect.normalize()
}

/// Resource limits for defense-in-depth security.
///
/// These are best-effort limits intended to prevent accidental or malicious resource exhaustion.
/// Limits are enforced before a new context is published to consumers.
///
/// Use `None` for unlimited (no limit enforced), or `Some(usize)` for a specific limit.
///
/// # Examples
///
/// ```rust
/// use spiffe::X509ResourceLimits;
///
/// // Limited resources
/// let limits = X509ResourceLimits::new(
///     Some(100),
///     Some(200),
///     Some(4 * 1024 * 1024), // 4MB
/// );
///
/// // Unlimited (no limits enforced)
/// let unlimited = X509ResourceLimits::unlimited();
///
/// // Mixed (some limits, some unlimited)
/// let mixed = X509ResourceLimits::new(
///     Some(50),
///     None, // Unlimited bundles
///     Some(1024 * 1024), // 1MB
/// );
/// ```
#[non_exhaustive]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResourceLimits {
    /// Maximum number of SVIDs allowed in a context.
    ///
    /// `None` means unlimited (no limit enforced).
    pub max_svids: Option<usize>,
    /// Maximum number of bundles allowed in a bundle set.
    ///
    /// `None` means unlimited (no limit enforced).
    pub max_bundles: Option<usize>,
    /// Maximum bundle DER size in bytes (per bundle).
    ///
    /// Definition: for each bundle, this is the sum of DER byte lengths of all
    /// authority certificates contained in that bundle. The limit is enforced
    /// independently per bundle.
    ///
    /// `None` means unlimited (no limit enforced).
    pub max_bundle_der_bytes: Option<usize>,
}

impl Default for ResourceLimits {
    fn default() -> Self {
        Self {
            // Conservative defaults; typical workloads are far below these.
            max_svids: Some(100),
            max_bundles: Some(200),
            max_bundle_der_bytes: Some(4 * 1024 * 1024), // 4MB
        }
    }
}

impl ResourceLimits {
    /// Creates a `ResourceLimits` with explicit limits.
    ///
    /// Use `None` for unlimited (no limit enforced), or `Some(usize)` for a
    /// specific limit.
    #[must_use]
    pub const fn new(
        max_svids: Option<usize>,
        max_bundles: Option<usize>,
        max_bundle_der_bytes: Option<usize>,
    ) -> Self {
        Self {
            max_svids,
            max_bundles,
            max_bundle_der_bytes,
        }
    }

    /// Creates a `ResourceLimits` with all limits set to unlimited (no limits enforced).
    ///
    /// # Examples
    ///
    /// ```rust
    /// use spiffe::X509ResourceLimits;
    ///
    /// let unlimited = X509ResourceLimits::unlimited();
    /// assert_eq!(unlimited.max_svids, None);
    /// assert_eq!(unlimited.max_bundles, None);
    /// assert_eq!(unlimited.max_bundle_der_bytes, None);
    /// ```
    pub const fn unlimited() -> Self {
        Self {
            max_svids: None,
            max_bundles: None,
            max_bundle_der_bytes: None,
        }
    }

    /// Creates a `ResourceLimits` with default conservative limits.
    ///
    /// This is equivalent to `ResourceLimits::default()` but provided for clarity.
    ///
    /// # Examples
    ///
    /// ```rust
    /// use spiffe::X509ResourceLimits;
    ///
    /// let limits = X509ResourceLimits::default_limits();
    /// assert_eq!(limits.max_svids, Some(100));
    /// assert_eq!(limits.max_bundles, Some(200));
    /// ```
    pub fn default_limits() -> Self {
        Self::default()
    }
}

/// Builder for [`X509Source`].
///
/// Use this when you need explicit configuration (socket path, picker, backoff, resource limits).
/// By default, `build()` waits until initial synchronization succeeds or returns a
/// non-retryable error according to the source's existing behavior. Use
/// [`X509SourceBuilder::initial_sync_timeout`] to opt into bounding only that construction-time
/// initial sync.
///
/// # Example
///
/// ```no_run
/// use spiffe::{X509ResourceLimits, X509Source, X509SourceBuilder};
/// use std::time::Duration;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let source = X509Source::builder()
///     .endpoint("unix:/tmp/spire-agent/public/api.sock")
///     .reconnect_backoff(Duration::from_secs(1), Duration::from_secs(30))
///     .resource_limits(X509ResourceLimits::new(
///         Some(100),
///         Some(500),
///         Some(5 * 1024 * 1024),
///     ))
///     .build()
///     .await?;
/// # Ok(())
/// # }
/// ```
pub struct X509SourceBuilder {
    svid_picker: Option<Box<dyn SvidPicker>>,
    reconnect: ReconnectConfig,
    make_client: Option<ClientFactory>,
    limits: ResourceLimits,
    metrics: Option<Arc<dyn MetricsRecorder>>,
    shutdown_timeout: Option<Duration>,
    initial_sync_timeout: Option<Duration>,
}

impl Debug for X509SourceBuilder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("X509SourceBuilder")
            .field(
                "svid_picker",
                &self.svid_picker.as_ref().map(|_| "<SvidPicker>"),
            )
            .field("reconnect", &self.reconnect)
            .field("limits", &self.limits)
            .field(
                "make_client",
                &self.make_client.as_ref().map(|_| "<ClientFactory>"),
            )
            .field(
                "metrics",
                &self.metrics.as_ref().map(|_| "<MetricsRecorder>"),
            )
            .field("shutdown_timeout", &self.shutdown_timeout)
            .field("initial_sync_timeout", &self.initial_sync_timeout)
            .finish()
    }
}

impl Default for X509SourceBuilder {
    fn default() -> Self {
        Self::new()
    }
}

impl X509SourceBuilder {
    /// Creates a new `X509SourceBuilder`.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509SourceBuilder;
    /// # use std::time::Duration;
    ///
    /// let builder = X509SourceBuilder::new()
    ///     .endpoint("unix:/tmp/spire-agent/public/api.sock")
    ///     .reconnect_backoff(Duration::from_secs(1), Duration::from_secs(30));
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn new() -> Self {
        Self {
            svid_picker: None,
            reconnect: ReconnectConfig::default(),
            make_client: None,
            limits: ResourceLimits::default(),
            metrics: None,
            shutdown_timeout: Some(Duration::from_secs(30)),
            initial_sync_timeout: None,
        }
    }

    /// Sets the Workload API endpoint.
    ///
    /// Accepts either a filesystem path (e.g. `/tmp/spire-agent/public/api.sock`)
    /// or a full URI (e.g. `unix:///tmp/spire-agent/public/api.sock`).
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509SourceBuilder;
    ///
    /// let builder = X509SourceBuilder::new()
    ///     .endpoint("unix:/tmp/spire-agent/public/api.sock");
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    #[must_use]
    pub fn endpoint(mut self, endpoint: impl AsRef<str>) -> Self {
        let endpoint: Arc<str> = Arc::from(endpoint.as_ref());

        let factory: ClientFactory = Arc::new(move || {
            let endpoint = Arc::clone(&endpoint);
            Box::pin(async move { WorkloadApiClient::connect_to(&endpoint).await })
        });

        self.make_client = Some(factory);
        self
    }

    /// Sets a custom client factory.
    #[must_use]
    pub fn client_factory(mut self, factory: ClientFactory) -> Self {
        self.make_client = Some(factory);
        self
    }

    /// Sets a custom SVID selection strategy.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # #[cfg(feature = "x509-source")]
    /// # fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    /// use std::sync::Arc;
    ///
    /// use spiffe::x509_source::{SvidPicker, X509SourceBuilder};
    /// use spiffe::X509Svid;
    ///
    /// #[derive(Debug)]
    /// struct HintPicker {
    ///     hint: String,
    /// }
    ///
    /// impl SvidPicker for HintPicker {
    ///     fn pick_svid(&self, svids: &[Arc<X509Svid>]) -> Option<usize> {
    ///         svids
    ///             .iter()
    ///             .position(|svid: &Arc<X509Svid>| svid.hint() == Some(self.hint.as_str()))
    ///     }
    /// }
    ///
    /// let _builder = X509SourceBuilder::new()
    ///     .picker(HintPicker {
    ///         hint: "internal".to_string(),
    ///     });
    /// # Ok(())
    /// # }
    /// ```
    #[must_use]
    pub fn picker<P>(mut self, picker: P) -> Self
    where
        P: SvidPicker + 'static,
    {
        self.svid_picker = Some(Box::new(picker));
        self
    }

    /// Sets the reconnect backoff range.
    ///
    /// When the Workload API connection fails, the source will retry with exponential
    /// backoff between `min_backoff` and `max_backoff`.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509SourceBuilder;
    /// use std::time::Duration;
    ///
    /// let builder = X509SourceBuilder::new()
    ///     .reconnect_backoff(Duration::from_secs(1), Duration::from_secs(60));
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    #[must_use]
    pub const fn reconnect_backoff(mut self, min_backoff: Duration, max_backoff: Duration) -> Self {
        // Normalization happens at the authoritative boundary in X509Source::new_with().
        // This setter stores the raw values; normalization ensures min <= max.
        self.reconnect = ReconnectConfig::new(min_backoff, max_backoff);
        self
    }

    /// Sets resource limits for defense-in-depth security.
    ///
    /// These limits prevent resource exhaustion from malicious or misconfigured agents.
    /// Default limits are reasonable for most use cases.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{X509ResourceLimits, X509SourceBuilder};
    ///
    /// let limits = X509ResourceLimits::new(
    ///     Some(50),
    ///     Some(500),
    ///     Some(5 * 1024 * 1024), // 5MB
    /// );
    /// let builder = X509SourceBuilder::new().resource_limits(limits);
    ///
    /// // Or disable limits:
    /// let unlimited = X509ResourceLimits::unlimited();
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    #[must_use]
    pub const fn resource_limits(mut self, limits: ResourceLimits) -> Self {
        self.limits = limits;
        self
    }

    /// Sets an optional metrics recorder for observability.
    ///
    /// The metrics recorder will be called to record updates, reconnections, and errors.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{X509SourceBuilder, x509_source::{MetricsErrorKind, MetricsRecorder}};
    /// use std::sync::Arc;
    ///
    /// struct MyMetrics;
    ///
    /// impl MetricsRecorder for MyMetrics {
    ///     fn record_update(&self) { /* ... */ }
    ///     fn record_reconnect(&self) { /* ... */ }
    ///     fn record_error(&self, _kind: MetricsErrorKind) { /* ... */ }
    /// }
    ///
    /// let metrics = Arc::new(MyMetrics);
    /// let builder = X509SourceBuilder::new().metrics(metrics);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    #[must_use]
    pub fn metrics(mut self, metrics: Arc<dyn MetricsRecorder>) -> Self {
        self.metrics = Some(metrics);
        self
    }

    /// Sets the shutdown timeout.
    ///
    /// When `shutdown_with_timeout()` or `shutdown_configured()` is called, it will wait
    /// at most this duration for background tasks to complete. If `None`, shutdown will
    /// wait indefinitely (same as `shutdown()`).
    ///
    /// Default is 30 seconds.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509SourceBuilder;
    /// use std::time::Duration;
    ///
    /// let builder = X509SourceBuilder::new()
    ///     .shutdown_timeout(Some(Duration::from_secs(10)));
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    #[must_use]
    pub const fn shutdown_timeout(mut self, timeout: Option<Duration>) -> Self {
        self.shutdown_timeout = timeout;
        self
    }

    /// Sets an optional timeout for the initial synchronization performed by `build()`.
    ///
    /// By default this is `None`, preserving the existing behavior: source construction waits
    /// until initial sync succeeds or returns a non-retryable error according to the source's
    /// existing retry behavior.
    ///
    /// When configured, the timeout bounds only the initial sync performed during source
    /// construction. It does not bound future background reconnects or update retries after the
    /// source has been constructed.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509SourceBuilder;
    /// use std::time::Duration;
    ///
    /// let builder = X509SourceBuilder::new()
    ///     .initial_sync_timeout(Duration::from_secs(10));
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    #[must_use]
    pub const fn initial_sync_timeout(mut self, timeout: Duration) -> Self {
        self.initial_sync_timeout = Some(timeout);
        self
    }

    /// Builds a ready-to-use [`X509Source`].
    ///
    /// On success, the returned source has completed an initial synchronization with
    /// the Workload API and will continue updating in the background.
    ///
    /// # Errors
    ///
    /// Returns an [`X509SourceError`] if the Workload API endpoint cannot be resolved
    /// or connected to, the initial synchronization fails or times out, or no suitable
    /// X.509 SVID can be selected.
    pub async fn build(self) -> Result<X509Source, X509SourceError> {
        let make_client = self.make_client.unwrap_or_else(|| {
            Arc::new(|| Box::pin(async { WorkloadApiClient::connect_env().await }))
        });

        X509Source::build_with(
            make_client,
            self.svid_picker,
            self.reconnect,
            self.limits,
            self.metrics,
            self.shutdown_timeout,
            self.initial_sync_timeout,
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconnect_config_normalization() {
        // Test that normalization swaps min/max when min > max
        let config = ReconnectConfig {
            min_backoff: Duration::from_secs(10),
            max_backoff: Duration::from_secs(1),
        };
        let normalized = config.normalize();
        assert_eq!(normalized.min_backoff, Duration::from_secs(1));
        assert_eq!(normalized.max_backoff, Duration::from_secs(10));

        // Test that normalization preserves valid config
        let config = ReconnectConfig {
            min_backoff: Duration::from_millis(200),
            max_backoff: Duration::from_secs(10),
        };
        let normalized = config.normalize();
        assert_eq!(normalized.min_backoff, Duration::from_millis(200));
        assert_eq!(normalized.max_backoff, Duration::from_secs(10));

        // Test that normalization handles equal values
        let config = ReconnectConfig {
            min_backoff: Duration::from_secs(5),
            max_backoff: Duration::from_secs(5),
        };
        let normalized = config.normalize();
        assert_eq!(normalized.min_backoff, Duration::from_secs(5));
        assert_eq!(normalized.max_backoff, Duration::from_secs(5));
    }

    #[test]
    fn reconnect_config_setter_does_not_normalize() {
        // Test that reconnect_backoff is a pure setter and does NOT normalize.
        // Normalization happens at the authoritative boundary in X509Source::new_with().
        let builder = X509SourceBuilder::new()
            .reconnect_backoff(Duration::from_secs(10), Duration::from_secs(1));
        // Builder stores raw values; normalization happens later at the boundary
        assert_eq!(builder.reconnect.min_backoff, Duration::from_secs(10));
        assert_eq!(builder.reconnect.max_backoff, Duration::from_secs(1));
    }

    #[test]
    fn initial_sync_timeout_defaults_to_none() {
        let builder = X509SourceBuilder::new();
        assert_eq!(builder.initial_sync_timeout, None);
    }

    #[test]
    fn initial_sync_timeout_setter_stores_timeout() {
        let builder = X509SourceBuilder::new().initial_sync_timeout(Duration::from_secs(5));
        assert_eq!(builder.initial_sync_timeout, Some(Duration::from_secs(5)));
    }

    #[test]
    fn normalize_reconnect_authoritative_boundary() {
        // This test verifies that normalize_reconnect() is the single authoritative boundary.
        let inverted = ReconnectConfig {
            min_backoff: Duration::from_secs(10),
            max_backoff: Duration::from_secs(1),
        };
        let normalized = normalize_reconnect(inverted);
        assert_eq!(normalized.min_backoff, Duration::from_secs(1));
        assert_eq!(normalized.max_backoff, Duration::from_secs(10));

        // Verify that valid configs are preserved
        let valid = ReconnectConfig {
            min_backoff: Duration::from_millis(200),
            max_backoff: Duration::from_secs(10),
        };
        let normalized = normalize_reconnect(valid);
        assert_eq!(normalized.min_backoff, Duration::from_millis(200));
        assert_eq!(normalized.max_backoff, Duration::from_secs(10));
    }
}
