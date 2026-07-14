use super::builder::{JwtSourceBuilder, ReconnectConfig, ResourceLimits};
use super::errors::{JwtSourceError, MetricsErrorKind};
use super::limits::validate_bundle_set;
use super::metrics::MetricsRecorder;
use super::supervisor::initial_sync_with_retry;
use super::types::ClientFactory;
use crate::bundle::BundleSource;
use crate::prelude::{debug, warn};
use crate::transport::TransportError;
use crate::workload_api::WorkloadApiClient;
use crate::{JwtBundle, JwtBundleSet, JwtSvid, SpiffeId, TrustDomain, WorkloadApiError};
use arc_swap::ArcSwap;
use std::fmt::Debug;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{watch, Mutex};
use tokio::task::JoinHandle;
use tokio_util::sync::{CancellationToken, DropGuard};

/// Handle for receiving update notifications from a [`JwtSource`].
///
/// This type wraps the underlying notification mechanism and provides a clean
/// API for detecting when the JWT bundle set has been updated.
///
/// Cloning this handle creates another receiver that shares the same update
/// stream. Each receiver observes the latest sequence number; if a receiver
/// is slow to consume updates, intermediate sequence numbers may be skipped
/// (this is the standard behavior of `watch` channels).
///
/// # Examples
///
/// ```no_run
/// # use spiffe::JwtSource;
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let source = JwtSource::new().await?;
/// let mut updates = source.updated();
///
/// // Wait for an update
/// updates.changed().await?;
/// println!("Update sequence: {}", updates.last());
///
/// // Wait for another update
/// updates.changed().await?;
/// println!("New sequence: {}", updates.last());
/// # Ok(())
/// # }
/// ```
#[derive(Clone, Debug)]
pub struct JwtSourceUpdates {
    rx: watch::Receiver<u64>,
    shutdown: CancellationToken,
}

impl JwtSourceUpdates {
    /// Waits for the next update and returns the new sequence number.
    ///
    /// This method waits for the next rotation after initial synchronization.
    /// The initial sync does not trigger a notification; only subsequent updates
    /// are notified.
    ///
    /// This method will return an error if the source has been closed or
    /// the internal update task has terminated (e.g., due to shutdown or
    /// an internal error).
    ///
    /// # Errors
    ///
    /// Returns [`JwtSourceError::Closed`] if the source has been shut down
    /// or the internal update task has terminated. This can occur due to:
    /// - Explicit shutdown via [`JwtSource::shutdown`] or [`JwtSource::shutdown_with_timeout`]
    /// - Internal task termination (e.g., supervisor task panic)
    pub async fn changed(&mut self) -> Result<u64, JwtSourceError> {
        if self.rx.has_changed().unwrap_or(false) {
            self.rx
                .changed()
                .await
                .map_err(|watch::error::RecvError { .. }| JwtSourceError::Closed)?;
            return Ok(*self.rx.borrow());
        }

        if self.shutdown.is_cancelled() {
            return Err(JwtSourceError::Closed);
        }

        tokio::select! {
            biased;
            result = self.rx.changed() => {
                result.map_err(|watch::error::RecvError { .. }| JwtSourceError::Closed)?;
                Ok(*self.rx.borrow())
            }
            () = self.shutdown.cancelled() => Err(JwtSourceError::Closed),
        }
    }

    /// Returns the last sequence number without waiting.
    ///
    /// This method never blocks and always returns immediately with the
    /// current sequence number.
    pub fn last(&self) -> u64 {
        *self.rx.borrow()
    }

    /// Waits for the sequence number to satisfy a predicate.
    ///
    /// This method first checks whether the source is closed, then checks the
    /// current sequence number; if the predicate is already satisfied, it returns
    /// immediately without waiting. Otherwise, it repeatedly calls `changed()`
    /// until the predicate returns `true`.
    ///
    /// # Errors
    ///
    /// Returns an error if the source has been closed.
    pub async fn wait_for<F>(&mut self, mut f: F) -> Result<u64, JwtSourceError>
    where
        F: FnMut(&u64) -> bool,
    {
        if self.shutdown.is_cancelled() {
            return Err(JwtSourceError::Closed);
        }

        let current = self.last();
        if f(&current) {
            return Ok(current);
        }
        loop {
            let seq = self.changed().await?;
            if f(&seq) {
                return Ok(seq);
            }
        }
    }
}

/// Live source of JWT bundles from the SPIFFE Workload API.
///
/// `JwtSource` performs an initial sync before returning from [`JwtSource::new`] or
/// [`JwtSourceBuilder::build`]. Updates are applied atomically and can be observed via
/// [`JwtSource::updated`].
///
/// The source automatically:
/// - Maintains a cached view of the latest JWT bundles
/// - Handles bundle rotation transparently
/// - Reconnects with exponential backoff on transient failures
/// - Validates resource limits before publishing updates
///
/// Unlike X.509 SVIDs which are streamed continuously, JWT SVIDs are fetched on-demand
/// with specific audiences. Use [`JwtSource::fetch_jwt_svid`] to fetch JWT SVIDs as needed.
///
/// Use [`JwtSource::shutdown`] or [`JwtSource::shutdown_configured`] to stop background tasks.
///
#[derive(Clone, Debug)]
pub struct JwtSource {
    inner: Arc<Inner>,
    _shutdown_guard: Arc<DropGuard>,
}

pub(super) struct Inner {
    // Atomically replaced, last-known-good JWT bundle set.
    bundle_set: ArcSwap<JwtBundleSet>,
    limits: ResourceLimits,

    // Cached client for on-demand SVID fetching (recreated on failure).
    // Uses Option to allow lazy initialization.
    // Protected by Mutex to prevent concurrent creation.
    cached_client: ArcSwap<Option<Arc<WorkloadApiClient>>>,
    client_creation_mutex: Mutex<()>,

    // Supervisor configuration and dependencies.
    reconnect: ReconnectConfig,
    make_client: ClientFactory,
    metrics: Option<Arc<dyn MetricsRecorder>>,

    // Lifecycle / shutdown.
    closed: AtomicBool,
    supervisor_running: AtomicBool,
    cancel: CancellationToken,
    shutdown_timeout: Option<Duration>,

    // Update notifications (monotonic sequence).
    update_seq: AtomicU64,
    update_tx: watch::Sender<u64>,

    // Supervisor task handle (joined/aborted at shutdown).
    supervisor: Mutex<Option<JoinHandle<()>>>,
}

impl Inner {
    pub(super) const fn reconnect(&self) -> ReconnectConfig {
        self.reconnect
    }
    pub(super) fn metrics(&self) -> Option<&dyn MetricsRecorder> {
        self.metrics.as_deref()
    }
    pub(super) fn make_client(&self) -> &ClientFactory {
        &self.make_client
    }

    /// Gets the cached client or creates a new one if not available.
    ///
    /// This method is safe to call concurrently. If multiple tasks call this
    /// simultaneously when the cache is empty, only one will create the client;
    /// the others will wait and reuse the newly created client.
    pub(super) async fn get_or_recreate_client(
        &self,
    ) -> Result<Arc<WorkloadApiClient>, JwtSourceError> {
        // Fast path: check cache first
        let cached = self.cached_client.load();
        if let Some(client) = cached.as_ref() {
            return Ok(Arc::clone(client));
        }

        // Slow path: serialize client creation to avoid races
        let _guard = self.client_creation_mutex.lock().await;

        // Double-check: another task might have created it while we waited
        let cached = self.cached_client.load();
        if let Some(client) = cached.as_ref() {
            return Ok(Arc::clone(client));
        }

        // We're the first, create the client
        self.recreate_client_inner().await
    }

    /// Recreates the cached client and stores it atomically.
    ///
    /// This method should be called when the cached client fails or becomes invalid.
    /// It serializes creation to avoid concurrent recreation.
    pub(super) async fn recreate_client(&self) -> Result<Arc<WorkloadApiClient>, JwtSourceError> {
        let _guard = self.client_creation_mutex.lock().await;
        self.recreate_client_inner().await
    }

    /// Internal helper that actually creates and stores the client.
    /// Must be called while holding `client_creation_mutex`.
    async fn recreate_client_inner(&self) -> Result<Arc<WorkloadApiClient>, JwtSourceError> {
        let client = (self.make_client)().await.map_err(JwtSourceError::Source)?;
        let client_arc = Arc::new(client);
        self.cached_client
            .store(Arc::new(Some(Arc::clone(&client_arc))));
        Ok(client_arc)
    }
}

impl Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("JwtSource")
            .field("bundle_set", &"<ArcSwap<JwtBundleSet>>")
            .field(
                "cached_client",
                &"<ArcSwap<Option<Arc<WorkloadApiClient>>>>",
            )
            .field("client_creation_mutex", &"<Mutex<()>>")
            .field("reconnect", &self.reconnect)
            .field("limits", &self.limits)
            .field("make_client", &"<ClientFactory>")
            .field(
                "metrics",
                &self.metrics.as_ref().map(|_| "<MetricsRecorder>"),
            )
            .field("shutdown_timeout", &self.shutdown_timeout)
            .field("closed", &self.closed.load(Ordering::Relaxed))
            .field(
                "supervisor_running",
                &self.supervisor_running.load(Ordering::Relaxed),
            )
            .field("cancel", &self.cancel)
            .field("update_seq", &self.update_seq)
            .field("update_tx", &"<watch::Sender<u64>>")
            .field("supervisor", &"<Mutex<Option<JoinHandle<()>>>>")
            .finish()
    }
}

impl JwtSource {
    /// Creates a `JwtSource` using the default Workload API endpoint.
    ///
    /// The endpoint is resolved from `SPIFFE_ENDPOINT_SOCKET`.
    ///
    /// On success, the returned source is already synchronized with the agent and will keep
    /// updating in the background until it is closed.
    ///
    /// # Errors
    ///
    /// Returns a [`JwtSourceError`] if:
    /// - the Workload API endpoint cannot be resolved or connected to,
    /// - the initial synchronization with the Workload API does not complete successfully.
    pub async fn new() -> Result<Self, JwtSourceError> {
        JwtSourceBuilder::new().build().await
    }

    /// Creates a builder for configuring a [`JwtSource`].
    ///
    /// The builder allows customizing how the source connects to the SPIFFE
    /// Workload API and how JWT material is managed (e.g. endpoint selection,
    /// reconnection behavior, resource limits).
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::jwt_source::JwtSource;
    ///
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::builder()
    ///     .endpoint("unix:///tmp/spire-agent/public/api.sock")
    ///     .build()
    ///     .await?;
    ///
    /// # Ok(())
    /// # }
    /// ```
    pub fn builder() -> JwtSourceBuilder {
        JwtSourceBuilder::new()
    }

    /// Returns a handle for receiving update notifications.
    ///
    /// The handle yields a monotonically increasing sequence number on each
    /// successful update to the JWT bundle set. This can be used to detect when
    /// the bundle set has changed without polling.
    ///
    /// **Note:** The initial sequence number is 0. Notifications are only sent
    /// for rotations that occur after initial synchronization completes. The initial
    /// sync does not trigger a notification.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::JwtSource;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::new().await?;
    /// let mut updates = source.updated();
    /// // Wait for the first update notification
    /// updates.changed().await?;
    /// println!("Update sequence: {}", updates.last());
    /// # Ok(())
    /// # }
    /// ```
    pub fn updated(&self) -> JwtSourceUpdates {
        JwtSourceUpdates {
            rx: self.inner.update_tx.subscribe(),
            shutdown: self.inner.cancel.clone(),
        }
    }

    /// Returns `true` if the source appears healthy and can likely provide usable JWT
    /// bundle material (at least one bundle with at least one JWT authority).
    ///
    /// This method checks that:
    /// - The source is not closed or cancelled
    /// - The update supervisor is still running
    /// - The cached [`JwtBundleSet`] has at least one bundle with at least one JWT authority
    ///   (see `JwtBundle::jwt_authorities`)
    ///
    /// This does not perform network probes, does not validate that your Workload API client
    /// is still connected or responsive, and does not verify client liveness. It reflects
    /// local, cached state only.
    ///
    /// **Note:** This check is inherently racy. Between calling `is_healthy()` and
    /// `bundle_set()`, the source may be shut down or the bundle set may change. Use this
    /// for best-effort health checks (e.g., monitoring), not for synchronization.
    /// If you need a guaranteed check, call `bundle_set()` directly and handle the error.
    /// `build()` / builder `build()` only indicates that initial sync completed successfully;
    /// `is_healthy()` is a runtime health signal, not a construction-success signal. There
    /// may be a brief scheduler-dependent window immediately after construction where this
    /// method returns `false` until the background supervisor task is first polled.
    ///
    /// If a [`MetricsRecorder`] callback panics, the supervisor task terminates, update
    /// handles close, and this method reports `false` afterward. Rebuild the source to
    /// resume updates.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::JwtSource;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::new().await?;
    ///
    /// if source.is_healthy() {
    ///     println!("Source appears healthy");
    /// } else {
    ///     println!("Source is unhealthy");
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn is_healthy(&self) -> bool {
        if self.inner.closed.load(Ordering::Acquire)
            || self.inner.cancel.is_cancelled()
            || !self.inner.supervisor_running.load(Ordering::Acquire)
        {
            return false;
        }

        let bundle_set = self.inner.bundle_set.load();
        let has_jwt_signing_key = bundle_set
            .iter()
            .any(|(_td, b)| b.jwt_authorities().next().is_some());
        has_jwt_signing_key
    }

    /// Returns the current JWT bundle set.
    ///
    /// # Errors
    ///
    /// Returns a [`JwtSourceError`] if the source is closed.
    pub fn bundle_set(&self) -> Result<Arc<JwtBundleSet>, JwtSourceError> {
        self.assert_open()?;
        Ok(self.inner.bundle_set.load_full())
    }

    /// Returns the current bundle for the trust domain, or `None` if unavailable.
    ///
    /// Returns `None` instead of an error
    /// when the bundle cannot be retrieved. Use this when `None` is an acceptable
    /// value for your use case.
    ///
    /// **Note:** This method swallows all errors, including `Closed`. If you need
    /// to detect shutdown, use [`JwtSource::bundle_for_trust_domain`] instead.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::{TrustDomain, JwtSource};
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::new().await?;
    /// let trust_domain = TrustDomain::new("example.org")?;
    ///
    /// if let Some(bundle) = source.try_bundle_for_trust_domain(&trust_domain) {
    ///     println!("Got bundle for {}", trust_domain);
    /// } else {
    ///     println!("No bundle available for {}", trust_domain);
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn try_bundle_for_trust_domain(&self, td: &TrustDomain) -> Option<Arc<JwtBundle>> {
        self.bundle_for_trust_domain(td).ok().flatten()
    }

    /// Fetches a JWT SVID for the given audience.
    ///
    /// Unlike X.509 SVIDs which are streamed continuously, JWT SVIDs are fetched
    /// on-demand with specific audiences. This method makes a one-shot request to
    /// the Workload API to fetch a JWT SVID.
    ///
    /// # Errors
    ///
    /// Returns a [`JwtSourceError`] if:
    /// - the source is closed
    /// - the Workload API request fails
    /// - no SVID is returned or the SVID cannot be parsed
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::JwtSource;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::new().await?;
    ///
    /// // Fetch a JWT SVID for specific audiences
    /// let jwt_svid = source.fetch_jwt_svid(&["service-a", "service-b"]).await?;
    /// println!("SPIFFE ID: {}", jwt_svid.spiffe_id());
    ///
    /// # Ok(())
    /// # }
    /// ```
    pub async fn fetch_jwt_svid<I>(&self, audience: I) -> Result<JwtSvid, JwtSourceError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        self.fetch_jwt_svid_with_id(audience, None).await
    }

    /// Fetches a JWT SVID for the given audience and optional SPIFFE ID.
    ///
    /// This method automatically retries once if the initial request fails with a transient
    /// transport/status error. On retry, the cached client is recreated to handle transient
    /// connection issues.
    ///
    /// # Errors
    ///
    /// Returns a [`JwtSourceError`] if:
    /// - the source is closed
    /// - the Workload API request fails (after retry)
    /// - no SVID is returned or the SVID cannot be parsed
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::JwtSource;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::new().await?;
    ///
    /// // Fetch for a specific SPIFFE ID
    /// let spiffe_id = "spiffe://example.org/myservice".parse()?;
    /// let jwt_svid = source.fetch_jwt_svid_with_id(&["service-a"], Some(&spiffe_id)).await?;
    /// # Ok(())
    /// # }
    pub async fn fetch_jwt_svid_with_id<I>(
        &self,
        audience: I,
        spiffe_id: Option<&SpiffeId>,
    ) -> Result<JwtSvid, JwtSourceError>
    where
        I: IntoIterator,
        I::Item: AsRef<str>,
    {
        self.assert_open()?;

        // Collect audience into Vec to allow reuse on retry
        let audience_vec: Vec<String> = audience
            .into_iter()
            .map(|a| a.as_ref().to_string())
            .collect();

        let client = self.inner.get_or_recreate_client().await?;

        match client.fetch_jwt_svid(&audience_vec, spiffe_id).await {
            Ok(svid) => Ok(svid),
            Err(e) if is_retryable_jwt_fetch_error(&e) => {
                debug!("JWT-SVID fetch failed with retryable Workload API error; recreating client and retrying once: error={e}");
                self.assert_open()?; // Check if closed before retry
                let new_client = self.inner.recreate_client().await?;
                new_client
                    .fetch_jwt_svid(&audience_vec, spiffe_id)
                    .await
                    .map_err(JwtSourceError::FetchJwtSvid)
            }
            Err(e) => Err(JwtSourceError::FetchJwtSvid(e)),
        }
    }

    /// Cancels background tasks and waits for termination.
    ///
    /// This method is idempotent. Calling it multiple times is safe and has no
    /// additional effect after the first invocation.
    ///
    /// The shutdown request is best-effort. Background tasks are signaled to stop
    /// and awaited before returning.
    ///
    /// **Note:** This method may wait indefinitely if background tasks don't respond.
    /// For production use, use [`JwtSource::shutdown_with_timeout`] or
    /// [`JwtSource::shutdown_configured`].
    pub async fn shutdown(&self) {
        if self.inner.closed.swap(true, Ordering::AcqRel) {
            return;
        }
        self.inner.cancel.cancel();

        if let Some(handle) = self.inner.supervisor.lock().await.take() {
            if let Err(e) = handle.await {
                warn!("Error joining supervisor task during shutdown: error={e}");
                self.inner
                    .record_error(MetricsErrorKind::SupervisorJoinFailed);
            }
        }
    }

    /// Cancels background tasks and waits for termination with a timeout.
    ///
    /// This method attempts graceful shutdown first: it signals cancellation and
    /// waits up to `timeout` for the supervisor task to complete. If the timeout
    /// is exceeded, the task is forcefully aborted.
    ///
    /// This method is idempotent. Calling it multiple times is safe and has no
    /// additional effect after the first invocation.
    ///
    /// # Errors
    ///
    /// Returns [`JwtSourceError::ShutdownTimeout`] if graceful shutdown does not
    /// complete within the timeout and the task must be aborted.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::JwtSource;
    /// use std::time::Duration;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = JwtSource::new().await?;
    /// // Shutdown with 10 second timeout (graceful, then abort if needed)
    /// source.shutdown_with_timeout(Duration::from_secs(10)).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn shutdown_with_timeout(&self, timeout: Duration) -> Result<(), JwtSourceError> {
        if self.inner.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        self.inner.cancel.cancel();

        let Some(mut handle) = self.inner.supervisor.lock().await.take() else {
            return Ok(());
        };

        match tokio::time::timeout(timeout, &mut handle).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => {
                warn!("Error joining supervisor task during shutdown: error={e}");
                self.inner
                    .record_error(MetricsErrorKind::SupervisorJoinFailed);
                Ok(())
            }
            Err(_) => {
                warn!("Shutdown timeout exceeded; aborting supervisor task");
                handle.abort();
                // Wait for the abort to take effect
                let _unused: Result<_, _> = handle.await;
                Err(JwtSourceError::ShutdownTimeout)
            }
        }
    }

    /// Cancels background tasks and waits for termination using the configured timeout.
    ///
    /// Uses the timeout configured in the builder.
    /// If no timeout was configured, this method will wait indefinitely (same as `shutdown()`).
    ///
    /// # Errors
    ///
    /// Returns [`JwtSourceError::ShutdownTimeout`] if the configured shutdown timeout is exceeded.
    pub async fn shutdown_configured(&self) -> Result<(), JwtSourceError> {
        if let Some(timeout) = self.inner.shutdown_timeout {
            self.shutdown_with_timeout(timeout).await
        } else {
            self.shutdown().await;
            Ok(())
        }
    }
}

fn is_retryable_jwt_fetch_error(error: &WorkloadApiError) -> bool {
    match error {
        WorkloadApiError::Transport(TransportError::Tonic(_)) => true,
        WorkloadApiError::Transport(TransportError::Status(status)) => matches!(
            status.code(),
            tonic::Code::Cancelled | tonic::Code::DeadlineExceeded | tonic::Code::Unavailable
        ),
        _ => false,
    }
}

struct BuildParts {
    make_client: ClientFactory,
    reconnect: ReconnectConfig,
    limits: ResourceLimits,
    metrics: Option<Arc<dyn MetricsRecorder>>,
    shutdown_timeout: Option<Duration>,
    cancel: CancellationToken,
    shutdown_guard: Arc<DropGuard>,
    update_tx: watch::Sender<u64>,
}

impl JwtSource {
    async fn build_from_synced_bundle_set(
        parts: BuildParts,
        initial_bundle_set: Arc<JwtBundleSet>,
    ) -> Self {
        let BuildParts {
            make_client,
            reconnect,
            limits,
            metrics,
            shutdown_timeout,
            cancel,
            shutdown_guard,
            update_tx,
        } = parts;

        let inner = Arc::new(Inner {
            bundle_set: ArcSwap::from(initial_bundle_set),
            cached_client: ArcSwap::from(Arc::new(None)),
            client_creation_mutex: Mutex::new(()),
            reconnect,
            make_client,
            limits,
            metrics,
            shutdown_timeout,
            closed: AtomicBool::new(false),
            supervisor_running: AtomicBool::new(false),
            cancel,
            update_seq: AtomicU64::new(0),
            update_tx,
            supervisor: Mutex::new(None),
        });

        let task_inner = Arc::clone(&inner);
        let token = task_inner.cancel.clone();
        let guard_inner = Arc::clone(&task_inner);
        let handle = tokio::spawn(async move {
            let _terminate_on_drop = SupervisorTerminationGuard::new(guard_inner);
            task_inner.run_update_supervisor(token).await;
        });

        *inner.supervisor.lock().await = Some(handle);

        Self {
            inner,
            _shutdown_guard: shutdown_guard,
        }
    }

    async fn build_with_initial_sync<F>(
        parts: BuildParts,
        initial_sync_timeout: Option<Duration>,
        initial_sync: F,
    ) -> Result<Self, JwtSourceError>
    where
        F: Future<Output = Result<Arc<JwtBundleSet>, JwtSourceError>>,
    {
        let initial_bundle_set =
            initial_sync_with_timeout(initial_sync, &parts.cancel, initial_sync_timeout).await?;

        Ok(Self::build_from_synced_bundle_set(parts, initial_bundle_set).await)
    }

    pub(super) async fn build_with(
        make_client: ClientFactory,
        reconnect: ReconnectConfig,
        limits: ResourceLimits,
        metrics: Option<Arc<dyn MetricsRecorder>>,
        shutdown_timeout: Option<Duration>,
        initial_sync_timeout: Option<Duration>,
    ) -> Result<Self, JwtSourceError> {
        let reconnect = super::builder::normalize_reconnect(reconnect);

        let (update_tx, _update_rx) = watch::channel(0u64);
        let cancel = CancellationToken::new();
        let shutdown_guard = Arc::new(cancel.clone().drop_guard());
        let initial_sync_make_client = Arc::clone(&make_client);
        let initial_sync_cancel = cancel.clone();
        let initial_sync_metrics = metrics.clone();
        let initial_sync = async move {
            initial_sync_with_retry(
                &initial_sync_make_client,
                &initial_sync_cancel,
                reconnect,
                limits,
                initial_sync_metrics.as_deref(),
            )
            .await
        };

        let parts = BuildParts {
            make_client,
            reconnect,
            limits,
            metrics,
            shutdown_timeout,
            cancel,
            shutdown_guard,
            update_tx,
        };

        Self::build_with_initial_sync(parts, initial_sync_timeout, initial_sync).await
    }

    /// Test-only constructor that creates a `JwtSource` with a provided initial bundle set
    /// without spawning the supervisor task or performing initial sync.
    ///
    /// This allows deterministic unit tests without requiring a real Workload API client.
    #[cfg(test)]
    pub(super) fn new_for_test(
        initial_bundle_set: Arc<JwtBundleSet>,
        reconnect: ReconnectConfig,
        limits: ResourceLimits,
        metrics: Option<Arc<dyn MetricsRecorder>>,
    ) -> Self {
        let make_client: ClientFactory =
            Arc::new(|| Box::pin(async move { Err(WorkloadApiError::EmptyResponse) }));

        Self::new_for_test_with_client_factory(
            initial_bundle_set,
            reconnect,
            limits,
            metrics,
            make_client,
        )
    }

    #[cfg(test)]
    fn new_for_test_with_client_factory(
        initial_bundle_set: Arc<JwtBundleSet>,
        reconnect: ReconnectConfig,
        limits: ResourceLimits,
        metrics: Option<Arc<dyn MetricsRecorder>>,
        make_client: ClientFactory,
    ) -> Self {
        // Normalize reconnect config at the boundary (same as build_with)
        let reconnect = super::builder::normalize_reconnect(reconnect);

        let (update_tx, _update_rx) = watch::channel(0u64);
        let cancel = CancellationToken::new();
        let shutdown_guard = Arc::new(cancel.clone().drop_guard());

        let inner = Inner {
            bundle_set: ArcSwap::from(initial_bundle_set),
            cached_client: ArcSwap::from(Arc::new(None)),
            client_creation_mutex: Mutex::new(()),
            reconnect,
            make_client,
            limits,
            metrics,
            shutdown_timeout: None,
            closed: AtomicBool::new(false),
            supervisor_running: AtomicBool::new(false),
            cancel,
            update_seq: AtomicU64::new(0),
            update_tx,
            supervisor: Mutex::new(None),
        };

        Self {
            inner: Arc::new(inner),
            _shutdown_guard: shutdown_guard,
        }
    }

    fn assert_open(&self) -> Result<(), JwtSourceError> {
        if self.inner.closed.load(Ordering::Acquire) || self.inner.cancel.is_cancelled() {
            return Err(JwtSourceError::Closed);
        }
        Ok(())
    }
}

struct SupervisorTerminationGuard {
    inner: Arc<Inner>,
}

impl SupervisorTerminationGuard {
    fn new(inner: Arc<Inner>) -> Self {
        inner.supervisor_running.store(true, Ordering::Release);
        Self { inner }
    }
}

impl Drop for SupervisorTerminationGuard {
    fn drop(&mut self) {
        self.inner
            .supervisor_running
            .store(false, Ordering::Release);
        self.inner.cancel.cancel();
    }
}

impl Inner {
    pub(super) fn record_error(&self, kind: MetricsErrorKind) {
        if let Some(metrics) = self.metrics.as_deref() {
            metrics.record_error(kind);
        }
    }

    pub(super) fn record_update(&self) {
        if let Some(metrics) = self.metrics.as_deref() {
            metrics.record_update();
        }
    }

    pub(super) fn apply_update(
        &self,
        new_bundle_set: Arc<JwtBundleSet>,
    ) -> Result<(), JwtSourceError> {
        // validate_bundle_set() already records limit-specific metrics.
        // We only record UpdateRejected here if validation fails, and the supervisor loop
        // should NOT record it again to avoid double-counting.
        match self.validate_bundle_set(&new_bundle_set) {
            Ok(()) => {
                self.bundle_set.store(new_bundle_set);
                self.notify_update();
                self.record_update();
                Ok(())
            }
            Err(e) => {
                // Record UpdateRejected for any validation failure (limit metrics already recorded in validate_bundle_set).
                self.record_error(MetricsErrorKind::UpdateRejected);
                Err(e)
            }
        }
    }

    pub(super) fn notify_update(&self) {
        let next = self.update_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let _prev = self.update_tx.send_replace(next);
    }

    pub(super) fn validate_bundle_set(
        &self,
        bundle_set: &JwtBundleSet,
    ) -> Result<(), JwtSourceError> {
        validate_bundle_set(bundle_set, self.limits, self.metrics.as_deref())
    }
}

async fn initial_sync_with_timeout<T, F>(
    initial_sync: F,
    cancel: &CancellationToken,
    timeout: Option<Duration>,
) -> Result<T, JwtSourceError>
where
    F: Future<Output = Result<T, JwtSourceError>>,
{
    let Some(timeout) = timeout else {
        return initial_sync.await;
    };

    match tokio::time::timeout(timeout, initial_sync).await {
        Ok(result) => result,
        Err(_elapsed) => {
            cancel.cancel();
            Err(JwtSourceError::InitialSyncTimeout)
        }
    }
}

impl BundleSource for JwtSource {
    type Item = JwtBundle;
    type Error = JwtSourceError;

    fn bundle_for_trust_domain(
        &self,
        trust_domain: &TrustDomain,
    ) -> Result<Option<Arc<Self::Item>>, Self::Error> {
        self.assert_open()?;
        let bundle_set = self.inner.bundle_set.load();
        Ok(bundle_set.get(trust_domain))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundle::jwt::JwtAuthority;
    use crate::transport::Endpoint;
    use crate::workload_api::client::JwtFetchTestHook;
    use base64ct::{Base64UrlUnpadded, Encoding as _};
    use std::collections::{HashMap, VecDeque};
    use std::sync::atomic::AtomicUsize;
    use std::sync::Mutex;

    fn updates_for_test(rx: watch::Receiver<u64>) -> JwtSourceUpdates {
        JwtSourceUpdates {
            rx,
            shutdown: CancellationToken::new(),
        }
    }

    fn jwk_with_kid(kid: &str) -> JwtAuthority {
        let json = format!(
            r#"{{
                "kty": "oct",
                "kid": "{kid}",
                "k": "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow"
            }}"#
        );
        JwtAuthority::from_jwk_json(json.as_bytes()).expect("valid JWK JSON")
    }

    fn create_test_bundle_set() -> Arc<JwtBundleSet> {
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let mut bundle = JwtBundle::new(trust_domain);
        bundle.add_jwt_authority(jwk_with_kid("kid-1"));
        let mut bundle_set = JwtBundleSet::new();
        bundle_set.add_bundle(bundle);
        Arc::new(bundle_set)
    }

    fn test_jwt_svid() -> JwtSvid {
        let header = Base64UrlUnpadded::encode_string(br#"{"alg":"ES256","kid":"k1","typ":"JWT"}"#);
        let claims = Base64UrlUnpadded::encode_string(
            br#"{"sub":"spiffe://example.org/service","aud":"aud1","exp":4294967295}"#,
        );
        JwtSvid::parse_insecure(&format!("{header}.{claims}.sig")).unwrap()
    }

    #[derive(Clone)]
    enum FetchOutcome {
        Ok,
        PermissionDenied(&'static str),
        NoIdentityIssued,
        HintNotFound(&'static str),
        InvalidJwt,
        Unavailable,
    }

    impl FetchOutcome {
        fn into_result(self) -> Result<JwtSvid, WorkloadApiError> {
            match self {
                Self::Ok => Ok(test_jwt_svid()),
                Self::PermissionDenied(msg) => {
                    Err(WorkloadApiError::PermissionDenied(msg.to_owned()))
                }
                Self::NoIdentityIssued => Err(WorkloadApiError::NoIdentityIssued),
                Self::HintNotFound(hint) => Err(WorkloadApiError::HintNotFound(hint.to_owned())),
                Self::InvalidJwt => Err(WorkloadApiError::JwtSvid(
                    JwtSvid::parse_insecure("not-a-jwt").unwrap_err(),
                )),
                Self::Unavailable => Err(WorkloadApiError::Transport(TransportError::Status(
                    tonic::Status::unavailable("agent unavailable"),
                ))),
            }
        }
    }

    struct FetchTestSource {
        source: JwtSource,
        factory_calls: Arc<AtomicUsize>,
        fetch_calls: Arc<AtomicUsize>,
    }

    fn source_with_fetch_outcomes(outcomes: Vec<FetchOutcome>) -> FetchTestSource {
        let outcomes = Arc::new(Mutex::new(VecDeque::from(outcomes)));
        let factory_calls = Arc::new(AtomicUsize::new(0));
        let fetch_calls = Arc::new(AtomicUsize::new(0));

        let make_client: ClientFactory = {
            let outcomes = Arc::clone(&outcomes);
            let factory_calls = Arc::clone(&factory_calls);
            let fetch_calls = Arc::clone(&fetch_calls);

            Arc::new(move || {
                factory_calls.fetch_add(1, Ordering::SeqCst);

                let hook: JwtFetchTestHook = {
                    let outcomes = Arc::clone(&outcomes);
                    let fetch_calls = Arc::clone(&fetch_calls);

                    Arc::new(move |_audience, _spiffe_id| {
                        fetch_calls.fetch_add(1, Ordering::SeqCst);
                        let outcome = outcomes
                            .lock()
                            .unwrap()
                            .pop_front()
                            .expect("test fetch outcome must be available");
                        Box::pin(async move { outcome.into_result() })
                    })
                };

                Box::pin(async move {
                    Ok(WorkloadApiClient::new_with_jwt_fetch_hook(
                        Endpoint::parse("tcp://127.0.0.1:1").unwrap(),
                        hook,
                    ))
                })
            })
        };

        let source = JwtSource::new_for_test_with_client_factory(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            make_client,
        );

        FetchTestSource {
            source,
            factory_calls,
            fetch_calls,
        }
    }

    async fn fetch_test_result(
        outcomes: Vec<FetchOutcome>,
    ) -> (Result<JwtSvid, JwtSourceError>, FetchTestSource) {
        let test_source = source_with_fetch_outcomes(outcomes);
        let spiffe_id = SpiffeId::new("spiffe://example.org/service").unwrap();
        let result = test_source
            .source
            .fetch_jwt_svid_with_id(["aud1"], Some(&spiffe_id))
            .await;
        (result, test_source)
    }

    #[tokio::test]
    async fn fetch_jwt_svid_does_not_retry_permission_denied() {
        let (result, test_source) =
            fetch_test_result(vec![FetchOutcome::PermissionDenied("not allowed")]).await;

        assert!(matches!(
            result,
            Err(JwtSourceError::FetchJwtSvid(
                WorkloadApiError::PermissionDenied(msg)
            )) if msg == "not allowed"
        ));
        assert_eq!(test_source.factory_calls.load(Ordering::SeqCst), 1);
        assert_eq!(test_source.fetch_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn fetch_jwt_svid_does_not_retry_no_identity_issued() {
        let (result, test_source) = fetch_test_result(vec![FetchOutcome::NoIdentityIssued]).await;

        assert!(matches!(
            result,
            Err(JwtSourceError::FetchJwtSvid(
                WorkloadApiError::NoIdentityIssued
            ))
        ));
        assert_eq!(test_source.factory_calls.load(Ordering::SeqCst), 1);
        assert_eq!(test_source.fetch_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn fetch_jwt_svid_does_not_retry_hint_not_found() {
        let (result, test_source) =
            fetch_test_result(vec![FetchOutcome::HintNotFound("external")]).await;

        assert!(matches!(
            result,
            Err(JwtSourceError::FetchJwtSvid(
                WorkloadApiError::HintNotFound(hint)
            )) if hint == "external"
        ));
        assert_eq!(test_source.factory_calls.load(Ordering::SeqCst), 1);
        assert_eq!(test_source.fetch_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn fetch_jwt_svid_does_not_retry_jwt_parse_error() {
        let (result, test_source) = fetch_test_result(vec![FetchOutcome::InvalidJwt]).await;

        assert!(matches!(
            result,
            Err(JwtSourceError::FetchJwtSvid(WorkloadApiError::JwtSvid(_)))
        ));
        assert_eq!(test_source.factory_calls.load(Ordering::SeqCst), 1);
        assert_eq!(test_source.fetch_calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn fetch_jwt_svid_retries_once_on_unavailable() {
        let (result, test_source) =
            fetch_test_result(vec![FetchOutcome::Unavailable, FetchOutcome::Ok]).await;

        result.expect("retry should return second successful JWT-SVID fetch");
        assert_eq!(test_source.factory_calls.load(Ordering::SeqCst), 2);
        assert_eq!(test_source.fetch_calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn fetch_jwt_svid_returns_second_failure_after_retry() {
        let (result, test_source) = fetch_test_result(vec![
            FetchOutcome::Unavailable,
            FetchOutcome::PermissionDenied("still denied"),
        ])
        .await;

        assert!(matches!(
            result,
            Err(JwtSourceError::FetchJwtSvid(
                WorkloadApiError::PermissionDenied(msg)
            )) if msg == "still denied"
        ));
        assert_eq!(test_source.factory_calls.load(Ordering::SeqCst), 2);
        assert_eq!(test_source.fetch_calls.load(Ordering::SeqCst), 2);
    }

    /// Trust domain present but no JWT keys (e.g. empty JWKS) — not sufficient for `is_healthy`.
    fn create_bundle_set_trust_domain_without_jwt_authorities() -> Arc<JwtBundleSet> {
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let mut bundle_set = JwtBundleSet::new();
        bundle_set.add_bundle(JwtBundle::new(trust_domain));
        Arc::new(bundle_set)
    }

    fn supervisor_running_guard_for_test(source: &JwtSource) -> SupervisorTerminationGuard {
        SupervisorTerminationGuard::new(Arc::clone(&source.inner))
    }

    async fn terminate_supervisor_for_test(terminate_guard: SupervisorTerminationGuard) {
        tokio::spawn(async move {
            let _terminate_on_drop = terminate_guard;
        })
        .await
        .expect("supervisor termination task should not panic");
    }

    #[tokio::test]
    async fn initial_sync_timeout_returns_timeout_and_cancels_token() {
        let cancel = CancellationToken::new();

        let result = initial_sync_with_timeout(
            std::future::pending::<Result<(), JwtSourceError>>(),
            &cancel,
            Some(Duration::ZERO),
        )
        .await;

        assert!(matches!(result, Err(JwtSourceError::InitialSyncTimeout)));
        assert!(cancel.is_cancelled());
    }

    #[tokio::test]
    async fn initial_sync_timeout_allows_success_before_timeout() {
        let cancel = CancellationToken::new();

        let result = initial_sync_with_timeout(
            async { Ok::<_, JwtSourceError>("synced") },
            &cancel,
            Some(Duration::from_secs(60)),
        )
        .await;

        assert_eq!(result.unwrap(), "synced");
        assert!(!cancel.is_cancelled());
    }

    #[tokio::test]
    async fn initial_sync_without_timeout_waits_for_future() {
        let cancel = CancellationToken::new();

        let result =
            initial_sync_with_timeout(async { Ok::<_, JwtSourceError>("synced") }, &cancel, None)
                .await;

        assert_eq!(result.unwrap(), "synced");
        assert!(!cancel.is_cancelled());
    }

    #[tokio::test]
    async fn build_with_initial_sync_timeout_does_not_eagerly_create_jwt_client() {
        let (update_tx, _update_rx) = watch::channel(0u64);
        let cancel = CancellationToken::new();
        let shutdown_guard = Arc::new(cancel.clone().drop_guard());
        let make_client: ClientFactory = Arc::new(|| {
            Box::pin(async {
                std::future::pending::<Result<WorkloadApiClient, WorkloadApiError>>().await
            })
        });

        let source = tokio::time::timeout(
            Duration::from_millis(100),
            JwtSource::build_with_initial_sync(
                BuildParts {
                    make_client,
                    reconnect: ReconnectConfig {
                        min_backoff: Duration::from_millis(10),
                        max_backoff: Duration::from_millis(10),
                    },
                    limits: ResourceLimits::default(),
                    metrics: None,
                    shutdown_timeout: Some(Duration::from_millis(10)),
                    cancel,
                    shutdown_guard,
                    update_tx,
                },
                Some(Duration::from_millis(50)),
                async { Ok::<_, JwtSourceError>(create_test_bundle_set()) },
            ),
        )
        .await
        .expect("build_with post-initial-sync path should not wait on on-demand client creation")
        .expect("initial sync should succeed before timeout");

        assert!(
            source.inner.cached_client.load().is_none(),
            "on-demand JWT client should start empty and be created lazily"
        );

        let _unused = source
            .shutdown_with_timeout(Duration::from_millis(10))
            .await;
    }

    #[tokio::test]
    async fn test_wait_for_immediate_satisfaction() {
        let (tx, rx) = watch::channel(5u64);
        let mut updates = updates_for_test(rx);

        // Predicate is already satisfied (current value is 5, which is > 3)
        let result = updates.wait_for(|&seq| seq > 3).await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 5);

        // Update the value
        let _unused: Result<_, _> = tx.send(10);

        // Wait for predicate to be satisfied again (should return immediately with new value)
        let result = updates.wait_for(|&seq| seq > 8).await;
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 10);
    }

    #[tokio::test]
    async fn test_wait_for_waits_when_not_satisfied() {
        let (tx, rx) = watch::channel(1u64);
        let mut updates = updates_for_test(rx);

        // Spawn a task to update the value after a short delay
        let tx_clone = tx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let _unused: Result<_, _> = tx_clone.send(5);
        });

        // Predicate is not satisfied initially (1 is not > 3)
        // Should wait and then return when value becomes 5
        let result = tokio::time::timeout(Duration::from_secs(1), updates.wait_for(|&seq| seq > 3))
            .await
            .expect("Should complete within timeout");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 5);
    }

    #[tokio::test]
    async fn test_updated_only_notifies_on_rotations_after_initial_sync() {
        // Verify that updated().changed() only notifies on rotations after initial sync,
        // not on the initial sync itself. The initial sequence number is 0.
        let (tx, rx) = watch::channel(0u64);
        let mut updates = updates_for_test(rx.clone());

        // Initial value is 0, so changed() should wait for an update
        let tx_clone = tx.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            // Simulate first rotation after initial sync
            let _unused: Result<_, _> = tx_clone.send(1);
        });

        // Should wait and then return when value becomes 1 (first rotation)
        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("Should complete within timeout");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 1);
        assert_eq!(updates.last(), 1);
    }

    #[tokio::test]
    async fn test_updated_initial_sequence_is_zero() {
        // Verify that the initial sequence number is 0
        let (_tx, rx) = watch::channel(0u64);
        let updates = updates_for_test(rx);
        assert_eq!(updates.last(), 0);
    }

    #[tokio::test]
    async fn test_updated_subscribes_at_current_sequence() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );

        source.inner.notify_update();

        let mut updates = source.updated();
        assert_eq!(updates.last(), 1);
        assert!(
            tokio::time::timeout(Duration::from_millis(20), updates.changed())
                .await
                .is_err(),
            "new subscribers should wait for updates after subscription"
        );

        source.inner.notify_update();
        assert_eq!(updates.changed().await.unwrap(), 2);
    }

    /// With no `updated()` / `watch` subscribers yet, `notify_update` must still advance the
    /// shared sequence; the first `updated()` should observe that value.
    #[test]
    fn test_notify_update_sequence_before_first_subscriber() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        source.inner.notify_update();
        let updates = source.updated();
        assert_eq!(updates.last(), 1);
    }

    #[tokio::test]
    async fn test_updates_changed_returns_closed_after_shutdown() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let mut updates = source.updated();

        source.shutdown().await;

        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed should return after shutdown");
        assert!(matches!(result, Err(JwtSourceError::Closed)));
    }

    #[tokio::test]
    async fn test_updates_wait_for_returns_closed_after_shutdown() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let mut updates = source.updated();

        source.shutdown().await;

        let result = tokio::time::timeout(Duration::from_secs(1), updates.wait_for(|&seq| seq > 0))
            .await
            .expect("wait_for should return after shutdown");
        assert!(matches!(result, Err(JwtSourceError::Closed)));
    }

    #[tokio::test]
    async fn wait_for_returns_closed_after_shutdown_even_when_predicate_matches_current() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let mut updates = source.updated();
        let current = updates.last();

        source.shutdown().await;

        let result = updates.wait_for(|seq| *seq == current).await;
        assert!(matches!(result, Err(JwtSourceError::Closed)));
    }

    #[tokio::test]
    async fn test_updates_changed_delivers_pending_update_before_closed() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let mut updates = source.updated();

        source.inner.notify_update();
        source.inner.cancel.cancel();

        assert_eq!(updates.changed().await.unwrap(), 1);
        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed should return closed after pending update is observed");
        assert!(matches!(result, Err(JwtSourceError::Closed)));
    }

    #[tokio::test]
    async fn test_updates_changed_returns_closed_after_last_source_drop() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let mut updates = source.updated();

        drop(source);

        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed should return after last source handle is dropped");
        assert!(matches!(result, Err(JwtSourceError::Closed)));
    }

    #[tokio::test]
    async fn test_dropping_last_source_handle_cancels_supervisor_token() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let clone = source.clone();
        let task_inner = Arc::clone(&source.inner);
        let token = task_inner.cancel.clone();
        let (stopped_tx, stopped_rx) = tokio::sync::oneshot::channel();

        tokio::spawn(async move {
            token.cancelled().await;
            let _unused: Result<_, _> = stopped_tx.send(());
            drop(task_inner);
        });

        drop(source);
        // One public handle still holds the shutdown guard, so cancellation must not fire yet.
        assert!(!clone.inner.cancel.is_cancelled());

        drop(clone);
        tokio::time::timeout(Duration::from_secs(1), stopped_rx)
            .await
            .expect("supervisor token should be cancelled when last source handle is dropped")
            .expect("supervisor observer should send stop notification");
    }

    #[tokio::test]
    async fn test_supervisor_termination_marks_unhealthy_and_closes_updates() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let running_guard = supervisor_running_guard_for_test(&source);
        let mut changed_updates = source.updated();
        let mut wait_updates = source.updated();

        assert!(
            source.is_healthy(),
            "cached bundle set should be healthy while supervisor is running"
        );

        terminate_supervisor_for_test(running_guard).await;

        assert!(
            !source.is_healthy(),
            "source must be unhealthy after supervisor termination"
        );
        let changed = tokio::time::timeout(Duration::from_secs(1), changed_updates.changed())
            .await
            .expect("changed should stop waiting after supervisor termination");
        assert!(matches!(changed, Err(JwtSourceError::Closed)));

        let waited = tokio::time::timeout(
            Duration::from_secs(1),
            wait_updates.wait_for(|&seq| seq > 0),
        )
        .await
        .expect("wait_for should stop waiting after supervisor termination");
        assert!(matches!(waited, Err(JwtSourceError::Closed)));
    }

    #[tokio::test]
    async fn wait_for_returns_closed_after_supervisor_termination_even_when_predicate_matches_current(
    ) {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let running_guard = supervisor_running_guard_for_test(&source);
        let mut updates = source.updated();
        let current = updates.last();

        terminate_supervisor_for_test(running_guard).await;

        let result = updates.wait_for(|seq| *seq == current).await;
        assert!(matches!(result, Err(JwtSourceError::Closed)));
    }

    #[test]
    fn test_is_healthy_false_when_bundle_set_is_empty() {
        let source = JwtSource::new_for_test(
            Arc::new(JwtBundleSet::new()),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let _guard = supervisor_running_guard_for_test(&source);
        assert!(!source.is_healthy(), "empty bundle set must be unhealthy");
    }

    #[test]
    fn test_is_healthy_false_when_trust_domain_has_no_jwt_authorities() {
        let source = JwtSource::new_for_test(
            create_bundle_set_trust_domain_without_jwt_authorities(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let _guard = supervisor_running_guard_for_test(&source);
        assert!(
            !source.is_healthy(),
            "bundle with no signing keys must be unhealthy even if the trust domain is present"
        );
    }

    #[test]
    fn test_is_healthy_true_when_trust_domain_has_jwt_authority() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let _guard = supervisor_running_guard_for_test(&source);
        assert!(source.is_healthy());
    }

    #[tokio::test]
    async fn is_healthy_false_after_shutdown() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let _guard = supervisor_running_guard_for_test(&source);

        assert!(source.is_healthy());
        source.shutdown().await;
        assert!(!source.is_healthy());
    }

    #[test]
    fn is_healthy_false_after_cancel() {
        let source = JwtSource::new_for_test(
            create_test_bundle_set(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
        );
        let _guard = supervisor_running_guard_for_test(&source);

        assert!(source.is_healthy());
        source.inner.cancel.cancel();
        assert!(!source.is_healthy());
    }

    /// Test metrics recorder that counts error recordings by kind.
    struct TestMetricsRecorder {
        counts: Arc<Mutex<HashMap<MetricsErrorKind, u64>>>,
    }

    impl TestMetricsRecorder {
        fn new() -> Self {
            Self {
                counts: Arc::new(Mutex::new(HashMap::new())),
            }
        }

        fn count(&self, kind: MetricsErrorKind) -> u64 {
            *self.counts.lock().unwrap().get(&kind).unwrap_or(&0)
        }
    }

    impl MetricsRecorder for TestMetricsRecorder {
        fn record_update(&self) {}
        fn record_reconnect(&self) {}
        fn record_error(&self, kind: MetricsErrorKind) {
            *self.counts.lock().unwrap().entry(kind).or_insert(0) += 1;
        }
    }

    struct OrderingMetricsRecorder {
        updates: Mutex<Option<JwtSourceUpdates>>,
        update_sequences: Mutex<Vec<Option<u64>>>,
    }

    impl OrderingMetricsRecorder {
        fn new() -> Self {
            Self {
                updates: Mutex::new(None),
                update_sequences: Mutex::new(Vec::new()),
            }
        }

        fn set_updates(&self, updates: JwtSourceUpdates) {
            *self.updates.lock().unwrap() = Some(updates);
        }

        fn update_sequences(&self) -> Vec<Option<u64>> {
            self.update_sequences.lock().unwrap().clone()
        }

        fn record_observed_update(&self) {
            let sequence = self
                .updates
                .lock()
                .unwrap()
                .as_ref()
                .map(JwtSourceUpdates::last);
            self.update_sequences.lock().unwrap().push(sequence);
        }
    }

    impl MetricsRecorder for OrderingMetricsRecorder {
        fn record_update(&self) {
            self.record_observed_update();
        }

        fn record_reconnect(&self) {}
        fn record_error(&self, _kind: MetricsErrorKind) {}
    }

    struct PanickingOrderingMetricsRecorder {
        inner: OrderingMetricsRecorder,
    }

    impl PanickingOrderingMetricsRecorder {
        fn new() -> Self {
            Self {
                inner: OrderingMetricsRecorder::new(),
            }
        }

        fn set_updates(&self, updates: JwtSourceUpdates) {
            self.inner.set_updates(updates);
        }

        fn update_sequences(&self) -> Vec<Option<u64>> {
            self.inner.update_sequences()
        }
    }

    impl MetricsRecorder for PanickingOrderingMetricsRecorder {
        fn record_update(&self) {
            self.inner.record_observed_update();
            panic!("intentional metrics panic for update ordering test");
        }

        fn record_reconnect(&self) {}
        fn record_error(&self, _kind: MetricsErrorKind) {}
    }

    #[test]
    fn test_apply_update_notifies_before_recording_success_metrics() {
        let metrics = Arc::new(OrderingMetricsRecorder::new());
        let source = JwtSource::new_for_test(
            Arc::new(JwtBundleSet::new()),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            Some(Arc::<OrderingMetricsRecorder>::clone(&metrics)),
        );
        metrics.set_updates(source.updated());

        let result = source.inner.apply_update(create_test_bundle_set());

        result.expect("valid JWT bundle set update should be accepted");
        assert_eq!(metrics.update_sequences(), vec![Some(1)]);
        assert_eq!(source.updated().last(), 1);
        assert_eq!(source.bundle_set().unwrap().iter().count(), 1);
    }

    #[test]
    fn test_apply_update_publishes_and_notifies_before_panicking_success_metrics() {
        let metrics = Arc::new(PanickingOrderingMetricsRecorder::new());
        let source = JwtSource::new_for_test(
            Arc::new(JwtBundleSet::new()),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            Some(Arc::<PanickingOrderingMetricsRecorder>::clone(&metrics)),
        );
        metrics.set_updates(source.updated());

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            source.inner.apply_update(create_test_bundle_set())
        }));

        result.expect_err("metrics recorder should panic after notification");
        assert_eq!(metrics.update_sequences(), vec![Some(1)]);
        assert_eq!(source.updated().last(), 1);
        assert_eq!(source.bundle_set().unwrap().iter().count(), 1);
    }

    #[test]
    fn test_metrics_recorded_exactly_once_per_rejected_update() {
        // Verify that UpdateRejected and limit metrics are recorded exactly once
        // per rejected update, with no double-counting.
        use super::super::builder::ResourceLimits;
        use crate::bundle::jwt::JwtBundle;

        let metrics = Arc::new(TestMetricsRecorder::new());
        let limits = ResourceLimits {
            max_bundles: Some(0), // Limit that will be exceeded
            max_bundle_jwks_bytes: Some(1000),
        };

        // Create a bundle set with 1 bundle (exceeds max_bundles=0)
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let mut bundle = JwtBundle::new(trust_domain);
        bundle.add_jwt_authority(jwk_with_kid("kid-1"));
        let mut bundle_set = JwtBundleSet::new();
        bundle_set.add_bundle(bundle);

        // Create source using test seam
        let source = {
            let metrics = Arc::clone(&metrics);
            JwtSource::new_for_test(
                Arc::new(JwtBundleSet::new()),
                ReconnectConfig::default(),
                limits,
                Some(metrics),
            )
        };

        // Apply update that should be rejected due to max_bundles limit
        let result = source.inner.apply_update(Arc::new(bundle_set));

        // Should fail with ResourceLimitExceeded
        assert!(matches!(
            result,
            Err(JwtSourceError::ResourceLimitExceeded {
                kind: super::super::errors::LimitKind::MaxBundles,
                ..
            })
        ));

        // Verify metrics recorded exactly once
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundles), 1);
        assert_eq!(metrics.count(MetricsErrorKind::UpdateRejected), 1);
        // Verify no other limit metrics were recorded
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundleJwksBytes), 0);
    }

    #[test]
    fn test_new_with_normalizes_reconnect_config() {
        // Verify that JwtSource::build_with() normalizes reconnect config at the authoritative boundary.
        use super::super::builder::ResourceLimits;
        use std::time::Duration;

        let initial_bundle_set = create_test_bundle_set();

        // Create reconnect config with inverted min/max (min > max)
        let inverted_reconnect = ReconnectConfig {
            min_backoff: Duration::from_secs(10),
            max_backoff: Duration::from_secs(1),
        };

        // Create source using test seam with inverted reconnect config
        let source = JwtSource::new_for_test(
            initial_bundle_set,
            inverted_reconnect,
            ResourceLimits::default(),
            None,
        );

        // Verify that reconnect config was normalized (swapped)
        assert_eq!(source.inner.reconnect.min_backoff, Duration::from_secs(1));
        assert_eq!(source.inner.reconnect.max_backoff, Duration::from_secs(10));
    }

    #[test]
    fn test_initial_sync_validation_records_correct_metrics() {
        // Verify that validation records limit metrics,
        // but does NOT record UpdateRejected (that's recorded by apply_update).
        use super::super::builder::ResourceLimits;
        use super::super::limits::validate_bundle_set;

        let metrics = Arc::new(TestMetricsRecorder::new());
        let limits = ResourceLimits {
            max_bundles: Some(0), // Limit that will be exceeded
            max_bundle_jwks_bytes: Some(1000),
        };

        // Create a bundle set with 1 bundle (exceeds max_bundles=0)
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let mut bundle = JwtBundle::new(trust_domain);
        bundle.add_jwt_authority(jwk_with_kid("kid-1"));
        let mut bundle_set = JwtBundleSet::new();
        bundle_set.add_bundle(bundle);

        // Validate bundle set (simulating validation used in both initial sync and updates)
        let result = validate_bundle_set(&bundle_set, limits, Some(metrics.as_ref()));

        // Should fail with ResourceLimitExceeded
        assert!(matches!(
            result,
            Err(JwtSourceError::ResourceLimitExceeded {
                kind: super::super::errors::LimitKind::MaxBundles,
                ..
            })
        ));

        // Verify limit metric was recorded
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundles), 1);
        // Verify UpdateRejected was NOT recorded (that's recorded by apply_update, not validate_bundle_set)
        assert_eq!(metrics.count(MetricsErrorKind::UpdateRejected), 0);
        // Verify no other limit metrics were recorded
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundleJwksBytes), 0);
    }

    #[test]
    fn test_resource_limits_unlimited() {
        // Verify that ResourceLimits::unlimited() creates limits with all fields set to None.
        use super::super::builder::ResourceLimits;

        let unlimited = ResourceLimits::unlimited();
        assert_eq!(unlimited.max_bundles, None);
        assert_eq!(unlimited.max_bundle_jwks_bytes, None);
    }

    #[test]
    fn test_resource_limits_default_limits() {
        // Verify that ResourceLimits::default_limits() creates limits with conservative defaults.
        use super::super::builder::ResourceLimits;

        let limits = ResourceLimits::default_limits();
        assert_eq!(limits.max_bundles, Some(200));
        assert_eq!(limits.max_bundle_jwks_bytes, Some(4 * 1024 * 1024)); // 4MB
    }

    #[test]
    fn test_resource_limits_mixed() {
        // Verify that ResourceLimits can have mixed unlimited and limited fields.
        use super::super::builder::ResourceLimits;

        let mixed = ResourceLimits {
            max_bundles: Some(50),
            max_bundle_jwks_bytes: None, // Unlimited
        };

        assert_eq!(mixed.max_bundles, Some(50));
        assert_eq!(mixed.max_bundle_jwks_bytes, None);
    }
}
