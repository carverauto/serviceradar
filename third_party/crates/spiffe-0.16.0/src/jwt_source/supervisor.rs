use super::builder::{ReconnectConfig, ResourceLimits};
use super::errors::{JwtSourceError, MetricsErrorKind};
use super::limits::validate_bundle_set;
use super::metrics::MetricsRecorder;
use super::source::Inner;
use super::types::ClientFactory;
use crate::bundle::jwt::JwtBundleSet;
use crate::prelude::{debug, info, warn};
use crate::workload_api::error::WorkloadApiError;
use crate::workload_api::supervisor_common::{
    self, ErrorKey, ErrorTracker, StreamPhase, MAX_CONSECUTIVE_SAME_ERROR,
};
use crate::workload_api::WorkloadApiClient;
use futures::StreamExt as _;
use std::sync::Arc;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

/// Attempts to create a Workload API client.
///
/// Records metrics and logs errors.
///
/// On error, records `ClientCreation` metric. The caller should call `record_reconnect`
/// for steady-state reconnections (not for initial sync).
pub(super) async fn try_create_client(
    make_client: &ClientFactory,
    backoff: Duration,
    error_tracker: &mut ErrorTracker,
    metrics: Option<&dyn MetricsRecorder>,
) -> Result<WorkloadApiClient, WorkloadApiError> {
    match (make_client)().await {
        Ok(c) => {
            // Only log recovery if there were significant consecutive failures (>= 3) of the same type
            if error_tracker.last_error_kind() == Some(ErrorKey::ClientCreation)
                && error_tracker.consecutive_count() >= 3
            {
                debug!(
                    "Client creation recovered after {} consecutive failures",
                    error_tracker.consecutive_count()
                );
            }
            // Only reset tracker if the last error was client creation (actual recovery).
            // Don't reset if tracking stream connection errors (e.g., NoIdentityIssued).
            if error_tracker.last_error_kind() == Some(ErrorKey::ClientCreation) {
                error_tracker.reset();
            }
            Ok(c)
        }
        Err(e) => {
            let error_kind = ErrorKey::ClientCreation;
            let should_warn = error_tracker.record_error(error_kind);

            if should_warn {
                warn!(
                    "Failed to create WorkloadApiClient; retrying: error={}, backoff_ms={}",
                    e,
                    backoff.as_millis()
                );
            } else {
                debug!(
                    "Failed to create WorkloadApiClient (repeated); retrying: error={}, backoff_ms={}, consecutive_failures={}",
                    e,
                    backoff.as_millis(),
                    error_tracker.consecutive_count()
                );
            }

            if let Some(m) = metrics {
                m.record_error(MetricsErrorKind::ClientCreation);
            }
            Err(e)
        }
    }
}

/// Attempts to connect to the JWT bundle stream.
///
/// Records metrics and logs errors. Does not modify backoff (caller manages backoff progression).
///
/// On error, records `StreamConnect` metric. The caller should call `record_reconnect`
/// for steady-state reconnections (not for initial sync).
pub(super) async fn try_connect_stream(
    client: &WorkloadApiClient,
    backoff: Duration,
    error_tracker: &mut ErrorTracker,
    metrics: Option<&dyn MetricsRecorder>,
    phase: StreamPhase,
    supervisor_id: Option<u64>,
) -> Result<
    impl futures::Stream<Item = Result<JwtBundleSet, WorkloadApiError>> + Send + 'static + use<>,
    WorkloadApiError,
> {
    match client.stream_jwt_bundles().await {
        Ok(s) => {
            let id_suffix = supervisor_id.map_or_else(String::new, |id| format!(", id={id}"));

            // Only log recovery if the last error was a stream connection failure
            if error_tracker.last_error_kind() == Some(ErrorKey::StreamConnect)
                && error_tracker.consecutive_count() > 0
            {
                info!(
                    "Stream connection recovered after {} consecutive failures (phase={:?}{})",
                    error_tracker.consecutive_count(),
                    phase,
                    id_suffix
                );
            }
            error_tracker.reset();
            info!(
                "Connected to Workload API JWT bundle stream (phase={:?}{})",
                phase, id_suffix
            );
            Ok(s)
        }
        Err(e) => {
            // Handle "no identity issued" as a distinct transient state
            if matches!(e, WorkloadApiError::NoIdentityIssued) {
                let error_kind = ErrorKey::NoIdentityIssued;
                let should_warn = error_tracker.record_error(error_kind);

                if should_warn {
                    warn!("No identity issued yet; waiting before retry");
                } else {
                    debug!(
                        "No identity issued yet (repeated); waiting before retry: consecutive_failures={}",
                        error_tracker.consecutive_count()
                    );
                }

                // Don't record this as a stream error metric (it's expected/transient)
                return Err(e);
            }

            let error_kind = ErrorKey::StreamConnect;
            let should_warn = error_tracker.record_error(error_kind);

            if should_warn {
                warn!(
                    "Failed to connect to Workload API stream; retrying: error={}, backoff_ms={}",
                    e,
                    backoff.as_millis()
                );
            } else {
                debug!(
                    "Failed to connect to Workload API stream (repeated); retrying: error={}, backoff_ms={}, consecutive_failures={}",
                    e,
                    backoff.as_millis(),
                    error_tracker.consecutive_count()
                );
            }

            if let Some(m) = metrics {
                m.record_error(MetricsErrorKind::StreamConnect);
            }
            Err(e)
        }
    }
}

pub(super) async fn initial_sync_with_retry(
    make_client: &ClientFactory,
    cancel: &CancellationToken,
    reconnect: ReconnectConfig,
    limits: ResourceLimits,
    metrics: Option<&dyn MetricsRecorder>,
) -> Result<Arc<JwtBundleSet>, JwtSourceError> {
    let mut backoff = reconnect.min_backoff;
    let mut error_tracker = ErrorTracker::new(MAX_CONSECUTIVE_SAME_ERROR);

    loop {
        if cancel.is_cancelled() {
            return Err(JwtSourceError::Closed);
        }

        match try_sync_once(make_client, limits, metrics, backoff, &mut error_tracker).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                // Record InitialSyncFailed as an umbrella metric for any failed attempt.
                // Specific metrics (ClientCreation, StreamConnect, StreamError, StreamEnded,
                // LimitMaxBundles, LimitMaxBundleJwksBytes) are already recorded in try_sync_once().
                // Detailed logs are also produced by try_create_client/try_connect_stream/stream read,
                // so we avoid duplicate outer logs here to reduce noise.
                if let Some(m) = metrics {
                    m.record_error(MetricsErrorKind::InitialSyncFailed);
                }
                if sleep_or_cancel(cancel, backoff).await {
                    return Err(JwtSourceError::Closed);
                }
                // Choose backoff policy based on error type
                match &e {
                    JwtSourceError::Source(WorkloadApiError::NoIdentityIssued) => {
                        // Use slower backoff for "no identity issued" (expected transient state)
                        backoff = next_backoff_for_no_identity(backoff, reconnect.max_backoff);
                        warn!(
                            "Initial sync: no identity issued, using backoff_ms={}",
                            backoff.as_millis()
                        );
                    }
                    _ => {
                        // Use standard exponential backoff for other errors
                        backoff = next_backoff(backoff, reconnect.max_backoff);
                    }
                }
            }
        }
    }
}

async fn try_sync_once(
    make_client: &ClientFactory,
    limits: ResourceLimits,
    metrics: Option<&dyn MetricsRecorder>,
    backoff: Duration,
    error_tracker: &mut ErrorTracker,
) -> Result<Arc<JwtBundleSet>, JwtSourceError> {
    // Use shared client creation logic (records ClientCreation metric on failure).
    // Initial sync does not record reconnect metrics (it's not a reconnect).
    let client = match try_create_client(make_client, backoff, error_tracker, metrics).await {
        Ok(c) => c,
        Err(e) => {
            return Err(JwtSourceError::Source(e));
        }
    };

    // Use shared stream connection logic (records StreamConnect metric on failure).
    let mut stream = match try_connect_stream(
        &client,
        backoff,
        error_tracker,
        metrics,
        StreamPhase::InitialSync,
        None,
    )
    .await
    {
        Ok(s) => s,
        Err(e) => {
            return Err(JwtSourceError::Source(e));
        }
    };

    match stream.next().await {
        Some(Ok(bundle_set)) => {
            validate_bundle_set(&bundle_set, limits, metrics).inspect_err(|e| {
                warn!("Initial JWT bundle set rejected; will retry: error={e}");
            })?;

            Ok(Arc::new(bundle_set))
        }
        Some(Err(e)) => {
            // Record StreamError for stream read errors.
            warn!("Initial sync: Workload API stream error; will retry: error={e}");
            if let Some(m) = metrics {
                m.record_error(MetricsErrorKind::StreamError);
            }
            Err(JwtSourceError::Source(e))
        }
        None => {
            // Record StreamEnded for empty stream.
            warn!("Initial sync: Workload API stream ended immediately; will retry");
            if let Some(m) = metrics {
                m.record_error(MetricsErrorKind::StreamEnded);
            }
            Err(JwtSourceError::StreamEnded)
        }
    }
}

pub(super) use supervisor_common::{next_backoff, next_backoff_for_no_identity, sleep_or_cancel};

/// Result of processing a stream of updates.
struct StreamResult {
    /// Whether the cancellation token was triggered.
    cancelled: bool,
    /// Whether at least one update was successfully applied.
    had_successful_update: bool,
}

impl Inner {
    pub(super) async fn run_update_supervisor(&self, cancellation_token: CancellationToken) {
        // Generate a unique supervisor ID for diagnostics (detects duplicate supervisors/repeated constructions).
        let supervisor_id = fastrand::u64(..);
        info!("Starting update supervisor: id={}", supervisor_id);

        let mut backoff = self.reconnect().min_backoff;
        let mut error_tracker = ErrorTracker::new(MAX_CONSECUTIVE_SAME_ERROR);

        loop {
            if cancellation_token.is_cancelled() {
                debug!("Cancellation signal received; stopping updates");
                return;
            }

            let Ok(client) = try_create_client(
                self.make_client(),
                backoff,
                &mut error_tracker,
                self.metrics(),
            )
            .await
            else {
                if self
                    .backoff_and_maybe_cancel(&cancellation_token, backoff)
                    .await
                {
                    return;
                }
                backoff = next_backoff(backoff, self.reconnect().max_backoff);
                continue;
            };

            match try_connect_stream(
                &client,
                backoff,
                &mut error_tracker,
                self.metrics(),
                StreamPhase::Supervisor,
                Some(supervisor_id),
            )
            .await
            {
                Ok(mut stream) => {
                    let result = self
                        .process_stream_updates(&mut stream, &cancellation_token, supervisor_id)
                        .await;
                    if result.cancelled {
                        return;
                    }

                    // Reset backoff only if we successfully processed at least one update,
                    // meaning the stream actually delivered useful data before failing.
                    if result.had_successful_update {
                        backoff = self.reconnect().min_backoff;
                    }

                    // Stream ended or errored. Sleep/backoff before retrying.
                    if self
                        .backoff_and_maybe_cancel(&cancellation_token, backoff)
                        .await
                    {
                        return;
                    }
                    if !result.had_successful_update {
                        backoff = next_backoff(backoff, self.reconnect().max_backoff);
                    }
                }
                Err(stream_err) => {
                    // Choose backoff policy based on error type
                    match stream_err {
                        WorkloadApiError::NoIdentityIssued => {
                            // Use slower backoff for "no identity issued" (expected transient state)
                            backoff =
                                next_backoff_for_no_identity(backoff, self.reconnect().max_backoff);
                            warn!(
                                "No identity issued: using backoff_ms={}",
                                backoff.as_millis()
                            );
                        }
                        _ => {
                            // Use standard exponential backoff for other errors
                            backoff = next_backoff(backoff, self.reconnect().max_backoff);
                        }
                    }

                    if self
                        .backoff_and_maybe_cancel(&cancellation_token, backoff)
                        .await
                    {
                        return;
                    }
                }
            }
        }
    }

    async fn backoff_and_maybe_cancel(&self, token: &CancellationToken, backoff: Duration) -> bool {
        if let Some(metrics) = self.metrics() {
            metrics.record_reconnect();
        }
        sleep_or_cancel(token, backoff).await
    }

    /// Processes stream updates until the stream ends, errors, or cancellation is requested.
    async fn process_stream_updates(
        &self,
        stream: &mut (impl futures::Stream<Item = Result<JwtBundleSet, WorkloadApiError>>
                  + Unpin
                  + Send
                  + 'static),
        cancellation_token: &CancellationToken,
        supervisor_id: u64,
    ) -> StreamResult {
        let mut update_rejection_tracker = ErrorTracker::new(MAX_CONSECUTIVE_SAME_ERROR);
        let mut had_successful_update = false;

        loop {
            let item = tokio::select! {
                () = cancellation_token.cancelled() => {
                    debug!("Cancellation signal received; stopping update loop");
                    return StreamResult { cancelled: true, had_successful_update };
                }
                v = stream.next() => v,
            };

            match item {
                Some(Ok(bundle_set)) => {
                    match self.apply_update(Arc::new(bundle_set)) {
                        Ok(()) => {
                            had_successful_update = true;
                            if update_rejection_tracker.consecutive_count() > 0 {
                                info!(
                                    "Update validation recovered after {} consecutive failures",
                                    update_rejection_tracker.consecutive_count(),
                                );
                                update_rejection_tracker.reset();
                            }
                            info!("JWT bundle set updated");
                        }
                        Err(e) => {
                            let should_warn =
                                update_rejection_tracker.record_error(ErrorKey::UpdateRejected);

                            if should_warn {
                                warn!("Rejected JWT bundle set update: error={e}");
                            } else {
                                debug!(
                                    "Rejected JWT bundle set update (repeated): error={}, consecutive_rejections={}",
                                    e,
                                    update_rejection_tracker.consecutive_count()
                                );
                            }
                            // Metrics already recorded by apply_update(); do not double-count.
                        }
                    }
                }
                Some(Err(e)) => {
                    warn!("Workload API stream error; reconnecting: id={supervisor_id}, error={e}");
                    self.record_error(MetricsErrorKind::StreamError);
                    return StreamResult {
                        cancelled: false,
                        had_successful_update,
                    };
                }
                None => {
                    warn!("Workload API stream ended; reconnecting: id={supervisor_id}");
                    self.record_error(MetricsErrorKind::StreamEnded);
                    return StreamResult {
                        cancelled: false,
                        had_successful_update,
                    };
                }
            }
        }
    }
}
