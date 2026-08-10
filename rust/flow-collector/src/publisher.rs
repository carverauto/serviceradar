use crate::config::{Config, SecurityMode};
use crate::metrics::HostSliceMetricsRegistry;
use anyhow::{Context, Result};
use async_nats::jetstream::{
    self,
    context::PublishErrorKind,
    message::PublishMessage,
    stream::{DiscardPolicy, RetentionPolicy, StorageType},
};
use async_nats::{Client, ConnectOptions};
use log::{error, info, warn};
use std::cmp::min;
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TryRecvError;
use tokio::task::JoinSet;
use tokio::time::sleep;

/// Preferred JetStream de-duplication window for the dedicated flows stream.
/// Capped by max_age and the common NATS server limit (jetstream.limits.duplicate_window,
/// default 2m). Raising above the server limit fails stream create with 10052.
pub(crate) const PREFERRED_DUPLICATE_WINDOW_SECS: u64 = 120;
/// Operational upper bound on post-attempt retry age. Always also capped by the
/// verified stream duplicate_window. Prevents multi-hour HOL blocking when an
/// existing stream preserves a large window.
const MAX_OPERATIONAL_RETRY_AGE_SECS: u64 = 90;
/// TTL for messages that never reached send_publish (disconnect / channel hold).
/// Separate from the duplicate-window horizon — no duplicate risk until first send.
const NEVER_ATTEMPTED_QUEUE_TTL_SECS: u64 = 900;
/// Max concurrent JetStream publish+ACK futures (bounds worst-case pass time).
const PUBLISH_CONCURRENCY: usize = 32;

/// Flow publish channel item: subject, payload, and **ingress** time (UDP accept).
/// Ingress Instant is set at the listener so never-attempted TTL bounds total hold
/// across per-listener + shared queues, not only time spent in the publisher.
pub type OutboundFlow = (String, Vec<u8>, Instant);

/// NATS requires 0 < duplicate_window <= max_age when max_age is finite.
fn clamp_duplicate_window(desired: Duration, max_age: Duration) -> Duration {
    if max_age.is_zero() {
        // Unlimited retention — desired window is fine.
        desired
    } else if desired > max_age {
        max_age
    } else if desired.is_zero() {
        // Never set a zero window when we intend de-dup; use min(max_age, desired)
        // but desired is non-zero from DUPLICATE_WINDOW_SECS.
        max_age.min(Duration::from_secs(1))
    } else {
        desired
    }
}

pub struct Publisher {
    config: Arc<Config>,
    rx: mpsc::Receiver<OutboundFlow>,
    host_slice_metrics: Arc<HostSliceMetricsRegistry>,
    /// Subjects removed from `events` but not yet confirmed on the target stream.
    /// Preserved across connect retries so a failed restore cannot orphan extension subjects.
    pending_rehome: Vec<String>,
}

/// Outcome of one publish pass over a pending queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PublishPassResult {
    /// Finished a chunk. `succeeded` = ACKed; `retryable` = requeued failures.
    Completed { succeeded: usize, retryable: usize },
    /// Owned stream missing/unusable — readiness must clear and ensure re-run.
    StreamMissing,
    /// Client not Connected — caller must clear readiness.
    Disconnected,
}

impl Publisher {
    pub fn new(
        config: Arc<Config>,
        rx: mpsc::Receiver<OutboundFlow>,
        host_slice_metrics: Arc<HostSliceMetricsRegistry>,
    ) -> Self {
        Self {
            config,
            rx,
            host_slice_metrics,
            pending_rehome: Vec::new(),
        }
    }

    pub async fn run(mut self) -> Result<()> {
        // Never inherit a previous pod/process readiness or half-written marker.
        clear_publisher_ready(&self.config)?;
        // verified_dup_window comes from stream ensure INFO — never invent a fallback
        // that could exceed the real window (unsafe for retry age).
        // admin_js: control-plane (INFO/CREATE/UPDATE) with default API timeout.
        // publish_js: data path only; ACK timeout = publish_timeout_ms.
        let (client, admin_js, publish_js, verified_dup_window) = self.connect_with_retry().await?;
        let mut max_retry_age = max_retry_age_from_window(verified_dup_window);
        mark_publisher_ready(&self.config)?;
        let mut publisher_ready = true;

        let max_retry_queue = self
            .config
            .channel_size
            .max(self.config.batch_size.saturating_mul(4));
        let mut retry_q: VecDeque<PendingPublish> = VecDeque::new();
        // Independent of fresh-traffic success — only no-progress retry passes
        // advance exponential backoff.
        let mut next_retry_at = Instant::now();
        let mut retry_backoff = Duration::from_millis(100);
        let max_backoff = Duration::from_secs(5);
        info!(
            "Publisher started (dup_window={:?}, max_retry_age={:?}, never_attempted_ttl={:?}, concurrency={})",
            verified_dup_window,
            max_retry_age,
            Duration::from_secs(NEVER_ATTEMPTED_QUEUE_TTL_SECS),
            PUBLISH_CONCURRENCY
        );

        loop {
            // Clear readiness while disconnected so kube endpoints stop sending
            // UDP to a collector that cannot publish; re-ensure after reconnect.
            let connected = matches!(
                client.connection_state(),
                async_nats::connection::State::Connected
            );
            if !connected {
                if publisher_ready {
                    warn!("NATS disconnected; clearing readiness marker");
                    clear_publisher_ready(&self.config)?;
                    publisher_ready = false;
                }
            } else if !publisher_ready {
                self.recover_owned_stream(&client, &admin_js, &mut max_retry_age, "reconnect")
                    .await?;
                publisher_ready = true;
            }

            expire_old_retries(&mut retry_q, max_retry_age);

            // Interleave: non-blocking drain of fresh traffic first so retries
            // never head-of-line block the listener channels for the full window.
            let (mut batch, closed) = self.drain_fresh_batch();
            if batch.is_empty() && !closed {
                let wait_retry = !retry_q.is_empty();
                let retry_wait = next_retry_at.saturating_duration_since(Instant::now());
                if !wait_retry {
                    match self.rx.recv().await {
                        Some(msg) => {
                            batch.push(PendingPublish::from_outbound(msg));
                            let (more, more_closed) = self.drain_fresh_batch();
                            batch.extend(more);
                            if more_closed {
                                self.handle_publish_pass(
                                    &client,
                                    &admin_js,
                                    &publish_js,
                                    &mut batch,
                                    &mut retry_q,
                                    max_retry_queue,
                                    &mut max_retry_age,
                                    &mut publisher_ready,
                                    &mut next_retry_at,
                                    &mut retry_backoff,
                                    max_backoff,
                                    true,
                                )
                                .await?;
                                return self
                                    .drain_retries_until_empty(
                                        &client,
                                        &admin_js,
                                        &publish_js,
                                        &mut retry_q,
                                        &mut max_retry_age,
                                        &mut publisher_ready,
                                    )
                                    .await;
                            }
                        }
                        None => {
                            return self
                                .drain_retries_until_empty(
                                    &client,
                                    &admin_js,
                                    &publish_js,
                                    &mut retry_q,
                                    &mut max_retry_age,
                                    &mut publisher_ready,
                                )
                                .await;
                        }
                    }
                } else {
                    // Wait for either fresh work or independent retry schedule.
                    tokio::select! {
                        msg = self.rx.recv() => {
                            match msg {
                                Some(m) => {
                                    batch.push(PendingPublish::from_outbound(m));
                                    let (more, _) = self.drain_fresh_batch();
                                    batch.extend(more);
                                }
                                None => {
                                    return self
                                        .drain_retries_until_empty(
                                            &client,
                                            &admin_js,
                                            &publish_js,
                                            &mut retry_q,
                                            &mut max_retry_age,
                                            &mut publisher_ready,
                                        )
                                        .await;
                                }
                            }
                        }
                        _ = sleep(retry_wait) => {}
                    }
                }
            }

            if !batch.is_empty() {
                self.handle_publish_pass(
                    &client,
                    &admin_js,
                    &publish_js,
                    &mut batch,
                    &mut retry_q,
                    max_retry_queue,
                    &mut max_retry_age,
                    &mut publisher_ready,
                    &mut next_retry_at,
                    &mut retry_backoff,
                    max_backoff,
                    false, // fresh pass does not drive retry backoff schedule
                )
                .await?;
            }

            if !retry_q.is_empty() && Instant::now() >= next_retry_at {
                self.handle_publish_pass(
                    &client,
                    &admin_js,
                    &publish_js,
                    &mut Vec::new(), // empty fresh; drain retry_q directly
                    &mut retry_q,
                    max_retry_queue,
                    &mut max_retry_age,
                    &mut publisher_ready,
                    &mut next_retry_at,
                    &mut retry_backoff,
                    max_backoff,
                    true,
                )
                .await?;
            }

            if closed {
                return self
                    .drain_retries_until_empty(
                        &client,
                        &admin_js,
                        &publish_js,
                        &mut retry_q,
                        &mut max_retry_age,
                        &mut publisher_ready,
                    )
                    .await;
            }
        }
    }

    /// Publish `batch` (if any) then one chunk of `retry_q`, updating readiness
    /// and retry schedule from pass stats.
    #[allow(clippy::too_many_arguments)]
    async fn handle_publish_pass(
        &self,
        client: &Client,
        admin_js: &jetstream::Context,
        publish_js: &jetstream::Context,
        batch: &mut Vec<PendingPublish>,
        retry_q: &mut VecDeque<PendingPublish>,
        max_retry_queue: usize,
        max_retry_age: &mut Duration,
        publisher_ready: &mut bool,
        next_retry_at: &mut Instant,
        retry_backoff: &mut Duration,
        max_backoff: Duration,
        drive_retry_schedule: bool,
    ) -> Result<()> {
        // Merge fresh batch into a local pending for one pass, or process retry_q.
        let result = if !batch.is_empty() {
            self.publish_and_requeue(
                client,
                publish_js,
                batch,
                retry_q,
                max_retry_queue,
                *max_retry_age,
            )
            .await
        } else {
            wait_until_connected(client).await;
            self.publish_pending(client, publish_js, retry_q, *max_retry_age)
                .await
        };

        match result {
            PublishPassResult::StreamMissing => {
                self.recover_owned_stream(client, admin_js, max_retry_age, "stream missing")
                    .await?;
                *publisher_ready = true;
                if drive_retry_schedule {
                    *next_retry_at = Instant::now() + *retry_backoff;
                }
            }
            PublishPassResult::Disconnected => {
                if *publisher_ready {
                    clear_publisher_ready(&self.config)?;
                    *publisher_ready = false;
                }
                if drive_retry_schedule {
                    *retry_backoff = min(retry_backoff.saturating_mul(2), max_backoff);
                    *next_retry_at = Instant::now() + *retry_backoff;
                }
            }
            PublishPassResult::Completed {
                succeeded,
                retryable,
            } => {
                if !drive_retry_schedule {
                    return Ok(());
                }
                // Progress: at least one ACK → process next chunk immediately.
                // No progress with retryable failures → exponential backoff.
                if succeeded > 0 {
                    *next_retry_at = Instant::now();
                    if retry_q.is_empty() {
                        *retry_backoff = Duration::from_millis(100);
                    }
                } else if retryable > 0 || !retry_q.is_empty() {
                    *retry_backoff = min(retry_backoff.saturating_mul(2), max_backoff);
                    *next_retry_at = Instant::now() + *retry_backoff;
                } else {
                    *retry_backoff = Duration::from_millis(100);
                    *next_retry_at = Instant::now();
                }
            }
        }
        Ok(())
    }

    fn drain_fresh_batch(&mut self) -> (Vec<PendingPublish>, bool) {
        let mut batch = Vec::with_capacity(self.config.batch_size);
        let mut closed = false;
        while batch.len() < self.config.batch_size {
            match self.rx.try_recv() {
                Ok(msg) => batch.push(PendingPublish::from_outbound(msg)),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    closed = true;
                    break;
                }
            }
        }
        (batch, closed)
    }

    async fn publish_and_requeue(
        &self,
        client: &Client,
        publish_js: &jetstream::Context,
        batch: &mut Vec<PendingPublish>,
        retry_q: &mut VecDeque<PendingPublish>,
        max_retry_queue: usize,
        max_retry_age: Duration,
    ) -> PublishPassResult {
        if batch.is_empty() {
            return PublishPassResult::Completed {
                succeeded: 0,
                retryable: 0,
            };
        }
        let mut pending: VecDeque<PendingPublish> = std::mem::take(batch).into();
        wait_until_connected(client).await;
        let result = self
            .publish_pending(client, publish_js, &mut pending, max_retry_age)
            .await;
        while let Some(item) = pending.pop_front() {
            if retry_q.len() >= max_retry_queue {
                warn!(
                    "Publish retry queue full ({}); dropping oldest failed publish",
                    max_retry_queue
                );
                retry_q.pop_front();
            }
            retry_q.push_back(item);
        }
        result
    }

    async fn drain_retries_until_empty(
        &self,
        client: &Client,
        admin_js: &jetstream::Context,
        publish_js: &jetstream::Context,
        retry_q: &mut VecDeque<PendingPublish>,
        max_retry_age: &mut Duration,
        publisher_ready: &mut bool,
    ) -> Result<()> {
        let mut backoff = Duration::from_millis(100);
        let max_backoff = Duration::from_secs(5);
        let mut attempts = 0u32;
        while !retry_q.is_empty() {
            expire_old_retries(retry_q, *max_retry_age);
            if retry_q.is_empty() {
                break;
            }
            attempts += 1;
            wait_until_connected(client).await;
            match self
                .publish_pending(client, publish_js, retry_q, *max_retry_age)
                .await
            {
                PublishPassResult::StreamMissing => {
                    self.recover_owned_stream(client, admin_js, max_retry_age, "shutdown drain")
                        .await?;
                    *publisher_ready = true;
                    // Progress may resume after re-ensure — do not sleep yet.
                    continue;
                }
                PublishPassResult::Disconnected => {
                    if *publisher_ready {
                        clear_publisher_ready(&self.config)?;
                        *publisher_ready = false;
                    }
                    sleep(backoff).await;
                    backoff = min(backoff.saturating_mul(2), max_backoff);
                }
                PublishPassResult::Completed {
                    succeeded,
                    retryable,
                } => {
                    if retry_q.is_empty() {
                        break;
                    }
                    // Immediate next chunk after successful ACKs; back off only
                    // when the pass made no progress.
                    if succeeded > 0 {
                        backoff = Duration::from_millis(100);
                        continue;
                    }
                    if retryable > 0 {
                        sleep(backoff).await;
                        backoff = min(backoff.saturating_mul(2), max_backoff);
                    }
                }
            }
            if attempts >= 500 {
                return Err(anyhow::anyhow!(
                    "publisher shutting down with {} unacked flow message(s)",
                    retry_q.len()
                ));
            }
        }
        info!("Publisher channel closed, shutting down");
        Ok(())
    }

    /// Clear readiness, re-verify owned stream ownership, then re-assert ready.
    async fn recover_owned_stream(
        &self,
        client: &Client,
        admin_js: &jetstream::Context,
        max_retry_age: &mut Duration,
        reason: &str,
    ) -> Result<()> {
        error!("Owned JetStream stream unavailable ({reason}); clearing ready and re-ensuring");
        clear_publisher_ready(&self.config)?;
        wait_until_connected(client).await;
        let window = self.ensure_owned_stream(admin_js).await?;
        *max_retry_age = max_retry_age_from_window(window);
        mark_publisher_ready(&self.config)?;
        info!(
            "Stream re-ensure complete (dup_window={:?}, max_retry_age={:?})",
            window, *max_retry_age
        );
        Ok(())
    }

    async fn ensure_owned_stream(&self, admin_js: &jetstream::Context) -> Result<Duration> {
        let desired_max_age = Duration::from_secs(self.config.stream_max_age_secs);
        let mut subjects = self.config.stream_subjects_resolved();
        // Recover post-cutover ownership (includes migrated extension subjects
        // that are no longer in live config / pending_rehome).
        let ownership_path = ownership_state_path(&self.config);
        if let Some(inv) = load_ownership_inventory(&ownership_path)?
            && inv.stream == self.config.stream_name
        {
            for s in inv.subjects {
                if !subjects.iter().any(|x| x == &s) {
                    subjects.push(s);
                }
            }
        }
        // In-progress rehome marker still applies during cutover recovery.
        let rehome_path = rehome_state_path(&self.config);
        if let Some(marker) = load_rehome_marker(&rehome_path)? {
            for s in marker.subjects {
                if !subjects.iter().any(|x| x == &s) {
                    subjects.push(s);
                }
            }
        }
        subjects = normalize_stream_subjects(subjects);

        if self.config.stream_name == "events" {
            return ensure_legacy_events_subjects_only(admin_js, &subjects).await;
        }
        let window = ensure_flows_stream(
            admin_js,
            &self.config.stream_name,
            &subjects,
            self.config.stream_max_bytes,
            desired_max_age,
            self.config.stream_replicas,
        )
        .await?;
        write_ownership_inventory(
            &ownership_path,
            &OwnershipInventory {
                stream: self.config.stream_name.clone(),
                subjects: subjects.clone(),
            },
        )?;
        Ok(window)
    }

    async fn publish_pending(
        &self,
        client: &Client,
        publish_js: &jetstream::Context,
        pending: &mut VecDeque<PendingPublish>,
        max_retry_age: Duration,
    ) -> PublishPassResult {
        // Never enqueue publishes while disconnected — async-nats buffers
        // Command::Request across reconnect and cannot cancel timed-out futures.
        if !matches!(
            client.connection_state(),
            async_nats::connection::State::Connected
        ) {
            warn!(
                "NATS not connected; deferring {} publish(es)",
                pending.len()
            );
            return PublishPassResult::Disconnected;
        }
        let limit = pending.len().min(self.config.batch_size.max(1));
        if limit == 0 {
            return PublishPassResult::Completed {
                succeeded: 0,
                retryable: 0,
            };
        }

        let mut batch = Vec::with_capacity(limit);
        for _ in 0..limit {
            if let Some(item) = pending.pop_front() {
                batch.push(item);
            }
        }

        let semaphore = std::sync::Arc::new(Semaphore::new(PUBLISH_CONCURRENCY));
        let mut set = JoinSet::new();

        for item in batch {
            let js = publish_js.clone();
            let client = client.clone();
            let sem = semaphore.clone();
            let metrics = self.host_slice_metrics.clone();
            set.spawn(async move {
                if past_retry_horizon(&item, max_retry_age) {
                    error!(
                        "Dropping publish for subject {} id={} at send ({})",
                        item.subject,
                        item.msg_id,
                        horizon_reason(&item, max_retry_age)
                    );
                    return TaskOutcome::Done;
                }
                let _permit = match sem.acquire_owned().await {
                    Ok(p) => p,
                    Err(_) => return TaskOutcome::Retry(item),
                };
                if past_retry_horizon(&item, max_retry_age) {
                    error!(
                        "Dropping publish for subject {} id={} after permit wait ({})",
                        item.subject,
                        item.msg_id,
                        horizon_reason(&item, max_retry_age)
                    );
                    return TaskOutcome::Done;
                }
                let bytes = item.payload.len();
                let publish = PublishMessage::build()
                    .payload(item.payload.clone().into())
                    .message_id(item.msg_id.clone());

                // Refuse to buffer publishes while disconnected.
                if !matches!(
                    client.connection_state(),
                    async_nats::connection::State::Connected
                ) {
                    warn!(
                        "NATS disconnected before publish of subject {} id={}; will retry",
                        item.subject, item.msg_id
                    );
                    return TaskOutcome::Retry(item);
                }

                match js.send_publish(item.subject.clone(), publish).await {
                    Ok(ack_fut) => {
                        // Command::Request is in the async-nats client channel —
                        // not yet a confirmed store. Classify ACK carefully.
                        let item = item.mark_attempted();
                        match ack_fut.await {
                            Ok(_seq) => {
                                metrics.record_publish(&item.subject, bytes);
                                TaskOutcome::Done
                            }
                            Err(e) => {
                                let disposition = classify_publish_error(e.kind());
                                match disposition {
                                    PublishDisposition::StreamMissing => {
                                        error!(
                                            "NATS stream missing for subject {} id={}: {} — preserving and re-ensuring",
                                            item.subject, item.msg_id, e
                                        );
                                        TaskOutcome::StreamMissing(item.clear_attempt())
                                    }
                                    PublishDisposition::Permanent => {
                                        error!(
                                            "Permanent NATS publish failure for subject {} id={}: {} — dropping",
                                            item.subject, item.msg_id, e
                                        );
                                        TaskOutcome::Done
                                    }
                                    PublishDisposition::Negative | PublishDisposition::Transient => {
                                        // Explicit negative ACK or backpressure —
                                        // server did not store; safe to retry.
                                        warn!(
                                            "NATS publish {} for subject {} id={}: {} — will retry",
                                            disposition_label(disposition),
                                            item.subject,
                                            item.msg_id,
                                            e
                                        );
                                        TaskOutcome::Retry(item.clear_attempt())
                                    }
                                    PublishDisposition::Ambiguous => {
                                        // TimedOut/BrokenPipe: may still be in the
                                        // client/socket buffer. Requeue only after
                                        // force_reconnect abandons that buffer so a
                                        // later flush cannot double-store past the
                                        // duplicate_window.
                                        warn!(
                                            "NATS publish ACK ambiguous for subject {} id={}: {} — will force-reconnect then retry",
                                            item.subject, item.msg_id, e
                                        );
                                        TaskOutcome::Ambiguous(item)
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => {
                        // send_publish failed before/without a durable enqueue —
                        // safe to requeue when not permanent.
                        match classify_publish_error(e.kind()) {
                            PublishDisposition::StreamMissing => {
                                error!(
                                    "NATS stream missing on send for subject {} id={}: {} — preserving",
                                    item.subject, item.msg_id, e
                                );
                                TaskOutcome::StreamMissing(item)
                            }
                            PublishDisposition::Permanent => {
                                error!(
                                    "Permanent NATS send failure for subject {} id={}: {} — dropping",
                                    item.subject, item.msg_id, e
                                );
                                TaskOutcome::Done
                            }
                            _ => {
                                error!(
                                    "Failed to publish to NATS subject {} id={}: {} — will retry",
                                    item.subject, item.msg_id, e
                                );
                                TaskOutcome::Retry(item)
                            }
                        }
                    }
                }
            });
        }

        let mut failed = VecDeque::new();
        let mut ambiguous = VecDeque::new();
        let mut stream_missing = false;
        let mut succeeded = 0usize;
        while let Some(joined) = set.join_next().await {
            match joined {
                Ok(TaskOutcome::Done) => succeeded += 1,
                Ok(TaskOutcome::Retry(item)) => failed.push_back(item),
                Ok(TaskOutcome::Ambiguous(item)) => ambiguous.push_back(item),
                Ok(TaskOutcome::StreamMissing(item)) => {
                    stream_missing = true;
                    failed.push_back(item);
                }
                Err(e) => error!("publish task join error: {}", e),
            }
        }

        // Abandon client-buffered ambiguous publishes before requeueing them.
        if !ambiguous.is_empty() {
            warn!(
                "Force-reconnecting NATS to abandon {} ambiguous in-flight publish(es)",
                ambiguous.len()
            );
            if let Err(e) = client.force_reconnect().await {
                error!("force_reconnect failed: {e}");
            }
            wait_until_connected(client).await;
            while let Some(item) = ambiguous.pop_front() {
                // Still within first_attempt horizon for Msg-Id dedup if the
                // original was stored before the socket was dropped.
                if past_retry_horizon(&item, max_retry_age) {
                    error!(
                        "Dropping ambiguous publish for subject {} id={} after reconnect ({})",
                        item.subject,
                        item.msg_id,
                        horizon_reason(&item, max_retry_age)
                    );
                } else {
                    failed.push_back(item);
                }
            }
        }

        let retryable = failed.len();
        // Preserve remaining unattempted (if any) then failures.
        failed.append(pending);
        *pending = failed;
        if stream_missing {
            PublishPassResult::StreamMissing
        } else {
            PublishPassResult::Completed {
                succeeded,
                retryable,
            }
        }
    }

    async fn connect_once(
        &mut self,
    ) -> Result<(Client, jetstream::Context, jetstream::Context, Duration)> {
        let mut options = ConnectOptions::new();

        if let Some(sec) = &self.config.security {
            match sec.mode {
                SecurityMode::Mtls => {
                    if let Some(ca_path) = sec.ca_file_path() {
                        options = options.add_root_certificates(ca_path);
                    }
                    if let (Some(cert_path), Some(key_path)) =
                        (sec.cert_file_path(), sec.key_file_path())
                    {
                        options = options.add_client_certificate(cert_path, key_path);
                    }
                }
                SecurityMode::None => {}
            }
        }

        if let Some(creds_file) = &self.config.nats_creds_file {
            options = options
                .credentials_file(creds_file)
                .await
                .with_context(|| format!("Failed to load NATS creds file {}", creds_file))?;
        }

        let client = options.connect(&self.config.nats_url).await?;
        // Control-plane context keeps the library default API timeout so a low
        // publish_timeout_ms cannot spuriously fail stream INFO/CREATE/UPDATE.
        let admin_js = jetstream::new(client.clone());
        // Data-path context: PublishAckFuture timeout only.
        let mut publish_js = jetstream::new(client.clone());
        let ack_timeout = Duration::from_millis(self.config.publish_timeout_ms.max(1_000));
        publish_js.set_timeout(ack_timeout);

        let required_subjects = self.config.stream_subjects_resolved();
        let desired_max_age = Duration::from_secs(self.config.stream_max_age_secs);
        let rehome_path = rehome_state_path(&self.config);

        // Recover durable rehome marker — always union subjects, even on target mismatch
        // (e.g. crash after detach then Helm rollback to stream_name=events).
        if let Some(marker) = load_rehome_marker(&rehome_path)? {
            for subject in &marker.subjects {
                if !self.pending_rehome.iter().any(|s| s == subject) {
                    self.pending_rehome.push(subject.clone());
                }
            }
            info!(
                "Loaded {} subject(s) from durable rehome marker at {} (marker_target={}, config_stream={})",
                self.pending_rehome.len(),
                rehome_path.display(),
                marker.target_stream,
                self.config.stream_name
            );

            if marker.target_stream != self.config.stream_name {
                warn!(
                    "Rehome marker target '{}' differs from configured stream '{}'; transferring recorded subjects",
                    marker.target_stream, self.config.stream_name
                );
            }
        }

        if self.config.stream_name == "events" {
            // Legacy / rollback: restore every unresolved marker subject onto events
            // (required_subjects alone would drop extension subjects).
            let mut restore = required_subjects.clone();
            for s in &self.pending_rehome {
                if !restore.iter().any(|r| r == s) {
                    restore.push(s.clone());
                }
            }
            // Wildcard + exact subjects from a prior rehome marker must not form a
            // self-overlapping list (NATS 10052).
            restore = normalize_stream_subjects(restore);
            warn!(
                "flow-collector stream_name is 'events' (legacy). Refusing to apply                  stream_max_bytes/max_age to the shared events bus. Migrate config to                  stream_name=flows (see docs/docs/netflow.md)."
            );
            let dup_window = ensure_legacy_events_subjects_only(&admin_js, &restore).await?;
            // Verify ownership then clear marker.
            self.pending_rehome.clear();
            clear_rehome_marker(&rehome_path);
            info!(
                "Connected to NATS at {} (legacy events stream, dup_window={:?})",
                self.config.nats_url, dup_window
            );
            return Ok((client, admin_js, publish_js, dup_window));
        }

        // Dedicated flows stream path
        {
            // Rehome flow subjects off events onto the dedicated stream.
            match rehome_subjects_from_events(
                &admin_js,
                &required_subjects,
                &self.config.stream_name,
                &rehome_path,
            )
            .await
            {
                Ok(subjects) => {
                    for subject in subjects {
                        if !self.pending_rehome.iter().any(|s| s == &subject) {
                            self.pending_rehome.push(subject);
                        }
                    }
                }
                Err(err) => {
                    warn!(
                        "Could not rehome flow subjects off shared events stream: {}",
                        err
                    );
                    return Err(err);
                }
            }

            let mut target_subjects = required_subjects.clone();
            for subject in &self.pending_rehome {
                if !target_subjects.iter().any(|s| s == subject) {
                    target_subjects.push(subject.clone());
                }
            }
            target_subjects = normalize_stream_subjects(target_subjects);

            // Union durable post-cutover ownership so runtime recovery after
            // stream delete still recreates extension subjects (e.g. ipfix).
            let ownership_path = ownership_state_path(&self.config);
            if let Some(inv) = load_ownership_inventory(&ownership_path)?
                && inv.stream == self.config.stream_name
            {
                for s in inv.subjects {
                    if !target_subjects.iter().any(|x| x == &s) {
                        target_subjects.push(s);
                    }
                }
                target_subjects = normalize_stream_subjects(target_subjects);
            }

            let dup_window = match ensure_flows_stream(
                &admin_js,
                &self.config.stream_name,
                &target_subjects,
                self.config.stream_max_bytes,
                desired_max_age,
                self.config.stream_replicas,
            )
            .await
            {
                Ok(window) => {
                    self.pending_rehome.clear();
                    clear_rehome_marker(&rehome_path);
                    write_ownership_inventory(
                        &ownership_path,
                        &OwnershipInventory {
                            stream: self.config.stream_name.clone(),
                            subjects: target_subjects.clone(),
                        },
                    )?;
                    window
                }
                Err(err) => {
                    if !self.pending_rehome.is_empty() {
                        match restore_subjects_to_events(&admin_js, &self.pending_rehome).await {
                            Ok(()) => {
                                self.pending_rehome.clear();
                                clear_rehome_marker(&rehome_path);
                            }
                            Err(restore_err) => {
                                error!(
                                    "Failed to restore rehomed subjects after target stream error                                      (marker retained at {}): {restore_err}",
                                    rehome_path.display()
                                );
                                return Err(
                                    err.context(format!("restore also failed: {restore_err}"))
                                );
                            }
                        }
                    }
                    return Err(err);
                }
            };

            info!(
                "Connected to NATS at {} and ensured stream '{}' exists (max_bytes={}, max_age={:?}, replicas={}, dup_window={:?})",
                self.config.nats_url,
                self.config.stream_name,
                self.config.stream_max_bytes,
                desired_max_age,
                self.config.stream_replicas,
                dup_window
            );

            Ok((client, admin_js, publish_js, dup_window))
        }
    }

    async fn connect_with_retry(
        &mut self,
    ) -> Result<(Client, jetstream::Context, jetstream::Context, Duration)> {
        let mut attempt: u32 = 0;
        let initial_backoff = Duration::from_millis(500);
        let max_backoff = Duration::from_secs(30);
        let mut backoff = min(initial_backoff, max_backoff);
        let max_attempts = 60;

        loop {
            attempt += 1;
            match self.connect_once().await {
                Ok(conn) => return Ok(conn),
                Err(err) => {
                    if attempt >= max_attempts {
                        error!(
                            "NATS connection attempt {} failed: {}. Giving up after {} attempts.",
                            attempt, err, max_attempts
                        );
                        return Err(err);
                    }

                    warn!(
                        "NATS connection attempt {} failed: {}. Retrying in {:?}...",
                        attempt, err, backoff
                    );
                    sleep(backoff).await;

                    let doubled = backoff.checked_mul(2).unwrap_or(max_backoff);
                    backoff = min(doubled, max_backoff);
                }
            }
        }
    }
}

/// Removes rehomeable flow subjects from `events` and returns the exact set
/// removed so the caller can union them into the target stream (including
/// extension subjects like `flows.raw.ipfix` not listed in this process config).
///
/// Writes a durable rehome marker **before** the events UPDATE so a crash between
/// detach and attach can recover the exact subject set on the next start.
async fn rehome_subjects_from_events(
    js: &jetstream::Context,
    required_subjects: &[String],
    target_stream: &str,
    rehome_path: &Path,
) -> Result<Vec<String>> {
    let mut events = match js.get_stream("events").await {
        Ok(stream) => stream,
        Err(err) if is_stream_not_found(&err) => return Ok(Vec::new()),
        Err(err) => {
            return Err(anyhow::anyhow!(
                "failed to INFO events stream during rehome: {err}"
            ));
        }
    };

    let info = events.info().await?;
    let mut updated = info.config.clone();
    let mut removed = Vec::new();
    updated.subjects.retain(|s| {
        if is_rehomeable_flow_subject(s, required_subjects) {
            removed.push(s.clone());
            false
        } else {
            true
        }
    });

    if removed.is_empty() {
        return Ok(removed);
    }

    // Persist complete unresolved set (existing marker ∪ removed) before detach.
    let mut subjects = removed.clone();
    if let Ok(Some(existing)) = load_rehome_marker(rehome_path) {
        for s in existing.subjects {
            if !subjects.iter().any(|x| x == &s) {
                subjects.push(s);
            }
        }
    }
    write_rehome_marker(
        rehome_path,
        &RehomeMarker {
            target_stream: target_stream.to_string(),
            subjects: subjects.clone(),
        },
    )?;
    // Return the full set so callers can union into pending_rehome.
    let removed = subjects;

    info!(
        "Removing {} flow subject(s) from shared events stream so dedicated stream can own them: {:?}",
        removed.len(),
        removed
    );
    js.update_stream(updated).await?;
    Ok(removed)
}

/// Legacy stream_name=events: merge required flow subjects only — never rewrite
/// shared retention/discard/storage that would evict logs/OTEL.
async fn ensure_legacy_events_subjects_only(
    js: &jetstream::Context,
    required_subjects: &[String],
) -> Result<Duration> {
    let mut events = match js.get_stream("events").await {
        Ok(stream) => stream,
        Err(err) if is_stream_not_found(&err) => {
            return Err(anyhow::anyhow!(
                "stream_name=events but events stream is missing; create it out-of-band or migrate to stream_name=flows"
            ));
        }
        Err(err) => {
            return Err(anyhow::anyhow!("failed to INFO events stream: {err}"));
        }
    };

    let info = events.info().await?;
    let existing_max_bytes = info.config.max_bytes;
    let existing_max_age = info.config.max_age;
    let mut updated = info.config.clone();
    let mut needs_update = false;
    for required in required_subjects {
        let covered = updated
            .subjects
            .iter()
            .any(|s| s == required || subject_covers(s, required));
        if !covered {
            updated.subjects.push(required.clone());
            needs_update = true;
        }
    }
    let normalized = normalize_stream_subjects(updated.subjects.clone());
    if normalized != updated.subjects {
        updated.subjects = normalized;
        needs_update = true;
    }
    // Do NOT raise events.duplicate_window: shared-stream ownership + server
    // jetstream.limits.duplicate_window (often 2m) make aggressive raises fail with 10052.
    // Retry age is derived from the verified INFO window after this merge.
    if needs_update {
        updated.max_bytes = existing_max_bytes;
        updated.max_age = existing_max_age;
        js.update_stream(updated).await?;
        info!("Merged flow subjects into legacy events stream without reshaping retention");
    }
    // Re-INFO for verified window (post-update config). Never invent a larger value.
    let mut events = js.get_stream("events").await?;
    let info = events.info().await?;
    // Legacy mode must not reshape shared retention, but no_ack=true makes every
    // publish wait for a timeout (no ACK). Fail closed with an actionable error.
    if info.config.no_ack {
        return Err(anyhow::anyhow!(
            "events stream has no_ack=true; flow-collector requires publish ACKs. \
             Fix the shared events stream (set no_ack=false) or migrate to stream_name=flows"
        ));
    }
    Ok(info.config.duplicate_window)
}

#[derive(Debug, Clone)]
struct PendingPublish {
    subject: String,
    payload: Vec<u8>,
    msg_id: String,
    /// UDP accept / first channel enqueue (never-attempted TTL basis).
    ingress_at: Instant,
    /// When send_publish first returned Ok (attempted on client channel).
    first_attempt_at: Option<Instant>,
}

impl PendingPublish {
    fn from_outbound((subject, payload, ingress_at): OutboundFlow) -> Self {
        Self {
            subject,
            payload,
            msg_id: next_msg_id(),
            ingress_at,
            first_attempt_at: None,
        }
    }

    #[cfg(test)]
    fn new(subject: String, payload: Vec<u8>) -> Self {
        Self::from_outbound((subject, payload, Instant::now()))
    }

    fn mark_attempted(mut self) -> Self {
        if self.first_attempt_at.is_none() {
            self.first_attempt_at = Some(Instant::now());
        }
        self
    }

    fn clear_attempt(mut self) -> Self {
        self.first_attempt_at = None;
        self
    }
}

/// Per-task publish outcome (joined after concurrent pass).
enum TaskOutcome {
    Done,
    Retry(PendingPublish),
    /// Ambiguous ACK — must force_reconnect before requeue.
    Ambiguous(PendingPublish),
    StreamMissing(PendingPublish),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PublishDisposition {
    Transient,
    /// Explicit JetStream Response::Err (not wrong-last) — not stored; retry.
    Negative,
    /// TimedOut/BrokenPipe — may still be buffered client-side.
    Ambiguous,
    Permanent,
    /// Stream gone — not stored; re-ensure rather than drop while Ready.
    StreamMissing,
}

fn classify_publish_error(kind: PublishErrorKind) -> PublishDisposition {
    match kind {
        PublishErrorKind::TimedOut | PublishErrorKind::BrokenPipe => {
            // May or may not have been stored; client buffer may still hold it.
            PublishDisposition::Ambiguous
        }
        PublishErrorKind::MaxAckPending => PublishDisposition::Transient,
        PublishErrorKind::StreamNotFound => PublishDisposition::StreamMissing,
        PublishErrorKind::MaxPayloadExceeded
        | PublishErrorKind::WrongLastMessageId
        | PublishErrorKind::WrongLastSequence => PublishDisposition::Permanent,
        // async-nats maps other JetStream Response::Err to Other — definitive
        // negative ACKs (insufficient resources, store failed, …).
        PublishErrorKind::Other => PublishDisposition::Negative,
    }
}

fn disposition_label(d: PublishDisposition) -> &'static str {
    match d {
        PublishDisposition::Transient => "transient",
        PublishDisposition::Negative => "negative",
        PublishDisposition::Ambiguous => "ambiguous",
        PublishDisposition::Permanent => "permanent",
        PublishDisposition::StreamMissing => "stream_missing",
    }
}

fn past_retry_horizon(item: &PendingPublish, max_attempt_age: Duration) -> bool {
    match item.first_attempt_at {
        Some(at) => {
            // Zero window ⇒ no server dedup ⇒ do not re-publish after attempt.
            if max_attempt_age.is_zero() {
                true
            } else {
                at.elapsed() > max_attempt_age
            }
        }
        None => item.ingress_at.elapsed() > Duration::from_secs(NEVER_ATTEMPTED_QUEUE_TTL_SECS),
    }
}

fn horizon_reason(item: &PendingPublish, max_attempt_age: Duration) -> String {
    match item.first_attempt_at {
        Some(at) => format!(
            "first_attempt_age {:?} > max_retry_age {:?}",
            at.elapsed(),
            max_attempt_age
        ),
        None => format!(
            "ingress_age {:?} > never_attempted_ttl {:?}",
            item.ingress_at.elapsed(),
            Duration::from_secs(NEVER_ATTEMPTED_QUEUE_TTL_SECS)
        ),
    }
}

fn expire_old_retries(retry_q: &mut VecDeque<PendingPublish>, max_attempt_age: Duration) {
    let before = retry_q.len();
    retry_q.retain(|item| {
        if past_retry_horizon(item, max_attempt_age) {
            error!(
                "Dropping publish retry for subject {} id={} ({})",
                item.subject,
                item.msg_id,
                horizon_reason(item, max_attempt_age)
            );
            false
        } else {
            true
        }
    });
    let dropped = before.saturating_sub(retry_q.len());
    if dropped > 0 {
        warn!("Expired {} publish retries past horizon", dropped);
    }
}

static MSG_ID_SEQ: AtomicU64 = AtomicU64::new(1);

fn next_msg_id() -> String {
    // Stable across retries for JetStream de-duplication (Nats-Msg-Id).
    // Instance prefix avoids collisions after process restart within duplicate_window.
    let seq = MSG_ID_SEQ.fetch_add(1, Ordering::Relaxed);
    let start = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    // seq is unique per process; start nanos prefixes a process generation.
    // Using only seq after first call is fine; include pid for multi-replica.
    format!("fc-{}-{}-{}", std::process::id(), start, seq)
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct RehomeMarker {
    target_stream: String,
    subjects: Vec<String>,
}

fn rehome_state_path(config: &Config) -> PathBuf {
    if let Some(path) = &config.rehome_state_path {
        return path.clone();
    }
    if let Ok(path) = std::env::var("FLOW_COLLECTOR_REHOME_STATE_PATH") {
        return PathBuf::from(path);
    }
    // Writable in Helm (PVC at /var/lib/serviceradar), Docker, and packages.
    // Never default to /tmp: containers use readOnlyRootFilesystem and /tmp is
    // not durable across pod replacement.
    PathBuf::from("/var/lib/serviceradar/flow-collector-rehome.json")
}

/// Durable post-cutover ownership inventory (survives marker clear + stream delete).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct OwnershipInventory {
    stream: String,
    subjects: Vec<String>,
}

fn ownership_state_path(config: &Config) -> PathBuf {
    if let Ok(path) = std::env::var("FLOW_COLLECTOR_OWNERSHIP_PATH") {
        return PathBuf::from(path);
    }
    // Sibling of rehome marker on the same data PVC.
    let rehome = rehome_state_path(config);
    if let Some(parent) = rehome.parent() {
        return parent.join("flow-collector-ownership.json");
    }
    PathBuf::from("/var/lib/serviceradar/flow-collector-ownership.json")
}

fn write_ownership_inventory(path: &Path, inv: &OwnershipInventory) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| {
            format!(
                "failed to create ownership inventory dir {}",
                parent.display()
            )
        })?;
    }
    let json = serde_json::to_vec_pretty(inv).context("failed to serialize ownership inventory")?;
    fs::write(path, json)
        .with_context(|| format!("failed to write ownership inventory {}", path.display()))?;
    info!(
        "Wrote ownership inventory for stream '{}' ({} subject(s)) to {}",
        inv.stream,
        inv.subjects.len(),
        path.display()
    );
    Ok(())
}

fn load_ownership_inventory(path: &Path) -> Result<Option<OwnershipInventory>> {
    if !path.exists() {
        return Ok(None);
    }
    let data = fs::read(path)
        .with_context(|| format!("failed to read ownership inventory {}", path.display()))?;
    let inv: OwnershipInventory = serde_json::from_slice(&data)
        .with_context(|| format!("failed to parse ownership inventory {}", path.display()))?;
    Ok(Some(inv))
}

fn ready_marker_path(config: &Config) -> PathBuf {
    // Explicit env wins so operators/probes share one override knob.
    if let Ok(path) = std::env::var("FLOW_COLLECTOR_READY_PATH") {
        return PathBuf::from(path);
    }
    if let Some(path) = &config.ready_state_path {
        return path.clone();
    }
    // Fixed default must match Helm readinessProbe path.
    PathBuf::from("/var/lib/serviceradar/flow-collector.ready")
}

/// Derive post-attempt retry horizon from a **verified** stream duplicate_window,
/// then apply an operational cap so large preserved windows cannot HOL-block
/// fresh traffic for hours. Never invent a larger value than INFO reported.
/// Zero window ⇒ no server-side dedup ⇒ no safe re-publish after first attempt.
fn max_retry_age_from_window(window: Duration) -> Duration {
    if window.is_zero() {
        return Duration::ZERO;
    }
    // Keep margin under the dedup window for concurrent pass latency.
    let margin = Duration::from_secs(15).min(window / 4);
    let derived = window.saturating_sub(margin);
    let under_window = if derived.is_zero() {
        window / 2
    } else {
        derived
    };
    let cap = Duration::from_secs(MAX_OPERATIONAL_RETRY_AGE_SECS);
    under_window.min(cap).min(window)
}

async fn wait_until_connected(client: &Client) {
    use async_nats::connection::State;
    if matches!(client.connection_state(), State::Connected) {
        return;
    }
    // Poll briefly; expire_old_retries still applies once Connected returns.
    for _ in 0..100 {
        if matches!(client.connection_state(), State::Connected) {
            return;
        }
        sleep(Duration::from_millis(100)).await;
    }
    warn!(
        "NATS still not Connected after wait (state={})",
        client.connection_state()
    );
}

fn clear_publisher_ready(config: &Config) -> Result<()> {
    let path = ready_marker_path(config);
    if path.exists() {
        fs::remove_file(&path).with_context(|| {
            format!(
                "failed to clear stale readiness marker {} (fail closed)",
                path.display()
            )
        })?;
    }
    Ok(())
}

fn mark_publisher_ready(config: &Config) -> Result<()> {
    let path = ready_marker_path(config);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create readiness marker dir {}", parent.display()))?;
    }
    fs::write(&path, b"ready\n").with_context(|| {
        format!(
            "failed to write readiness marker {} (fail closed)",
            path.display()
        )
    })?;
    info!("Publisher ready marker written to {}", path.display());
    Ok(())
}

fn load_rehome_marker(path: &Path) -> Result<Option<RehomeMarker>> {
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(path)
        .with_context(|| format!("read rehome marker {}", path.display()))?;
    let marker: RehomeMarker = serde_json::from_str(&raw)
        .with_context(|| format!("parse rehome marker {}", path.display()))?;
    Ok(Some(marker))
}

fn write_rehome_marker(path: &Path, marker: &RehomeMarker) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create rehome marker dir {}", parent.display()))?;
    }
    let raw = serde_json::to_string_pretty(marker)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, raw).with_context(|| format!("write rehome marker {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("persist rehome marker {}", path.display()))?;
    Ok(())
}

fn clear_rehome_marker(path: &Path) {
    if path.exists()
        && let Err(err) = fs::remove_file(path)
    {
        warn!("Failed to clear rehome marker {}: {}", path.display(), err);
    }
}

async fn restore_subjects_to_events(js: &jetstream::Context, subjects: &[String]) -> Result<()> {
    if subjects.is_empty() {
        return Ok(());
    }

    let mut events = match js.get_stream("events").await {
        Ok(stream) => stream,
        Err(err) if is_stream_not_found(&err) => {
            return Err(anyhow::anyhow!(
                "events stream missing while restoring rehomed subjects: {err}"
            ));
        }
        Err(err) => {
            return Err(anyhow::anyhow!(
                "failed to INFO events stream during restore: {err}"
            ));
        }
    };

    let info = events.info().await?;
    let mut updated = info.config.clone();
    let mut changed = false;
    for subject in subjects {
        let covered = updated
            .subjects
            .iter()
            .any(|s| s == subject || subject_covers(s, subject));
        if !covered {
            updated.subjects.push(subject.clone());
            changed = true;
        }
    }

    let normalized = normalize_stream_subjects(updated.subjects.clone());
    if normalized != updated.subjects {
        updated.subjects = normalized;
        changed = true;
    }

    if changed {
        // Verify every requested subject is covered after normalize.
        for required in subjects {
            if !updated
                .subjects
                .iter()
                .any(|s| s == required || subject_covers(s, required))
            {
                return Err(anyhow::anyhow!(
                    "events stream missing required subject '{required}' after restore normalize"
                ));
            }
        }
        warn!(
            "Restoring {} flow subject(s) onto events after target stream ensure failed (normalized={:?})",
            subjects.len(),
            updated.subjects
        );
        js.update_stream(updated).await?;
    }
    Ok(())
}

async fn ensure_flows_stream(
    js: &jetstream::Context,
    stream_name: &str,
    target_subjects: &[String],
    max_bytes: i64,
    max_age: Duration,
    replicas: usize,
) -> Result<Duration> {
    match js.get_stream(stream_name).await {
        Ok(mut existing_stream) => {
            let info = existing_stream.info().await?;
            let mut updated_config = info.config.clone();
            let mut needs_update = false;

            for required in target_subjects {
                let already_covered = updated_config
                    .subjects
                    .iter()
                    .any(|s| s == required || subject_covers(s, required));
                if !already_covered {
                    updated_config.subjects.push(required.clone());
                    needs_update = true;
                }
            }
            // Re-normalize after union in case wildcards + exacts both present.
            let normalized = normalize_stream_subjects(updated_config.subjects.clone());
            if normalized != updated_config.subjects {
                updated_config.subjects = normalized;
                needs_update = true;
            }

            if updated_config.num_replicas != replicas {
                updated_config.num_replicas = replicas;
                needs_update = true;
            }

            if updated_config.max_bytes != max_bytes {
                info!(
                    "Updating stream '{}' max_bytes from {} to {}",
                    stream_name, updated_config.max_bytes, max_bytes
                );
                updated_config.max_bytes = max_bytes;
                needs_update = true;
            }

            if updated_config.max_age != max_age {
                info!(
                    "Updating stream '{}' max_age from {:?} to {:?}",
                    stream_name, updated_config.max_age, max_age
                );
                updated_config.max_age = max_age;
                needs_update = true;
            }

            if updated_config.retention != RetentionPolicy::Limits {
                updated_config.retention = RetentionPolicy::Limits;
                needs_update = true;
            }
            if updated_config.discard != DiscardPolicy::Old {
                updated_config.discard = DiscardPolicy::Old;
                needs_update = true;
            }
            if updated_config.storage != StorageType::File {
                updated_config.storage = StorageType::File;
                needs_update = true;
            }

            // Publisher correctness requires publish ACKs. no_ack=true stores
            // messages but never ACKs, so every flow falls into the ambiguous path.
            if updated_config.no_ack {
                info!(
                    "Updating stream '{}' no_ack from true to false (publisher requires ACKs)",
                    stream_name
                );
                updated_config.no_ack = false;
                needs_update = true;
            }

            // Use the post-update max_age (may have just been changed above).
            let effective_max_age = updated_config.max_age;
            let desired_dup = clamp_duplicate_window(
                Duration::from_secs(PREFERRED_DUPLICATE_WINDOW_SECS),
                effective_max_age,
            );
            if updated_config.duplicate_window != desired_dup
                && (updated_config.duplicate_window < desired_dup
                    || updated_config.duplicate_window > effective_max_age
                        && !effective_max_age.is_zero())
            {
                info!(
                    "Updating stream '{}' duplicate_window from {:?} to {:?} (max_age={:?})",
                    stream_name, updated_config.duplicate_window, desired_dup, effective_max_age
                );
                updated_config.duplicate_window = desired_dup;
                needs_update = true;
            }

            if needs_update {
                // If server rejects duplicate_window (server limit), retry without raising it.
                if let Err(err) = js.update_stream(updated_config.clone()).await {
                    warn!(
                        "stream '{}' update failed ({err}); retrying without duplicate_window change",
                        stream_name
                    );
                    let mut fallback = updated_config.clone();
                    // Restore prior window from INFO we started with
                    fallback.duplicate_window = info.config.duplicate_window;
                    js.update_stream(fallback).await?;
                }
            }
            let mut verified = js.get_stream(stream_name).await?;
            let verified_info = verified.info().await?;
            for required in target_subjects {
                if !verified_info
                    .config
                    .subjects
                    .iter()
                    .any(|s| subject_covers(s, required) || s == required)
                {
                    return Err(anyhow::anyhow!(
                        "stream '{stream_name}' missing required subject '{required}' after update"
                    ));
                }
            }
            if verified_info.config.no_ack {
                return Err(anyhow::anyhow!(
                    "stream '{stream_name}' has no_ack=true after reconcile; publisher requires publish ACKs"
                ));
            }
            // Return verified INFO window only — never invent a larger fallback.
            Ok(verified_info.config.duplicate_window)
        }
        Err(err) if is_stream_not_found(&err) => {
            let stream_config = jetstream::stream::Config {
                name: stream_name.to_string(),
                subjects: target_subjects.to_vec(),
                storage: StorageType::File,
                retention: RetentionPolicy::Limits,
                discard: DiscardPolicy::Old,
                max_bytes,
                max_age,
                num_replicas: replicas,
                no_ack: false,
                // Preferred window (≤ max_age). Server jetstream.limits.duplicate_window
                // (often 2m) may reject larger values with 10052 — fall back below.
                duplicate_window: clamp_duplicate_window(
                    Duration::from_secs(PREFERRED_DUPLICATE_WINDOW_SECS),
                    max_age,
                ),
                ..Default::default()
            };
            // Prefer create_stream over get_or_create: get_or_create can return an
            // existing handle without applying our config when races occur.
            // If preferred window exceeds server limit, fall back to omit (server default).
            if let Err(err) = js.create_stream(stream_config.clone()).await {
                warn!(
                    "create stream '{}' with preferred duplicate_window failed ({err}); using server default",
                    stream_name
                );
                let mut fallback = stream_config;
                fallback.duplicate_window = Duration::ZERO; // server default
                js.create_stream(fallback).await?;
            }
            let mut verified = js.get_stream(stream_name).await?;
            let verified_info = verified.info().await?;
            for required in target_subjects {
                if !verified_info
                    .config
                    .subjects
                    .iter()
                    .any(|s| subject_covers(s, required) || s == required)
                {
                    return Err(anyhow::anyhow!(
                        "stream '{stream_name}' missing required subject '{required}' after create"
                    ));
                }
            }
            if verified_info.config.no_ack {
                return Err(anyhow::anyhow!(
                    "stream '{stream_name}' has no_ack=true after create; publisher requires publish ACKs"
                ));
            }
            // Verified INFO only — retry horizon must not exceed actual window.
            Ok(verified_info.config.duplicate_window)
        }
        Err(err) => Err(anyhow::anyhow!(
            "failed to INFO stream '{stream_name}': {err}"
        )),
    }
}

fn is_stream_not_found(err: &async_nats::jetstream::context::GetStreamError) -> bool {
    use async_nats::jetstream::context::GetStreamErrorKind;
    match err.kind() {
        GetStreamErrorKind::JetStream(js_err) => js_err.code() == 404,
        _ => {
            let msg = err.to_string().to_ascii_lowercase();
            msg.contains("not found") || msg.contains("no stream")
        }
    }
}

/// Drop subjects covered by a broader pattern so NATS does not reject
/// self-overlapping stream subject lists (e.g. `flows.raw.>` + `flows.raw.netflow`).
pub(crate) fn normalize_stream_subjects(subjects: Vec<String>) -> Vec<String> {
    let mut subjects = subjects;
    subjects.sort();
    subjects.dedup();
    let copy = subjects.clone();
    subjects
        .into_iter()
        .filter(|subject| {
            !copy
                .iter()
                .any(|other| other != subject && subject_covers(other, subject))
        })
        .collect()
}

/// Returns true when every subject matched by `narrower` is also matched by `broader`
/// under NATS subject filter language (`*` = one token, `>` = one or more tokens at end).
pub(crate) fn subject_covers(broader: &str, narrower: &str) -> bool {
    if broader == narrower {
        return true;
    }
    let broader_tokens: Vec<&str> = broader.split('.').collect();
    let narrower_tokens: Vec<&str> = narrower.split('.').collect();
    pattern_covers_pattern(&broader_tokens, &narrower_tokens)
}

fn pattern_covers_pattern(broader: &[&str], narrower: &[&str]) -> bool {
    let mut bi = 0;
    let mut ni = 0;

    while bi < broader.len() {
        match broader[bi] {
            ">" => {
                // `>` must be the final token and covers one or more remaining tokens.
                return bi == broader.len() - 1 && ni < narrower.len();
            }
            "*" => {
                // `*` covers exactly one token. It does not cover `>` (multi-token).
                if ni >= narrower.len() {
                    return false;
                }
                if narrower[ni] == ">" {
                    return false;
                }
                bi += 1;
                ni += 1;
            }
            lit => {
                if ni >= narrower.len() {
                    return false;
                }
                match narrower[ni] {
                    ">" | "*" => return false,
                    nlit if nlit == lit => {
                        bi += 1;
                        ni += 1;
                    }
                    _ => return false,
                }
            }
        }
    }

    ni == narrower.len()
}

pub(crate) fn is_rehomeable_flow_subject(subject: &str, required_subjects: &[String]) -> bool {
    if subject.starts_with("flows.raw.") {
        return true;
    }
    subject.starts_with("flow.host-slice.") && required_subjects.iter().any(|req| req == subject)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn rehome_marker_round_trip() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("rehome-marker-test-{nanos}.json"));
        let marker = RehomeMarker {
            target_stream: "flows".to_string(),
            subjects: vec![
                "flows.raw.ipfix".to_string(),
                "flows.raw.netflow".to_string(),
            ],
        };
        write_rehome_marker(&path, &marker).unwrap();
        let loaded = load_rehome_marker(&path).unwrap().expect("marker present");
        assert_eq!(loaded.target_stream, "flows");
        assert_eq!(loaded.subjects, marker.subjects);
        clear_rehome_marker(&path);
        assert!(load_rehome_marker(&path).unwrap().is_none());
    }

    #[test]
    fn clamp_duplicate_window_respects_max_age() {
        assert_eq!(
            clamp_duplicate_window(Duration::from_secs(120), Duration::from_secs(60)),
            Duration::from_secs(60)
        );
        assert_eq!(
            clamp_duplicate_window(Duration::from_secs(120), Duration::ZERO),
            Duration::from_secs(120)
        );
        assert_eq!(
            clamp_duplicate_window(Duration::from_secs(60), Duration::from_secs(120)),
            Duration::from_secs(60)
        );
    }

    #[test]
    fn max_retry_age_never_exceeds_verified_window_or_operational_cap() {
        assert_eq!(max_retry_age_from_window(Duration::ZERO), Duration::ZERO);
        let age_60 = max_retry_age_from_window(Duration::from_secs(60));
        assert!(age_60 < Duration::from_secs(60));
        assert!(age_60 > Duration::ZERO);
        let age_120 = max_retry_age_from_window(Duration::from_secs(120));
        assert!(age_120 <= Duration::from_secs(MAX_OPERATIONAL_RETRY_AGE_SECS));
        assert!(age_120 <= Duration::from_secs(105));
        // Multi-hour preserved windows must not become multi-hour HOL blocks.
        let age_day = max_retry_age_from_window(Duration::from_secs(86_400));
        assert_eq!(age_day, Duration::from_secs(MAX_OPERATIONAL_RETRY_AGE_SECS));
    }

    #[test]
    fn classify_publish_error_kinds() {
        assert_eq!(
            classify_publish_error(PublishErrorKind::TimedOut),
            PublishDisposition::Ambiguous
        );
        assert_eq!(
            classify_publish_error(PublishErrorKind::BrokenPipe),
            PublishDisposition::Ambiguous
        );
        assert_eq!(
            classify_publish_error(PublishErrorKind::StreamNotFound),
            PublishDisposition::StreamMissing
        );
        assert_eq!(
            classify_publish_error(PublishErrorKind::MaxPayloadExceeded),
            PublishDisposition::Permanent
        );
        assert_eq!(
            classify_publish_error(PublishErrorKind::MaxAckPending),
            PublishDisposition::Transient
        );
        assert_eq!(
            classify_publish_error(PublishErrorKind::Other),
            PublishDisposition::Negative
        );
    }

    #[test]
    fn ownership_inventory_round_trip() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("ownership-inv-{nanos}.json"));
        let inv = OwnershipInventory {
            stream: "flows".to_string(),
            subjects: vec![
                "flows.raw.netflow".to_string(),
                "flows.raw.ipfix".to_string(),
            ],
        };
        write_ownership_inventory(&path, &inv).unwrap();
        let loaded = load_ownership_inventory(&path).unwrap().expect("present");
        assert_eq!(loaded.stream, "flows");
        assert!(loaded.subjects.iter().any(|s| s == "flows.raw.ipfix"));
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn never_attempted_not_expired_by_short_attempt_horizon() {
        let item = PendingPublish::new("flows.raw.netflow".into(), vec![1, 2, 3]);
        // 90s attempt horizon must not drop a never-attempted message immediately.
        assert!(!past_retry_horizon(&item, Duration::from_secs(90)));
        let attempted = item.mark_attempted();
        assert!(!past_retry_horizon(&attempted, Duration::from_secs(90)));
        // Zero window: after attempt, immediately past horizon.
        assert!(past_retry_horizon(&attempted, Duration::ZERO));
    }

    #[test]
    fn restore_normalize_drops_exacts_under_wildcard() {
        let normalized = normalize_stream_subjects(vec![
            "flows.raw.>".to_string(),
            "flows.raw.netflow".to_string(),
            "flows.raw.sflow".to_string(),
        ]);
        assert_eq!(normalized, vec!["flows.raw.>".to_string()]);
    }

    #[test]
    fn wildcard_star_does_not_cover_gt() {
        assert!(!subject_covers("flows.raw.*", "flows.raw.>"));
        assert!(subject_covers("flows.raw.>", "flows.raw.*"));
        let normalized =
            normalize_stream_subjects(vec!["flows.raw.*".to_string(), "flows.raw.>".to_string()]);
        assert_eq!(normalized, vec!["flows.raw.>".to_string()]);
    }
}
