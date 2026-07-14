use super::builder::{ReconnectConfig, ResourceLimits};
use super::errors::{MetricsErrorKind, X509SourceError};
use super::limits::{select_svid, validate_context};
use super::metrics::MetricsRecorder;
use super::supervisor::initial_sync_with_retry;
use crate::bundle::BundleSource;
use crate::prelude::warn;
use crate::svid::SvidSource;
use crate::workload_api::x509_context::X509Context;
use crate::x509_source::types::{ClientFactory, SvidPicker};
use crate::{TrustDomain, X509Bundle, X509BundleSet, X509SourceBuilder, X509Svid};
use arc_swap::ArcSwap;
use std::fmt::Debug;
use std::future::Future;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{watch, Mutex};
use tokio::task::JoinHandle;
use tokio_util::sync::{CancellationToken, DropGuard};

#[cfg(test)]
use crate::WorkloadApiError;

/// Handle for receiving update notifications from an [`X509Source`].
///
/// This type wraps the underlying notification mechanism and provides a clean
/// API for detecting when the X.509 context has been updated.
///
/// Cloning this handle creates another receiver that shares the same update
/// stream. Each receiver observes the latest sequence number; if a receiver
/// is slow to consume updates, intermediate sequence numbers may be skipped
/// (this is the standard behavior of `watch` channels).
///
/// # Examples
///
/// ```no_run
/// # use spiffe::X509Source;
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let source = X509Source::new().await?;
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
pub struct X509SourceUpdates {
    rx: watch::Receiver<u64>,
    shutdown: CancellationToken,
}

impl X509SourceUpdates {
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
    /// Returns [`X509SourceError::Closed`] if the source has been shut down
    /// or the internal update task has terminated. This can occur due to:
    /// - Explicit shutdown via [`X509Source::shutdown`] or [`X509Source::shutdown_with_timeout`]
    /// - Internal task termination (e.g., supervisor task panic)
    pub async fn changed(&mut self) -> Result<u64, X509SourceError> {
        if self.rx.has_changed().unwrap_or(false) {
            self.rx
                .changed()
                .await
                .map_err(|watch::error::RecvError { .. }| X509SourceError::Closed)?;
            return Ok(*self.rx.borrow());
        }

        if self.shutdown.is_cancelled() {
            return Err(X509SourceError::Closed);
        }

        tokio::select! {
            biased;
            result = self.rx.changed() => {
                result.map_err(|watch::error::RecvError { .. }| X509SourceError::Closed)?;
                Ok(*self.rx.borrow())
            }
            () = self.shutdown.cancelled() => Err(X509SourceError::Closed),
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
    pub async fn wait_for<F>(&mut self, mut f: F) -> Result<u64, X509SourceError>
    where
        F: FnMut(&u64) -> bool,
    {
        if self.shutdown.is_cancelled() {
            return Err(X509SourceError::Closed);
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

/// Live source of X.509 SVIDs and bundles from the SPIFFE Workload API.
///
/// `X509Source` performs an initial sync before returning from [`X509Source::new`] or
/// [`X509SourceBuilder::build`]. Updates are applied atomically and can be observed via
/// [`X509Source::updated`].
///
/// The source automatically:
/// - Maintains a cached view of the latest X.509 materials
/// - Handles SVID and bundle rotation transparently
/// - Reconnects with exponential backoff on transient failures
/// - Validates resource limits before publishing updates
///
/// Use [`X509Source::shutdown`] or [`X509Source::shutdown_configured`] to stop background tasks.
///
#[derive(Clone, Debug)]
pub struct X509Source {
    inner: Arc<Inner>,
    _shutdown_guard: Arc<DropGuard>,
}

struct Snapshot {
    ctx: Arc<X509Context>,
    expiry_unix: i64,
}

pub(super) struct Inner {
    // Atomically replaced, last-known-good X.509 context and selected SVID expiry.
    snapshot: ArcSwap<Snapshot>,

    // Policy for selecting an SVID when multiple are present.
    svid_picker: Option<Box<dyn SvidPicker>>,
    limits: ResourceLimits,

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
}

impl Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("X509Source")
            .field("snapshot", &"<ArcSwap<Snapshot>>")
            .field(
                "svid_picker",
                &self.svid_picker.as_ref().map(|_| "<SvidPicker>"),
            )
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

impl X509Source {
    /// Creates an `X509Source` using the default Workload API endpoint.
    ///
    /// The endpoint is resolved from `SPIFFE_ENDPOINT_SOCKET`. The source selects the default
    /// X.509 SVID when multiple SVIDs are available.
    ///
    /// On success, the returned source is already synchronized with the agent and will keep
    /// updating in the background until it is closed.
    ///
    /// # Errors
    ///
    /// Returns an [`X509SourceError`] if:
    /// - the Workload API endpoint cannot be resolved or connected to,
    /// - the initial synchronization with the Workload API does not complete successfully,
    /// - or no suitable X.509 SVID can be selected from the received context.
    pub async fn new() -> Result<Self, X509SourceError> {
        X509SourceBuilder::new().build().await
    }

    /// Creates a builder for configuring an [`X509Source`].
    ///
    /// The builder allows customizing how the source connects to the SPIFFE
    /// Workload API and how X.509 material is managed (e.g. endpoint selection,
    /// reconnection behavior, resource limits).
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509Source;
    ///
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = X509Source::builder()
    ///     .endpoint("unix:///tmp/spire-agent/public/api.sock")
    ///     .build()
    ///     .await?;
    ///
    /// # Ok(())
    /// # }
    /// ```
    pub fn builder() -> X509SourceBuilder {
        X509SourceBuilder::new()
    }

    /// Returns a handle for receiving update notifications.
    ///
    /// The handle yields a monotonically increasing sequence number on each
    /// successful update to the X.509 context. This can be used to detect when
    /// the context has changed without polling.
    ///
    /// **Note:** The initial sequence number is 0. Notifications are only sent
    /// for rotations that occur after initial synchronization completes. The initial
    /// sync does not trigger a notification.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::X509Source;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = X509Source::new().await?;
    /// let mut updates = source.updated();
    /// // Wait for the first update notification
    /// updates.changed().await?;
    /// println!("Update sequence: {}", updates.last());
    /// # Ok(())
    /// # }
    /// ```
    pub fn updated(&self) -> X509SourceUpdates {
        X509SourceUpdates {
            rx: self.inner.update_tx.subscribe(),
            shutdown: self.inner.cancel.clone(),
        }
    }

    /// Returns `true` if the source appears healthy and can likely provide an SVID.
    ///
    /// This method checks that:
    /// - The source is not closed or cancelled
    /// - The update supervisor is still running
    /// - The most recently accepted update produced a selectable SVID
    /// - That selected SVID's leaf certificate `notAfter` is still in the future
    ///
    /// **Note:** This check is inherently racy. Between calling `is_healthy()` and
    /// `svid()`, the source may be shut down or the context may change. Use this
    /// for best-effort health checks (e.g., monitoring), not for synchronization.
    /// If you need a guaranteed check, call `svid()` directly and handle the error.
    /// `build()` / builder `build()` only indicates that initial sync completed successfully;
    /// `is_healthy()` is a runtime health signal, not a construction-success signal. There
    /// may be a brief scheduler-dependent window immediately after construction where this
    /// method returns `false` until the background supervisor task is first polled.
    ///
    /// If a [`MetricsRecorder`] or picker callback panics, the supervisor task terminates,
    /// update handles close, and this method reports `false` afterward. Rebuild the source
    /// to resume updates.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::X509Source;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = X509Source::new().await?;
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

        let Some(now) = unix_timestamp_now() else {
            // If the wall clock is unavailable, health is reported conservatively as
            // unhealthy. Validation is more optimistic to avoid rejecting otherwise
            // usable initial sync data.
            return false;
        };

        self.inner.snapshot.load().expiry_unix > now
    }

    /// Returns the current X.509 context (SVID + bundles) as a single value.
    ///
    /// # Errors
    ///
    /// Returns an [`X509SourceError`] if the X.509 context is not available or
    /// cannot be constructed.
    pub fn x509_context(&self) -> Result<Arc<X509Context>, X509SourceError> {
        self.assert_open()?;
        Ok(Arc::clone(&self.inner.snapshot.load().ctx))
    }

    /// Returns the current X.509 SVID selected by the picker (or default).
    ///
    /// # Errors
    ///
    /// Returns [`X509SourceError`] if the source is closed or no SVID is available.
    pub fn svid(&self) -> Result<Arc<X509Svid>, X509SourceError> {
        self.assert_open()?;

        let snapshot = self.inner.snapshot.load();
        select_svid(&snapshot.ctx, self.inner.svid_picker.as_deref()).ok_or_else(|| {
            self.inner.record_error(MetricsErrorKind::NoSuitableSvid);
            X509SourceError::NoSuitableSvid
        })
    }

    /// Returns the current SVID, or `None` if unavailable.
    ///
    /// Returns `None` instead of an error
    /// when the SVID cannot be retrieved. Use this when `None` is an acceptable
    /// value for your use case.
    ///
    /// **Note:** This method swallows all errors, including `Closed`. If you need
    /// to detect shutdown, use [`X509Source::svid`] instead.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::X509Source;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = X509Source::new().await?;
    ///
    /// if let Some(svid) = source.try_svid() {
    ///     println!("Got SVID: {}", svid.spiffe_id());
    /// } else {
    ///     println!("No SVID available");
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn try_svid(&self) -> Option<Arc<X509Svid>> {
        self.svid().ok()
    }

    /// Returns the current X.509 bundle set.
    ///
    /// # Errors
    ///
    /// Returns [`X509SourceError`] if the source is closed.
    pub fn bundle_set(&self) -> Result<Arc<X509BundleSet>, X509SourceError> {
        self.assert_open()?;
        Ok(Arc::clone(self.inner.snapshot.load().ctx.bundle_set()))
    }

    /// Returns the current bundle for the trust domain, or `None` if unavailable.
    ///
    /// Returns `None` instead of an error
    /// when the bundle cannot be retrieved. Use this when `None` is an acceptable
    /// value for your use case.
    ///
    /// **Note:** This method swallows all errors, including `Closed`. If you need
    /// to detect shutdown, use [`X509Source::bundle_for_trust_domain`] instead.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # use spiffe::{TrustDomain, X509Source};
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = X509Source::new().await?;
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
    pub fn try_bundle_for_trust_domain(&self, td: &TrustDomain) -> Option<Arc<X509Bundle>> {
        self.bundle_for_trust_domain(td).ok().flatten()
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
    /// For production use, use [`X509Source::shutdown_with_timeout`] or
    /// [`X509Source::shutdown_configured`].
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
    /// Returns [`X509SourceError::ShutdownTimeout`] if graceful shutdown does not
    /// complete within the timeout and the task must be aborted.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::X509Source;
    /// use std::time::Duration;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let source = X509Source::new().await?;
    /// // Shutdown with 10 second timeout (graceful, then abort if needed)
    /// source.shutdown_with_timeout(Duration::from_secs(10)).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn shutdown_with_timeout(&self, timeout: Duration) -> Result<(), X509SourceError> {
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
                Err(X509SourceError::ShutdownTimeout)
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
    /// Returns [`X509SourceError::ShutdownTimeout`] if the configured shutdown timeout is exceeded.
    pub async fn shutdown_configured(&self) -> Result<(), X509SourceError> {
        if let Some(timeout) = self.inner.shutdown_timeout {
            self.shutdown_with_timeout(timeout).await
        } else {
            self.shutdown().await;
            Ok(())
        }
    }
}

impl X509Source {
    pub(super) async fn build_with(
        make_client: ClientFactory,
        svid_picker: Option<Box<dyn SvidPicker>>,
        reconnect: ReconnectConfig,
        limits: ResourceLimits,
        metrics: Option<Arc<dyn MetricsRecorder>>,
        shutdown_timeout: Option<Duration>,
        initial_sync_timeout: Option<Duration>,
    ) -> Result<Self, X509SourceError> {
        let reconnect = super::builder::normalize_reconnect(reconnect);

        let (update_tx, _update_rx) = watch::channel(0u64);
        let cancel = CancellationToken::new();
        let shutdown_guard = Arc::new(cancel.clone().drop_guard());

        let initial_sync = initial_sync_with_retry(
            &make_client,
            svid_picker.as_deref(),
            &cancel,
            reconnect,
            limits,
            metrics.as_deref(),
        );
        let (initial_ctx, selected_svid) =
            initial_sync_with_timeout(initial_sync, &cancel, initial_sync_timeout).await?;
        let snapshot = Arc::new(Snapshot {
            ctx: initial_ctx,
            expiry_unix: selected_svid.expiry_unix(),
        });

        let inner = Arc::new(Inner {
            snapshot: ArcSwap::from(snapshot),
            svid_picker,
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

        Ok(Self {
            inner,
            _shutdown_guard: shutdown_guard,
        })
    }

    /// Test-only constructor that creates an `X509Source` with a provided initial context
    /// without spawning the supervisor task or performing initial sync.
    ///
    /// This allows deterministic unit tests without requiring a real Workload API client.
    #[cfg(test)]
    pub(super) fn new_for_test(
        initial_ctx: Arc<X509Context>,
        reconnect: ReconnectConfig,
        limits: ResourceLimits,
        metrics: Option<Arc<dyn MetricsRecorder>>,
        svid_picker: Option<Box<dyn SvidPicker>>,
    ) -> Self {
        // Normalize reconnect config at the boundary (same as new_with)
        let reconnect = super::builder::normalize_reconnect(reconnect);

        let (update_tx, _update_rx) = watch::channel(0u64);
        let cancel = CancellationToken::new();
        let shutdown_guard = Arc::new(cancel.clone().drop_guard());

        let make_client: ClientFactory =
            Arc::new(|| Box::pin(async move { Err(WorkloadApiError::EmptyResponse) }));
        let selected_svid_expires_at_unix =
            select_svid(&initial_ctx, svid_picker.as_deref()).map_or(0, |svid| svid.expiry_unix());
        let snapshot = Arc::new(Snapshot {
            ctx: initial_ctx,
            expiry_unix: selected_svid_expires_at_unix,
        });

        let inner = Inner {
            snapshot: ArcSwap::from(snapshot),
            svid_picker,
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

    fn assert_open(&self) -> Result<(), X509SourceError> {
        if self.inner.closed.load(Ordering::Acquire) || self.inner.cancel.is_cancelled() {
            return Err(X509SourceError::Closed);
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

fn unix_timestamp_now() -> Option<i64> {
    let duration = SystemTime::now().duration_since(UNIX_EPOCH).ok()?;
    i64::try_from(duration.as_secs()).ok()
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

    pub(super) fn apply_update(&self, new_ctx: Arc<X509Context>) -> Result<(), X509SourceError> {
        // validate_and_select() already records limit-specific metrics and NoSuitableSvid.
        // We only record UpdateRejected here if validation fails, and the supervisor loop
        // should NOT record it again to avoid double-counting.
        match self.validate_and_select(&new_ctx) {
            Ok(svid) => {
                self.snapshot.store(Arc::new(Snapshot {
                    ctx: new_ctx,
                    expiry_unix: svid.expiry_unix(),
                }));
                self.notify_update();
                self.record_update();
                Ok(())
            }
            Err(e) => {
                // Record UpdateRejected for any validation failure (limit metrics already recorded in validate_and_select).
                self.record_error(MetricsErrorKind::UpdateRejected);
                Err(e)
            }
        }
    }

    pub(super) fn notify_update(&self) {
        let next = self.update_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let _prev = self.update_tx.send_replace(next);
    }

    pub(super) fn validate_and_select(
        &self,
        ctx: &X509Context,
    ) -> Result<Arc<X509Svid>, X509SourceError> {
        validate_context(
            ctx,
            self.svid_picker.as_deref(),
            self.limits,
            self.metrics.as_deref(),
        )
    }
}

async fn initial_sync_with_timeout<T, F>(
    initial_sync: F,
    cancel: &CancellationToken,
    timeout: Option<Duration>,
) -> Result<T, X509SourceError>
where
    F: Future<Output = Result<T, X509SourceError>>,
{
    let Some(timeout) = timeout else {
        return initial_sync.await;
    };

    match tokio::time::timeout(timeout, initial_sync).await {
        Ok(result) => result,
        Err(_elapsed) => {
            cancel.cancel();
            Err(X509SourceError::InitialSyncTimeout)
        }
    }
}

impl SvidSource for X509Source {
    type Item = X509Svid;
    type Error = X509SourceError;

    fn svid(&self) -> Result<Arc<Self::Item>, Self::Error> {
        Self::svid(self)
    }
}

impl BundleSource for X509Source {
    type Item = X509Bundle;
    type Error = X509SourceError;

    fn bundle_for_trust_domain(
        &self,
        trust_domain: &TrustDomain,
    ) -> Result<Option<Arc<Self::Item>>, Self::Error> {
        self.assert_open()?;
        let snapshot = self.inner.snapshot.load();
        Ok(snapshot.ctx.bundle_set().get(trust_domain))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    fn updates_for_test(rx: watch::Receiver<u64>) -> X509SourceUpdates {
        X509SourceUpdates {
            rx,
            shutdown: CancellationToken::new(),
        }
    }

    fn test_x509_context() -> Arc<X509Context> {
        let cert_bytes = include_bytes!("../../tests/testdata/svid/x509/1-svid-chain.der");
        let key_bytes = include_bytes!("../../tests/testdata/svid/x509/1-key.der");
        let svid = Arc::new(X509Svid::parse_from_der(cert_bytes, key_bytes).unwrap());
        Arc::new(X509Context::new([svid], Arc::new(X509BundleSet::new())))
    }

    fn supervisor_running_guard_for_test(source: &X509Source) -> SupervisorTerminationGuard {
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
            std::future::pending::<Result<(), X509SourceError>>(),
            &cancel,
            Some(Duration::ZERO),
        )
        .await;

        assert!(matches!(result, Err(X509SourceError::InitialSyncTimeout)));
        assert!(cancel.is_cancelled());
    }

    #[tokio::test]
    async fn initial_sync_timeout_allows_success_before_timeout() {
        let cancel = CancellationToken::new();

        let result = initial_sync_with_timeout(
            async { Ok::<_, X509SourceError>("synced") },
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
            initial_sync_with_timeout(async { Ok::<_, X509SourceError>("synced") }, &cancel, None)
                .await;

        assert_eq!(result.unwrap(), "synced");
        assert!(!cancel.is_cancelled());
    }

    fn set_selected_svid_expiry_for_test(source: &X509Source, expiry_unix: i64) {
        let snapshot = source.inner.snapshot.load();
        source.inner.snapshot.store(Arc::new(Snapshot {
            ctx: Arc::clone(&snapshot.ctx),
            expiry_unix,
        }));
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
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
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
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        source.inner.notify_update();
        let updates = source.updated();
        assert_eq!(updates.last(), 1);
    }

    #[tokio::test]
    async fn test_updates_changed_returns_closed_after_shutdown() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let mut updates = source.updated();

        source.shutdown().await;

        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed should return after shutdown");
        assert!(matches!(result, Err(X509SourceError::Closed)));
    }

    #[tokio::test]
    async fn test_updates_wait_for_returns_closed_after_shutdown() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let mut updates = source.updated();

        source.shutdown().await;

        let result = tokio::time::timeout(Duration::from_secs(1), updates.wait_for(|&seq| seq > 0))
            .await
            .expect("wait_for should return after shutdown");
        assert!(matches!(result, Err(X509SourceError::Closed)));
    }

    #[tokio::test]
    async fn wait_for_returns_closed_after_shutdown_even_when_predicate_matches_current() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let mut updates = source.updated();
        let current = updates.last();

        source.shutdown().await;

        let result = updates.wait_for(|seq| *seq == current).await;
        assert!(matches!(result, Err(X509SourceError::Closed)));
    }

    #[tokio::test]
    async fn test_updates_changed_delivers_pending_update_before_closed() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let mut updates = source.updated();

        source.inner.notify_update();
        source.inner.cancel.cancel();

        assert_eq!(updates.changed().await.unwrap(), 1);
        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed should return closed after pending update is observed");
        assert!(matches!(result, Err(X509SourceError::Closed)));
    }

    #[tokio::test]
    async fn test_updates_changed_returns_closed_after_last_source_drop() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let mut updates = source.updated();

        drop(source);

        let result = tokio::time::timeout(Duration::from_secs(1), updates.changed())
            .await
            .expect("changed should return after last source handle is dropped");
        assert!(matches!(result, Err(X509SourceError::Closed)));
    }

    #[tokio::test]
    async fn test_dropping_last_source_handle_cancels_supervisor_token() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
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
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let running_guard = supervisor_running_guard_for_test(&source);
        let mut changed_updates = source.updated();
        let mut wait_updates = source.updated();

        assert!(
            source.is_healthy(),
            "cached SVID should be healthy while supervisor is running"
        );

        terminate_supervisor_for_test(running_guard).await;

        assert!(
            !source.is_healthy(),
            "source must be unhealthy after supervisor termination"
        );
        let changed = tokio::time::timeout(Duration::from_secs(1), changed_updates.changed())
            .await
            .expect("changed should stop waiting after supervisor termination");
        assert!(matches!(changed, Err(X509SourceError::Closed)));

        let waited = tokio::time::timeout(
            Duration::from_secs(1),
            wait_updates.wait_for(|&seq| seq > 0),
        )
        .await
        .expect("wait_for should stop waiting after supervisor termination");
        assert!(matches!(waited, Err(X509SourceError::Closed)));
    }

    #[tokio::test]
    async fn wait_for_returns_closed_after_supervisor_termination_even_when_predicate_matches_current(
    ) {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let running_guard = supervisor_running_guard_for_test(&source);
        let mut updates = source.updated();
        let current = updates.last();

        terminate_supervisor_for_test(running_guard).await;

        let result = updates.wait_for(|seq| *seq == current).await;
        assert!(matches!(result, Err(X509SourceError::Closed)));
    }

    #[test]
    fn test_is_healthy_returns_false_when_selected_svid_is_expired() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let _running_guard = supervisor_running_guard_for_test(&source);
        let now = unix_timestamp_now().expect("system time should be after UNIX epoch");

        assert!(
            source.is_healthy(),
            "source should be healthy while selected SVID expiry is in the future"
        );

        set_selected_svid_expiry_for_test(&source, now);
        assert!(
            !source.is_healthy(),
            "source should be unhealthy once selected SVID expiry is reached"
        );
    }

    #[tokio::test]
    async fn is_healthy_false_after_shutdown() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let _running_guard = supervisor_running_guard_for_test(&source);

        assert!(source.is_healthy());
        source.shutdown().await;
        assert!(!source.is_healthy());
    }

    #[test]
    fn is_healthy_false_after_cancel() {
        let source = X509Source::new_for_test(
            test_x509_context(),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            None,
            None,
        );
        let _running_guard = supervisor_running_guard_for_test(&source);

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
        updates: Mutex<Option<X509SourceUpdates>>,
        update_sequences: Mutex<Vec<Option<u64>>>,
    }

    impl OrderingMetricsRecorder {
        fn new() -> Self {
            Self {
                updates: Mutex::new(None),
                update_sequences: Mutex::new(Vec::new()),
            }
        }

        fn set_updates(&self, updates: X509SourceUpdates) {
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
                .map(X509SourceUpdates::last);
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

        fn set_updates(&self, updates: X509SourceUpdates) {
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
        let source = X509Source::new_for_test(
            Arc::new(X509Context::new([], Arc::new(X509BundleSet::new()))),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            Some(Arc::<OrderingMetricsRecorder>::clone(&metrics)),
            None,
        );
        metrics.set_updates(source.updated());

        let result = source.inner.apply_update(test_x509_context());

        result.expect("valid X.509 update should be accepted");
        assert_eq!(metrics.update_sequences(), vec![Some(1)]);
        assert_eq!(source.updated().last(), 1);
        assert_eq!(source.x509_context().unwrap().svids().len(), 1);
    }

    #[test]
    fn test_apply_update_publishes_and_notifies_before_panicking_success_metrics() {
        let metrics = Arc::new(PanickingOrderingMetricsRecorder::new());
        let source = X509Source::new_for_test(
            Arc::new(X509Context::new([], Arc::new(X509BundleSet::new()))),
            ReconnectConfig::default(),
            ResourceLimits::default(),
            Some(Arc::<PanickingOrderingMetricsRecorder>::clone(&metrics)),
            None,
        );
        metrics.set_updates(source.updated());

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            source.inner.apply_update(test_x509_context())
        }));

        result.expect_err("metrics recorder should panic after notification");
        assert_eq!(metrics.update_sequences(), vec![Some(1)]);
        assert_eq!(source.updated().last(), 1);
        assert_eq!(source.x509_context().unwrap().svids().len(), 1);
    }

    #[test]
    fn test_metrics_recorded_exactly_once_per_rejected_update() {
        // Verify that UpdateRejected and limit metrics are recorded exactly once
        // per rejected update, with no double-counting.
        use super::super::builder::{ReconnectConfig, ResourceLimits};
        use crate::workload_api::x509_context::X509Context;
        use crate::{TrustDomain, X509Bundle, X509BundleSet, X509Svid};
        use std::sync::Arc;

        // Load test fixture SVID
        let cert_bytes = include_bytes!("../../tests/testdata/svid/x509/1-svid-chain.der");
        let key_bytes = include_bytes!("../../tests/testdata/svid/x509/1-key.der");
        let svid = Arc::new(X509Svid::parse_from_der(cert_bytes, key_bytes).unwrap());

        let metrics = Arc::new(TestMetricsRecorder::new());
        let limits = ResourceLimits {
            max_svids: Some(100),
            max_bundles: Some(0), // Limit that will be exceeded
            max_bundle_der_bytes: Some(1000),
        };

        // Create a context with 1 bundle (exceeds max_bundles=0)
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let bundle = X509Bundle::new(trust_domain);
        let mut bundle_set = X509BundleSet::new();
        bundle_set.add_bundle(bundle);

        let ctx = X509Context::new([svid], Arc::new(bundle_set));

        // Create source using test seam
        let source = {
            let metrics = Arc::clone(&metrics);
            X509Source::new_for_test(
                Arc::new(X509Context::new([], Arc::new(X509BundleSet::new()))),
                ReconnectConfig::default(),
                limits,
                Some(metrics),
                None,
            )
        };

        // Apply update that should be rejected due to max_bundles limit
        let result = source.inner.apply_update(Arc::new(ctx));

        // Should fail with ResourceLimitExceeded
        assert!(matches!(
            result,
            Err(X509SourceError::ResourceLimitExceeded {
                kind: super::super::errors::LimitKind::MaxBundles,
                ..
            })
        ));

        // Verify metrics recorded exactly once
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundles), 1);
        assert_eq!(metrics.count(MetricsErrorKind::UpdateRejected), 1);
        // Verify no other limit metrics were recorded
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxSvids), 0);
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundleDerBytes), 0);
    }

    #[test]
    fn test_new_with_normalizes_reconnect_config() {
        // Verify that X509Source::new_with() normalizes reconnect config at the authoritative boundary.
        use super::super::builder::{ReconnectConfig, ResourceLimits};
        use crate::workload_api::x509_context::X509Context;
        use crate::{X509BundleSet, X509Svid};
        use std::sync::Arc;
        use std::time::Duration;

        // Load test fixture SVID
        let cert_bytes = include_bytes!("../../tests/testdata/svid/x509/1-svid-chain.der");
        let key_bytes = include_bytes!("../../tests/testdata/svid/x509/1-key.der");
        let svid = Arc::new(X509Svid::parse_from_der(cert_bytes, key_bytes).unwrap());

        // Create a context with valid SVID and bundle
        let ctx = X509Context::new([svid], Arc::new(X509BundleSet::new()));

        // Create reconnect config with inverted min/max (min > max)
        let inverted_reconnect = ReconnectConfig {
            min_backoff: Duration::from_secs(10),
            max_backoff: Duration::from_secs(1),
        };

        // Create source using test seam with inverted reconnect config
        let source = X509Source::new_for_test(
            Arc::new(ctx),
            inverted_reconnect,
            ResourceLimits::default(),
            None,
            None,
        );

        // Verify that reconnect config was normalized (swapped)
        assert_eq!(source.inner.reconnect.min_backoff, Duration::from_secs(1));
        assert_eq!(source.inner.reconnect.max_backoff, Duration::from_secs(10));
    }

    #[test]
    fn test_initial_sync_validation_records_correct_metrics() {
        // Verify that validation records limit metrics and NoSuitableSvid,
        // but does NOT record UpdateRejected (that's recorded by apply_update).
        use super::super::builder::ResourceLimits;
        use super::super::limits::validate_context;
        use crate::workload_api::x509_context::X509Context;
        use crate::{TrustDomain, X509Bundle, X509BundleSet, X509Svid};
        use std::sync::Arc;

        // Load test fixture SVID
        let cert_bytes = include_bytes!("../../tests/testdata/svid/x509/1-svid-chain.der");
        let key_bytes = include_bytes!("../../tests/testdata/svid/x509/1-key.der");
        let svid = Arc::new(X509Svid::parse_from_der(cert_bytes, key_bytes).unwrap());

        let metrics = Arc::new(TestMetricsRecorder::new());
        let limits = ResourceLimits {
            max_svids: Some(100),
            max_bundles: Some(0), // Limit that will be exceeded
            max_bundle_der_bytes: Some(1000),
        };

        // Create a context with 1 bundle (exceeds max_bundles=0)
        let trust_domain = TrustDomain::new("example.org").unwrap();
        let bundle = X509Bundle::new(trust_domain);
        let mut bundle_set = X509BundleSet::new();
        bundle_set.add_bundle(bundle);

        let ctx = X509Context::new([svid], Arc::new(bundle_set));

        // Validate context (simulating validation used in both initial sync and updates)
        let result = validate_context(
            &ctx,
            None, // No picker
            limits,
            Some(metrics.as_ref()),
        );

        // Should fail with ResourceLimitExceeded
        assert!(matches!(
            result,
            Err(X509SourceError::ResourceLimitExceeded {
                kind: super::super::errors::LimitKind::MaxBundles,
                ..
            })
        ));

        // Verify limit metric was recorded
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundles), 1);
        // Verify UpdateRejected was NOT recorded (that's recorded by apply_update, not validate_context)
        assert_eq!(metrics.count(MetricsErrorKind::UpdateRejected), 0);
        // Verify no other limit metrics were recorded
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxSvids), 0);
        assert_eq!(metrics.count(MetricsErrorKind::LimitMaxBundleDerBytes), 0);
    }

    #[test]
    fn test_resource_limits_unlimited() {
        // Verify that ResourceLimits::unlimited() creates limits with all fields set to None.
        use super::super::builder::ResourceLimits;

        let unlimited = ResourceLimits::unlimited();
        assert_eq!(unlimited.max_svids, None);
        assert_eq!(unlimited.max_bundles, None);
        assert_eq!(unlimited.max_bundle_der_bytes, None);
    }

    #[test]
    fn test_resource_limits_default_limits() {
        // Verify that ResourceLimits::default_limits() creates limits with conservative defaults.
        use super::super::builder::ResourceLimits;

        let limits = ResourceLimits::default_limits();
        assert_eq!(limits.max_svids, Some(100));
        assert_eq!(limits.max_bundles, Some(200));
        assert_eq!(limits.max_bundle_der_bytes, Some(4 * 1024 * 1024)); // 4MB
    }

    #[test]
    fn test_resource_limits_mixed() {
        // Verify that ResourceLimits can have mixed unlimited and limited fields.
        use super::super::builder::ResourceLimits;

        let mixed = ResourceLimits {
            max_svids: Some(50),
            max_bundles: None,                       // Unlimited
            max_bundle_der_bytes: Some(1024 * 1024), // 1MB
        };

        assert_eq!(mixed.max_svids, Some(50));
        assert_eq!(mixed.max_bundles, None);
        assert_eq!(mixed.max_bundle_der_bytes, Some(1024 * 1024));
    }
}
