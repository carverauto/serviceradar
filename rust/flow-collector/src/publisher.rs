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
/// Subject retained on a detached stream when NATS refuses an empty subject list.
/// This is stream plumbing, never durable flow ownership.
const DETACHED_SENTINEL_SUBJECT: &str = "_empty.detached";

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
#[derive(Debug)]
enum PublishPassResult {
    /// Finished a chunk. `succeeded` = ACKed; `retryable` = requeued failures.
    Completed { succeeded: usize, retryable: usize },
    /// A forced reconnect completed. The caller must re-verify stream ownership
    /// before reasserting readiness or retrying on the new generation.
    Reconnected { succeeded: usize, retryable: usize },
    /// Ambiguous publishes whose connection-generation barrier did not complete.
    /// These items must never enter the ordinary retry queue until the generation changes.
    Quarantined(PublishQuarantine),
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
        let mut quarantine: Option<PublishQuarantine> = None;
        let mut input_closed = false;
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
            if let Some(held) = quarantine.as_mut() {
                expire_old_retries(&mut held.items, max_retry_age);
            }

            if let Some(held) = quarantine.as_mut() {
                if held.observes_new_generation(&client) {
                    self.recover_owned_stream(
                        &client,
                        &admin_js,
                        &mut max_retry_age,
                        "ambiguous publish generation changed",
                    )
                    .await?;
                    publisher_ready = true;
                    let released = quarantine.take().expect("quarantine present");
                    append_retry_bounded(&mut retry_q, released.items, max_retry_queue);
                    next_retry_at = Instant::now();
                    retry_backoff = Duration::from_millis(100);
                    continue;
                }

                if publisher_ready {
                    clear_publisher_ready(&self.config)?;
                    publisher_ready = false;
                }
                expire_old_retries(&mut retry_q, max_retry_age);

                // Continue accepting already-arrived channel work, but do not publish
                // anything until the quarantined generation changes. On shutdown,
                // keep waiting safely; main's absolute drain deadline bounds this loop.
                if input_closed {
                    sleep(Duration::from_millis(100)).await;
                } else {
                    tokio::select! {
                        msg = self.rx.recv() => {
                            match msg {
                                Some(m) => {
                                    let mut fresh = VecDeque::from([
                                        PendingPublish::from_outbound(m),
                                    ]);
                                    let (more, closed) = self.drain_fresh_batch();
                                    fresh.extend(more);
                                    input_closed |= closed;
                                    append_retry_bounded(
                                        &mut retry_q,
                                        fresh,
                                        max_retry_queue,
                                    );
                                }
                                None => input_closed = true,
                            }
                        }
                        _ = sleep(Duration::from_millis(100)) => {}
                    }
                }
                continue;
            }

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
                // Cap wait so idle disconnect still clears readiness promptly.
                let readiness_wake = Duration::from_secs(1);
                let wait = if wait_retry {
                    retry_wait.min(readiness_wake)
                } else {
                    readiness_wake
                };
                tokio::select! {
                    msg = self.rx.recv() => {
                        match msg {
                            Some(m) => {
                                batch.push(PendingPublish::from_outbound(m));
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
                                        &mut quarantine,
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
                                            &mut quarantine,
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
                                        &mut quarantine,
                                    )
                                    .await;
                            }
                        }
                    }
                    _ = sleep(wait) => {
                        // Periodic wake: recheck connection state / retry schedule.
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
                    &mut quarantine,
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
                    &mut quarantine,
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
                        &mut quarantine,
                    )
                    .await;
            }
        }
    }

    /// Connect, ensure the owned stream (including any pending cutover), then
    /// return. Used by the Helm bootstrap Job so collector pods never have to
    /// own the durable cutover markers.
    ///
    /// This deliberately reuses `connect_with_retry`, which performs the same
    /// rehome/ownership recovery `run()` does. A second implementation of that
    /// state machine would have to be kept in behavioural parity by hand.
    pub async fn bootstrap_stream(config: Arc<Config>) -> Result<()> {
        // The Job has no listeners, so nothing will ever send on this channel.
        let (_tx, rx) = mpsc::channel(1);
        let mut publisher =
            Publisher::new(config, rx, Arc::new(HostSliceMetricsRegistry::new(vec![])));
        let (_client, _admin_js, _publish_js, window) = publisher.connect_with_retry().await?;
        info!(
            "Bootstrap complete: stream '{}' ensured (dup_window={:?})",
            publisher.config.stream_name, window
        );
        Ok(())
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
        quarantine: &mut Option<PublishQuarantine>,
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
            .await?
        } else {
            wait_until_connected(client).await;
            self.publish_pending(client, publish_js, retry_q, *max_retry_age)
                .await?
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
            PublishPassResult::Quarantined(held) => {
                if *publisher_ready {
                    // publish_pending cleared the marker before forcing reconnect;
                    // keep the in-memory readiness state consistent.
                    *publisher_ready = false;
                }
                *quarantine = Some(held);
                if drive_retry_schedule {
                    *retry_backoff = min(retry_backoff.saturating_mul(2), max_backoff);
                    *next_retry_at = Instant::now() + *retry_backoff;
                }
            }
            PublishPassResult::Reconnected {
                succeeded,
                retryable,
            } => {
                self.recover_owned_stream(
                    client,
                    admin_js,
                    max_retry_age,
                    "forced reconnect after ambiguous publish",
                )
                .await?;
                *publisher_ready = true;
                if drive_retry_schedule {
                    update_retry_schedule(
                        retry_q,
                        succeeded,
                        retryable,
                        next_retry_at,
                        retry_backoff,
                        max_backoff,
                    );
                }
            }
            PublishPassResult::Completed {
                succeeded,
                retryable,
            } => {
                if !drive_retry_schedule {
                    return Ok(());
                }
                update_retry_schedule(
                    retry_q,
                    succeeded,
                    retryable,
                    next_retry_at,
                    retry_backoff,
                    max_backoff,
                );
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
    ) -> Result<PublishPassResult> {
        if batch.is_empty() {
            return Ok(PublishPassResult::Completed {
                succeeded: 0,
                retryable: 0,
            });
        }
        let mut pending: VecDeque<PendingPublish> = std::mem::take(batch).into();
        wait_until_connected(client).await;
        let result = self
            .publish_pending(client, publish_js, &mut pending, max_retry_age)
            .await?;
        append_retry_bounded(retry_q, pending, max_retry_queue);
        Ok(result)
    }

    #[allow(clippy::too_many_arguments)]
    async fn drain_retries_until_empty(
        &self,
        client: &Client,
        admin_js: &jetstream::Context,
        publish_js: &jetstream::Context,
        retry_q: &mut VecDeque<PendingPublish>,
        max_retry_age: &mut Duration,
        publisher_ready: &mut bool,
        quarantine: &mut Option<PublishQuarantine>,
    ) -> Result<()> {
        let mut backoff = Duration::from_millis(100);
        let max_backoff = Duration::from_secs(5);
        let mut attempts = 0u32;
        while !retry_q.is_empty() || quarantine.is_some() {
            if let Some(held) = quarantine.as_mut() {
                expire_old_retries(&mut held.items, *max_retry_age);
                if held.items.is_empty() {
                    *quarantine = None;
                    continue;
                }
                if held.observes_new_generation(client) {
                    self.recover_owned_stream(
                        client,
                        admin_js,
                        max_retry_age,
                        "shutdown quarantine generation changed",
                    )
                    .await?;
                    *publisher_ready = true;
                    let released = quarantine.take().expect("quarantine present");
                    retry_q.extend(released.items);
                    backoff = Duration::from_millis(100);
                    continue;
                }
                if *publisher_ready {
                    clear_publisher_ready(&self.config)?;
                    *publisher_ready = false;
                }
                attempts += 1;
                if attempts >= 500 {
                    return Err(anyhow::anyhow!(
                        "publisher shutting down with {} quarantined flow message(s) awaiting a new NATS generation",
                        held.items.len()
                    ));
                }
                sleep(backoff).await;
                backoff = min(backoff.saturating_mul(2), max_backoff);
                continue;
            }

            expire_old_retries(retry_q, *max_retry_age);
            if retry_q.is_empty() {
                break;
            }
            attempts += 1;
            wait_until_connected(client).await;
            match self
                .publish_pending(client, publish_js, retry_q, *max_retry_age)
                .await?
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
                PublishPassResult::Quarantined(held) => {
                    *publisher_ready = false;
                    *quarantine = Some(held);
                }
                PublishPassResult::Reconnected {
                    succeeded,
                    retryable,
                } => {
                    self.recover_owned_stream(
                        client,
                        admin_js,
                        max_retry_age,
                        "shutdown forced reconnect",
                    )
                    .await?;
                    *publisher_ready = true;
                    if retry_q.is_empty() {
                        break;
                    }
                    if succeeded > 0 {
                        backoff = Duration::from_millis(100);
                        continue;
                    }
                    if retryable > 0 {
                        sleep(backoff).await;
                        backoff = min(backoff.saturating_mul(2), max_backoff);
                    }
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
        let (window, verified_subjects) = ensure_flows_stream(
            admin_js,
            &self.config.stream_name,
            &subjects,
            self.config.stream_max_bytes,
            desired_max_age,
            self.config.stream_replicas,
        )
        .await?;
        // Persist verified INFO subjects before any readiness reassert.
        write_ownership_inventory(
            &ownership_path,
            &OwnershipInventory {
                stream: self.config.stream_name.clone(),
                subjects: verified_subjects,
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
    ) -> Result<PublishPassResult> {
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
            return Ok(PublishPassResult::Disconnected);
        }
        let limit = pending.len().min(self.config.batch_size.max(1));
        if limit == 0 {
            return Ok(PublishPassResult::Completed {
                succeeded: 0,
                retryable: 0,
            });
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
                                let disposition = classify_publish_error(&e);
                                match disposition {
                                    PublishDisposition::StreamMissing => {
                                        error!(
                                            "NATS stream missing for subject {} id={}: {} — preserving and re-ensuring",
                                            item.subject, item.msg_id, e
                                        );
                                        // Preserve first_attempt if prior uncertainty.
                                        TaskOutcome::StreamMissing(item.clear_attempt_if_certain())
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
                                        // this reply was not a store. If a prior
                                        // attempt was ambiguous, keep that horizon.
                                        warn!(
                                            "NATS publish {} for subject {} id={}: {} — will retry",
                                            disposition_label(disposition),
                                            item.subject,
                                            item.msg_id,
                                            e
                                        );
                                        TaskOutcome::Retry(item.clear_attempt_if_certain())
                                    }
                                    PublishDisposition::Ambiguous => {
                                        // TimedOut/BrokenPipe or malformed ACK after
                                        // possible store. Requeue only after observed
                                        // connection-generation change.
                                        warn!(
                                            "NATS publish ACK ambiguous for subject {} id={}: {} — will force-reconnect then retry",
                                            item.subject, item.msg_id, e
                                        );
                                        TaskOutcome::Ambiguous(item.mark_ambiguous())
                                    }
                                }
                            }
                        }
                    }
                    Err(e) => {
                        // send_publish failed before/without a durable enqueue —
                        // safe to requeue when not permanent.
                        match classify_publish_error(&e) {
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

        // Wait for a new connection generation before requeueing ambiguous
        // items. force_reconnect alone is not a cancellation barrier — the
        // old connection may still flush queued commands first.
        let mut reconnected = false;
        if !ambiguous.is_empty() {
            warn!(
                "Force-reconnecting NATS after {} ambiguous in-flight publish(es); waiting for generation change",
                ambiguous.len()
            );
            // Fail readiness closed before requesting a reconnect. It may remain
            // on the old socket for a while, so never reassert until a distinct
            // generation is observed and stream ownership is re-verified.
            clear_publisher_ready(&self.config)?;
            match force_reconnect_and_await_generation(client).await {
                Ok(()) => {
                    reconnected = true;
                    while let Some(item) = ambiguous.pop_front() {
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
                Err(e) => {
                    if !e.can_quarantine() {
                        return Err(anyhow::anyhow!(
                            "cannot establish an ambiguous-publish reconnect barrier: {e}"
                        ));
                    }
                    // Do not enqueue a second attempt on the same connection
                    // generation. Ordinary negative/pre-send failures remain in
                    // `pending`; only ambiguous items enter the generation-keyed
                    // quarantine.
                    error!(
                        "Ambiguous publish generation barrier failed ({e}); quarantining {} item(s)",
                        ambiguous.len()
                    );
                    let held = PublishQuarantine {
                        generation: e.before,
                        saw_not_connected: e.saw_not_connected,
                        items: ambiguous,
                    };
                    failed.append(pending);
                    *pending = failed;
                    return Ok(PublishPassResult::Quarantined(held));
                }
            }
        }

        let retryable = failed.len();
        // Preserve remaining unattempted (if any) then failures.
        failed.append(pending);
        *pending = failed;
        if stream_missing {
            Ok(PublishPassResult::StreamMissing)
        } else if reconnected {
            Ok(PublishPassResult::Reconnected {
                succeeded,
                retryable,
            })
        } else {
            Ok(PublishPassResult::Completed {
                succeeded,
                retryable,
            })
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
        // Retain the target: on rollback it may be the only durable evidence of
        // which newly-created stream must be detached after a late forward crash.
        let rehome_marker = load_rehome_marker(&rehome_path)?;
        if let Some(marker) = rehome_marker.as_ref() {
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
            // Legacy / rollback: after a completed cutover the rehome marker is
            // gone but ownership inventory still records subjects on `flows`.
            // Reverse-transfer those filters before attaching to events or
            // JetStream returns cross-stream subject-overlap (10065).
            warn!(
                "flow-collector stream_name is 'events' (legacy). Refusing to apply \
                 stream_max_bytes/max_age to the shared events bus. Migrate config to \
                 stream_name=flows (see docs/docs/netflow.md)."
            );
            let ownership_path = ownership_state_path(&self.config);
            let ownership = load_ownership_inventory(&ownership_path)?;
            let restore = rollback_restore_subjects(
                &required_subjects,
                &self.pending_rehome,
                ownership.as_ref(),
            );
            let detach_sources =
                rollback_detach_sources(rehome_marker.as_ref(), ownership.as_ref());
            if !detach_sources.is_empty() {
                // Preserve a source target until every remote detach completes.
                // If the process crashes mid-detach, the next rollback can still
                // identify at least the marker-named source; ownership inventory
                // retains any additional source.
                let source_target = rehome_marker
                    .as_ref()
                    .filter(|marker| marker.target_stream != "events")
                    .map(|marker| marker.target_stream.clone())
                    .unwrap_or_else(|| detach_sources[0].0.clone());
                write_rehome_marker(
                    &rehome_path,
                    &RehomeMarker {
                        target_stream: source_target,
                        subjects: restore.clone(),
                    },
                )?;

                for (stream, subjects) in &detach_sources {
                    info!(
                        "Rollback: detaching {} subject(s) from '{}' before attaching to events",
                        subjects.len(),
                        stream
                    );
                    detach_subjects_from_stream(&admin_js, stream, subjects).await?;
                }

                // Detaches are complete. Flip the durable target before attaching
                // to events so a crash during the final ensure restores there.
                write_rehome_marker(
                    &rehome_path,
                    &RehomeMarker {
                        target_stream: "events".to_string(),
                        subjects: restore.clone(),
                    },
                )?;
            }
            let dup_window = ensure_legacy_events_subjects_only(&admin_js, &restore).await?;
            // Inventory now reflects events ownership (or clear if empty).
            write_ownership_inventory(
                &ownership_path,
                &OwnershipInventory {
                    stream: "events".to_string(),
                    subjects: restore.clone(),
                },
            )?;
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
                Ok((window, verified_subjects)) => {
                    // Persist verified post-ensure ownership BEFORE clearing the
                    // rehome marker so a crash cannot leave neither durable.
                    write_ownership_inventory(
                        &ownership_path,
                        &OwnershipInventory {
                            stream: self.config.stream_name.clone(),
                            subjects: verified_subjects,
                        },
                    )?;
                    self.pending_rehome.clear();
                    clear_rehome_marker(&rehome_path);
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
    /// Sticky: once an ACK was ambiguous, never switch to never-attempted TTL
    /// (a later definitive negative must not clear the uncertainty horizon).
    ever_ambiguous: bool,
}

impl PendingPublish {
    fn from_outbound((subject, payload, ingress_at): OutboundFlow) -> Self {
        Self {
            subject,
            payload,
            msg_id: next_msg_id(),
            ingress_at,
            first_attempt_at: None,
            ever_ambiguous: false,
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

    fn mark_ambiguous(mut self) -> Self {
        self.ever_ambiguous = true;
        if self.first_attempt_at.is_none() {
            self.first_attempt_at = Some(Instant::now());
        }
        self
    }

    /// Clear attempt only when never ambiguous — after uncertain enqueues we
    /// must keep the duplicate-window horizon for the rest of the item's life.
    fn clear_attempt_if_certain(mut self) -> Self {
        if !self.ever_ambiguous {
            self.first_attempt_at = None;
        }
        self
    }
}

/// Ambiguous requests held away from the ordinary retry queue until the
/// async-nats client has demonstrably moved off the connection that accepted
/// the original command. This prevents a failed reconnect barrier from
/// immediately sending a duplicate on the same generation.
#[derive(Debug)]
struct PublishQuarantine {
    generation: Option<ConnGeneration>,
    saw_not_connected: bool,
    items: VecDeque<PendingPublish>,
}

impl PublishQuarantine {
    fn observes_new_generation(&mut self, client: &Client) -> bool {
        let connected = matches!(
            client.connection_state(),
            async_nats::connection::State::Connected
        );
        let now = if connected {
            conn_generation(client)
        } else {
            None
        };
        observes_generation_change(
            &self.generation,
            &mut self.saw_not_connected,
            connected,
            now.as_ref(),
        )
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

fn classify_publish_error(
    err: &async_nats::jetstream::context::PublishError,
) -> PublishDisposition {
    use std::error::Error as StdError;
    match err.kind() {
        PublishErrorKind::TimedOut | PublishErrorKind::BrokenPipe => {
            // May or may not have been stored; client buffer may still hold it.
            PublishDisposition::Ambiguous
        }
        PublishErrorKind::MaxAckPending => PublishDisposition::Transient,
        PublishErrorKind::StreamNotFound => PublishDisposition::StreamMissing,
        PublishErrorKind::MaxPayloadExceeded
        | PublishErrorKind::WrongLastMessageId
        | PublishErrorKind::WrongLastSequence => PublishDisposition::Permanent,
        // Other is used for both explicit JetStream Response::Err (negative,
        // not stored) and ACK payload deserialization failures (may follow a
        // successful store). Inspect the source chain.
        PublishErrorKind::Other => {
            let mut src = err.source();
            while let Some(s) = src {
                if s.downcast_ref::<async_nats::jetstream::Error>().is_some() {
                    return PublishDisposition::Negative;
                }
                // Display fallback for wrapped JetStream API errors.
                let msg = s.to_string();
                if msg.contains("err_code")
                    || msg.contains("insufficient resources")
                    || msg.contains("stream store")
                {
                    return PublishDisposition::Negative;
                }
                src = s.source();
            }
            // Serde/malformed payload after a possible successful store.
            PublishDisposition::Ambiguous
        }
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

fn append_retry_bounded(
    retry_q: &mut VecDeque<PendingPublish>,
    incoming: impl IntoIterator<Item = PendingPublish>,
    max_retry_queue: usize,
) {
    for item in incoming {
        if max_retry_queue == 0 {
            warn!("Publish retry queue disabled; dropping failed publish");
            continue;
        }
        if retry_q.len() >= max_retry_queue {
            warn!(
                "Publish retry queue full ({}); dropping oldest failed publish",
                max_retry_queue
            );
            retry_q.pop_front();
        }
        retry_q.push_back(item);
    }
}

fn update_retry_schedule(
    retry_q: &VecDeque<PendingPublish>,
    succeeded: usize,
    retryable: usize,
    next_retry_at: &mut Instant,
    retry_backoff: &mut Duration,
    max_backoff: Duration,
) {
    // Progress: at least one ACK -> process next chunk immediately. No progress
    // with retryable failures -> exponential backoff.
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

fn durable_owned_subjects(subjects: Vec<String>) -> Vec<String> {
    normalize_stream_subjects(
        subjects
            .into_iter()
            .filter(|subject| subject != DETACHED_SENTINEL_SUBJECT)
            .collect(),
    )
}

fn rollback_restore_subjects(
    required: &[String],
    pending_rehome: &[String],
    ownership: Option<&OwnershipInventory>,
) -> Vec<String> {
    let mut restore = required.to_vec();
    restore.extend(pending_rehome.iter().cloned());
    if let Some(inv) = ownership {
        restore.extend(inv.subjects.iter().cloned());
    }
    durable_owned_subjects(restore)
}

fn add_rollback_detach_source(
    sources: &mut Vec<(String, Vec<String>)>,
    stream: &str,
    subjects: &[String],
) {
    if stream.is_empty() || stream == "events" {
        return;
    }
    let subjects = durable_owned_subjects(subjects.to_vec());
    if subjects.is_empty() {
        return;
    }
    if let Some((_, existing)) = sources.iter_mut().find(|(name, _)| name == stream) {
        existing.extend(subjects);
        *existing = durable_owned_subjects(std::mem::take(existing));
    } else {
        sources.push((stream.to_string(), subjects));
    }
}

fn rollback_detach_sources(
    marker: Option<&RehomeMarker>,
    ownership: Option<&OwnershipInventory>,
) -> Vec<(String, Vec<String>)> {
    let mut sources = Vec::new();
    if let Some(marker) = marker {
        add_rollback_detach_source(&mut sources, &marker.target_stream, &marker.subjects);
    }
    if let Some(inv) = ownership {
        add_rollback_detach_source(&mut sources, &inv.stream, &inv.subjects);
    }
    sources
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
    let persisted = OwnershipInventory {
        stream: inv.stream.clone(),
        subjects: durable_owned_subjects(inv.subjects.clone()),
    };
    let json =
        serde_json::to_vec_pretty(&persisted).context("failed to serialize ownership inventory")?;
    // Atomic replace: write temp + fsync + rename so a crash cannot leave a
    // truncated inventory after the rehome marker was cleared.
    let tmp = path.with_extension("json.tmp");
    {
        use std::io::Write;
        let mut f = fs::File::create(&tmp)
            .with_context(|| format!("failed to create ownership temp {}", tmp.display()))?;
        f.write_all(&json)
            .with_context(|| format!("failed to write ownership temp {}", tmp.display()))?;
        f.sync_all()
            .with_context(|| format!("failed to fsync ownership temp {}", tmp.display()))?;
    }
    fs::rename(&tmp, path).with_context(|| {
        format!(
            "failed to rename ownership inventory {} -> {}",
            tmp.display(),
            path.display()
        )
    })?;
    // Directory entry durability before any subsequent marker clear / NATS mutation.
    if let Some(parent) = path.parent() {
        fsync_dir(parent)?;
    }
    info!(
        "Wrote ownership inventory for stream '{}' ({} subject(s)) to {}",
        persisted.stream,
        persisted.subjects.len(),
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
    let mut inv: OwnershipInventory = serde_json::from_slice(&data)
        .with_context(|| format!("failed to parse ownership inventory {}", path.display()))?;
    inv.subjects = durable_owned_subjects(inv.subjects);
    Ok(Some(inv))
}

/// `pub(crate)`: also read by `main.rs` to hand the same path to
/// `run_prometheus_server`'s `/readyz` handler, so the HTTP readiness probe
/// checks exactly the file `mark_publisher_ready`/`clear_publisher_ready`
/// write below -- one source of truth for "where is the ready marker".
pub(crate) fn ready_marker_path(config: &Config) -> PathBuf {
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

/// Connection generation: client_id is server-local, so pair with server_id.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ConnGeneration {
    server_id: String,
    client_id: u64,
}

#[derive(Debug)]
struct GenerationBarrierFailure {
    before: Option<ConnGeneration>,
    saw_not_connected: bool,
    /// False only when async-nats rejected the Reconnect command because its
    /// internal command receiver is already closed. That client can never
    /// produce a new generation, so waiting in quarantine would wedge forever.
    reconnect_enqueued: bool,
    reason: String,
}

impl std::fmt::Display for GenerationBarrierFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} (before={:?}, saw_not_connected={}, reconnect_enqueued={})",
            self.reason, self.before, self.saw_not_connected, self.reconnect_enqueued
        )
    }
}

impl GenerationBarrierFailure {
    fn can_quarantine(&self) -> bool {
        self.reconnect_enqueued
    }
}

fn conn_generation(client: &Client) -> Option<ConnGeneration> {
    client.try_server_info().map(|i| ConnGeneration {
        server_id: i.server_id.clone(),
        client_id: i.client_id,
    })
}

fn observes_generation_change(
    before: &Option<ConnGeneration>,
    saw_not_connected: &mut bool,
    connected: bool,
    now: Option<&ConnGeneration>,
) -> bool {
    if !connected {
        *saw_not_connected = true;
        return false;
    }

    match (before.as_ref(), now) {
        (Some(old), Some(current)) => current != old,
        // Without a baseline, only a complete non-Connected -> Connected
        // transition proves that this is not the generation that accepted the
        // ambiguous command.
        (None, Some(_)) => *saw_not_connected,
        _ => false,
    }
}

/// force_reconnect only enqueues Reconnect and may still flush the old socket.
/// Hard-fail unless a different (server_id, client_id) is observed while Connected.
async fn force_reconnect_and_await_generation(
    client: &Client,
) -> std::result::Result<(), GenerationBarrierFailure> {
    use async_nats::connection::State;
    let before = conn_generation(client);
    // Prefer observing a non-Connected state so we do not mistake the old
    // generation for success when client_id has not changed yet.
    let mut saw_not_connected = !matches!(client.connection_state(), State::Connected);
    if let Err(e) = client.force_reconnect().await {
        return Err(GenerationBarrierFailure {
            before,
            saw_not_connected,
            reconnect_enqueued: false,
            reason: format!("force_reconnect failed: {e}"),
        });
    }

    for _ in 0..200 {
        let connected = matches!(client.connection_state(), State::Connected);
        let now = if connected {
            conn_generation(client)
        } else {
            None
        };
        if observes_generation_change(&before, &mut saw_not_connected, connected, now.as_ref()) {
            info!("NATS reconnected with new generation (before={before:?}, after={now:?})");
            return Ok(());
        }
        sleep(Duration::from_millis(25)).await;
    }

    for _ in 0..200 {
        let connected = matches!(client.connection_state(), State::Connected);
        let now = if connected {
            conn_generation(client)
        } else {
            None
        };
        if observes_generation_change(&before, &mut saw_not_connected, connected, now.as_ref()) {
            info!("NATS reconnected with new generation (before={before:?}, after={now:?})");
            return Ok(());
        }
        sleep(Duration::from_millis(50)).await;
    }

    Err(GenerationBarrierFailure {
        before,
        saw_not_connected,
        reconnect_enqueued: true,
        reason: format!(
            "no observed NATS connection generation change after force_reconnect (state={})",
            client.connection_state()
        ),
    })
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
    let mut marker: RehomeMarker = serde_json::from_str(&raw)
        .with_context(|| format!("parse rehome marker {}", path.display()))?;
    marker.subjects = durable_owned_subjects(marker.subjects);
    Ok(Some(marker))
}

fn write_rehome_marker(path: &Path, marker: &RehomeMarker) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("create rehome marker dir {}", parent.display()))?;
    }
    let persisted = RehomeMarker {
        target_stream: marker.target_stream.clone(),
        subjects: durable_owned_subjects(marker.subjects.clone()),
    };
    let raw = serde_json::to_string_pretty(&persisted)?;
    let tmp = path.with_extension("json.tmp");
    {
        use std::io::Write;
        let mut f = fs::File::create(&tmp)
            .with_context(|| format!("write rehome marker temp {}", tmp.display()))?;
        f.write_all(raw.as_bytes())?;
        f.sync_all()
            .with_context(|| format!("fsync rehome marker temp {}", tmp.display()))?;
    }
    fs::rename(&tmp, path).with_context(|| format!("persist rehome marker {}", path.display()))?;
    // Directory entry must survive power loss before remote NATS detach.
    if let Some(parent) = path.parent() {
        fsync_dir(parent)?;
    }
    Ok(())
}

/// Detach subjects from a JetStream stream (inverse of rehome attach).
async fn detach_subjects_from_stream(
    js: &jetstream::Context,
    stream_name: &str,
    subjects: &[String],
) -> Result<()> {
    if subjects.is_empty() {
        return Ok(());
    }
    let mut stream = match js.get_stream(stream_name).await {
        Ok(s) => s,
        Err(err) if is_stream_not_found(&err) => {
            info!("stream '{stream_name}' already absent during detach");
            return Ok(());
        }
        Err(err) => {
            return Err(anyhow::anyhow!(
                "failed to INFO stream '{stream_name}' during detach: {err}"
            ));
        }
    };
    let info = stream.info().await?;
    let mut updated = info.config.clone();
    let before = updated.subjects.len();
    updated
        .subjects
        .retain(|s| !subjects.iter().any(|d| d == s));
    if updated.subjects.len() == before {
        return Ok(());
    }
    // Keep at least one subject if stream would become empty — NATS may reject.
    if updated.subjects.is_empty() {
        warn!(
            "detach would empty stream '{stream_name}'; leaving placeholder subject {DETACHED_SENTINEL_SUBJECT}"
        );
        updated.subjects.push(DETACHED_SENTINEL_SUBJECT.to_string());
    }
    let removed = before.saturating_sub(updated.subjects.len());
    js.update_stream(updated).await?;
    info!("Detached {removed} subject(s) from stream '{stream_name}'");
    Ok(())
}

fn fsync_dir(dir: &Path) -> Result<()> {
    let f = fs::File::open(dir).with_context(|| format!("open dir for fsync {}", dir.display()))?;
    f.sync_all()
        .with_context(|| format!("fsync dir {}", dir.display()))?;
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
) -> Result<(Duration, Vec<String>)> {
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
            // Verified INFO subjects (includes pre-existing extensions not in target).
            Ok((
                verified_info.config.duplicate_window,
                verified_info.config.subjects.clone(),
            ))
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
            Ok((
                verified_info.config.duplicate_window,
                verified_info.config.subjects.clone(),
            ))
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
    // Host-slice subjects are only rehomeable when explicitly configured; the
    // attribution joiner path is not part of this change (see OpenSpec).
    subject.starts_with("flow.host-slice.") && required_subjects.iter().any(|req| req == subject)
}

/// True when a NATS **wildcard** filter intersects the protected namespaces
/// `flows.raw.>` or `flow.host-slice.>` (symbolic intersection, not finite probes).
/// Concrete leaves are not "overlap filters" and return false.
pub(crate) fn pattern_overlaps_flow_namespace(filter: &str) -> bool {
    if filter.is_empty() {
        return false;
    }
    // Concrete subjects (no whole-token wildcards) are exact ownership claims.
    if exact_nats_subject(filter) {
        return false;
    }
    nats_filters_intersect(filter, "flows.raw.>")
        || nats_filters_intersect(filter, "flow.host-slice.>")
}

/// True when there exists at least one concrete subject matched by both filters.
pub(crate) fn nats_filters_intersect(a: &str, b: &str) -> bool {
    let a: Vec<&str> = a.split('.').collect();
    let b: Vec<&str> = b.split('.').collect();
    filter_tokens_intersect(&a, &b)
}

fn filter_tokens_intersect(a: &[&str], b: &[&str]) -> bool {
    if a.is_empty() && b.is_empty() {
        return true;
    }
    if a.is_empty() || b.is_empty() {
        return false;
    }
    let (ha, ta) = (a[0], &a[1..]);
    let (hb, tb) = (b[0], &b[1..]);
    match (ha, hb) {
        // Final `>` matches one or more remaining tokens on the other side.
        (">", _) if a.len() == 1 => !b.is_empty(),
        (_, ">") if b.len() == 1 => !a.is_empty(),
        // `>` not terminal is not valid NATS — treat as non-intersecting.
        (">", _) | (_, ">") => false,
        // `*` matches exactly one token (literal, `*`, but not multi-token `>`).
        ("*", _) | (_, "*") => filter_tokens_intersect(ta, tb),
        (la, lb) if la == lb => filter_tokens_intersect(ta, tb),
        _ => false,
    }
}

/// Protocol-safe concrete NATS subject with no wildcard tokens.
pub(crate) fn exact_nats_subject(subject: &str) -> bool {
    is_protocol_valid_nats_subject(subject)
        && subject
            .split('.')
            .all(|t| !t.is_empty() && t != "*" && t != ">")
}

/// Protocol framing plus NATS filter grammar. Wildcards are recognized only
/// when `*` or `>` occupies a whole token; embedded characters remain literal.
/// A whole-token `>` must be terminal.
pub(crate) fn is_protocol_valid_nats_subject(subject: &str) -> bool {
    let bytes = subject.as_bytes();
    if bytes.is_empty() {
        return false;
    }
    if bytes[0] == b'.'
        || bytes[bytes.len() - 1] == b'.'
        || subject.contains("..")
        || bytes
            .iter()
            .any(|b| matches!(b, b' ' | b'\t' | b'\r' | b'\n'))
    {
        return false;
    }

    let tokens: Vec<&str> = subject.split('.').collect();
    tokens
        .iter()
        .enumerate()
        .all(|(index, token)| *token != ">" || index == tokens.len() - 1)
}

/// Listener publish subjects must be concrete and protocol-valid.
pub(crate) fn is_valid_listener_publish_subject(subject: &str) -> bool {
    exact_nats_subject(subject)
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
                DETACHED_SENTINEL_SUBJECT.to_string(),
                "flows.raw.ipfix".to_string(),
                "flows.raw.netflow".to_string(),
            ],
        };
        write_rehome_marker(&path, &marker).unwrap();
        let loaded = load_rehome_marker(&path).unwrap().expect("marker present");
        assert_eq!(loaded.target_stream, "flows");
        assert_eq!(
            loaded.subjects,
            vec![
                "flows.raw.ipfix".to_string(),
                "flows.raw.netflow".to_string()
            ]
        );
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
        use async_nats::jetstream::context::PublishError;
        let timed = PublishError::new(PublishErrorKind::TimedOut);
        assert_eq!(
            classify_publish_error(&timed),
            PublishDisposition::Ambiguous
        );
        let pipe = PublishError::new(PublishErrorKind::BrokenPipe);
        assert_eq!(classify_publish_error(&pipe), PublishDisposition::Ambiguous);
        let missing = PublishError::new(PublishErrorKind::StreamNotFound);
        assert_eq!(
            classify_publish_error(&missing),
            PublishDisposition::StreamMissing
        );
        let payload = PublishError::new(PublishErrorKind::MaxPayloadExceeded);
        assert_eq!(
            classify_publish_error(&payload),
            PublishDisposition::Permanent
        );
        let pending = PublishError::new(PublishErrorKind::MaxAckPending);
        assert_eq!(
            classify_publish_error(&pending),
            PublishDisposition::Transient
        );
        // Other without jetstream source ⇒ ambiguous (possible malformed positive ACK).
        let other = PublishError::new(PublishErrorKind::Other);
        assert_eq!(
            classify_publish_error(&other),
            PublishDisposition::Ambiguous
        );
        // Other with jetstream Error source ⇒ negative.
        let js_err: async_nats::jetstream::Error = serde_json::from_str(
            r#"{"code":503,"err_code":10023,"description":"insufficient resources"}"#,
        )
        .expect("jetstream error fixture");
        let negative = PublishError::with_source(PublishErrorKind::Other, js_err);
        assert_eq!(
            classify_publish_error(&negative),
            PublishDisposition::Negative
        );
    }

    #[test]
    fn ever_ambiguous_preserves_horizon_after_clear() {
        let mut item = PendingPublish::new("flows.raw.netflow".into(), vec![1]);
        item = item.mark_ambiguous();
        item = item.clear_attempt_if_certain();
        assert!(item.first_attempt_at.is_some());
        assert!(item.ever_ambiguous);
        assert!(!past_retry_horizon(&item, Duration::from_secs(90)));
    }

    #[test]
    fn pattern_overlaps_flow_namespace_symbolic() {
        assert!(pattern_overlaps_flow_namespace("flows.>"));
        assert!(pattern_overlaps_flow_namespace("flows.raw.>"));
        assert!(pattern_overlaps_flow_namespace("*.>"));
        assert!(pattern_overlaps_flow_namespace("*.raw.>"));
        assert!(pattern_overlaps_flow_namespace("*.*.>"));
        assert!(pattern_overlaps_flow_namespace("flow.>"));
        assert!(pattern_overlaps_flow_namespace(">"));
        // Non-probe extensions / mid-token patterns must still intersect.
        assert!(pattern_overlaps_flow_namespace("flows.*.vendor"));
        assert!(pattern_overlaps_flow_namespace("flows.raw.custom.>"));
        assert!(pattern_overlaps_flow_namespace("flow.*.vendor"));
        assert!(!pattern_overlaps_flow_namespace("logs.>"));
        assert!(!pattern_overlaps_flow_namespace("events.>"));
        // Concrete leaves are not wildcard overlap filters.
        assert!(!pattern_overlaps_flow_namespace("flows.raw.netflow"));
        assert!(!pattern_overlaps_flow_namespace("flow.host-slice.agent-1"));
    }

    #[test]
    fn nats_filters_intersect_extension_patterns() {
        assert!(nats_filters_intersect("flows.*.vendor", "flows.raw.>"));
        assert!(nats_filters_intersect("flows.raw.custom.>", "flows.raw.>"));
        assert!(nats_filters_intersect("flow.*.vendor", "flow.host-slice.>"));
        assert!(!nats_filters_intersect("logs.>", "flows.raw.>"));
        assert!(!nats_filters_intersect("events.>", "flows.raw.>"));
    }

    #[test]
    fn exact_nats_subject_rejects_whitespace() {
        assert!(exact_nats_subject("flows.raw.netflow"));
        assert!(!exact_nats_subject("flows.raw.bad subject"));
        assert!(!exact_nats_subject("flows.raw.\tnetflow"));
        assert!(!exact_nats_subject(""));
        assert!(!exact_nats_subject(".flows.raw"));
        assert!(!exact_nats_subject("flows.raw."));
        assert!(!exact_nats_subject("flows..raw"));
    }

    #[test]
    fn nats_filter_grammar_treats_only_whole_tokens_as_wildcards() {
        for valid in [
            "logs.*.vendor",
            "logs.vendor.>",
            "logs.vendor>.tail",
            "logs.vend*or",
            "*",
            ">",
        ] {
            assert!(is_protocol_valid_nats_subject(valid), "{valid}");
        }
        for invalid in ["logs.>.vendor", "logs.>.>"] {
            assert!(!is_protocol_valid_nats_subject(invalid), "{invalid}");
        }
        assert!(exact_nats_subject("flows.raw.vendor*name"));
        assert!(exact_nats_subject("flows.raw.vendor>name"));
        assert!(!exact_nats_subject("flows.raw.*"));
        assert!(!exact_nats_subject("flows.raw.>"));
    }

    #[test]
    fn generation_barrier_never_releases_on_same_connected_generation() {
        let old = ConnGeneration {
            server_id: "server-a".to_string(),
            client_id: 41,
        };
        let same = old.clone();
        let next = ConnGeneration {
            server_id: "server-a".to_string(),
            client_id: 42,
        };
        let before = Some(old);
        let mut saw_not_connected = false;
        assert!(!observes_generation_change(
            &before,
            &mut saw_not_connected,
            true,
            Some(&same)
        ));
        assert!(!observes_generation_change(
            &before,
            &mut saw_not_connected,
            false,
            None
        ));
        assert!(saw_not_connected);
        assert!(!observes_generation_change(
            &before,
            &mut saw_not_connected,
            true,
            Some(&same)
        ));
        assert!(observes_generation_change(
            &before,
            &mut saw_not_connected,
            true,
            Some(&next)
        ));

        let mut no_baseline_transition = false;
        assert!(!observes_generation_change(
            &None,
            &mut no_baseline_transition,
            true,
            Some(&next)
        ));
        assert!(!observes_generation_change(
            &None,
            &mut no_baseline_transition,
            false,
            None
        ));
        assert!(observes_generation_change(
            &None,
            &mut no_baseline_transition,
            true,
            Some(&next)
        ));
    }

    #[test]
    fn reconnect_command_failure_is_fatal_not_quarantinable() {
        let terminal = GenerationBarrierFailure {
            before: None,
            saw_not_connected: false,
            reconnect_enqueued: false,
            reason: "client command channel closed".to_string(),
        };
        let timed_out = GenerationBarrierFailure {
            before: None,
            saw_not_connected: true,
            reconnect_enqueued: true,
            reason: "generation transition timed out".to_string(),
        };

        assert!(!terminal.can_quarantine());
        assert!(timed_out.can_quarantine());
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
                DETACHED_SENTINEL_SUBJECT.to_string(),
                "flows.raw.netflow".to_string(),
                "flows.raw.ipfix".to_string(),
            ],
        };
        write_ownership_inventory(&path, &inv).unwrap();
        let loaded = load_ownership_inventory(&path).unwrap().expect("present");
        assert_eq!(loaded.stream, "flows");
        assert!(loaded.subjects.iter().any(|s| s == "flows.raw.ipfix"));
        assert!(
            !loaded
                .subjects
                .iter()
                .any(|s| s == DETACHED_SENTINEL_SUBJECT)
        );
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn rollback_forward_rollback_never_restores_detached_sentinel() {
        let required = vec!["flows.raw.netflow".to_string()];
        let first_inventory = OwnershipInventory {
            stream: "flows".to_string(),
            subjects: required.clone(),
        };
        let first_restore = rollback_restore_subjects(&required, &[], Some(&first_inventory));
        assert_eq!(first_restore, required);

        // First rollback leaves the plumbing sentinel on the empty `flows`
        // stream. A subsequent forward ensure reports sentinel + real subject.
        let verified_after_forward = vec![
            DETACHED_SENTINEL_SUBJECT.to_string(),
            "flows.raw.netflow".to_string(),
        ];
        let second_inventory = OwnershipInventory {
            stream: "flows".to_string(),
            subjects: durable_owned_subjects(verified_after_forward),
        };

        let second_restore = rollback_restore_subjects(&required, &[], Some(&second_inventory));
        assert_eq!(second_restore, vec!["flows.raw.netflow".to_string()]);
        let sources = rollback_detach_sources(None, Some(&second_inventory));
        assert_eq!(
            sources,
            vec![("flows".to_string(), vec!["flows.raw.netflow".to_string()])]
        );
    }

    #[test]
    fn rollback_uses_forward_marker_target_when_inventory_is_stale() {
        let marker = RehomeMarker {
            target_stream: "flows".to_string(),
            subjects: vec!["flows.raw.ipfix".to_string()],
        };
        let stale_inventory = OwnershipInventory {
            stream: "events".to_string(),
            subjects: vec!["flows.raw.netflow".to_string()],
        };
        assert_eq!(
            rollback_detach_sources(Some(&marker), Some(&stale_inventory)),
            vec![("flows".to_string(), vec!["flows.raw.ipfix".to_string()])]
        );
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
