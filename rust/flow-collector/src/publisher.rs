use crate::config::{Config, SecurityMode};
use crate::metrics::HostSliceMetricsRegistry;
use anyhow::{Context, Result};
use async_nats::jetstream::{
    self,
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
use tokio::time::{sleep, timeout};

/// Preferred JetStream de-duplication window for the dedicated flows stream.
/// Capped by max_age and the common NATS server limit (jetstream.limits.duplicate_window,
/// default 2m). Raising above the server limit fails stream create with 10052.
pub(crate) const PREFERRED_DUPLICATE_WINDOW_SECS: u64 = 120;
/// Max concurrent JetStream publish+ACK futures (bounds worst-case pass time).
const PUBLISH_CONCURRENCY: usize = 32;

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
    rx: mpsc::Receiver<(String, Vec<u8>)>,
    host_slice_metrics: Arc<HostSliceMetricsRegistry>,
    /// Subjects removed from `events` but not yet confirmed on the target stream.
    /// Preserved across connect retries so a failed restore cannot orphan extension subjects.
    pending_rehome: Vec<String>,
}

impl Publisher {
    pub fn new(
        config: Arc<Config>,
        rx: mpsc::Receiver<(String, Vec<u8>)>,
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
        let (client, js, verified_dup_window) = self.connect_with_retry().await?;
        let max_retry_age = max_retry_age_from_window(verified_dup_window);
        mark_publisher_ready(&self.config)?;

        let timeout_duration = Duration::from_millis(self.config.publish_timeout_ms);
        let max_retry_queue = self
            .config
            .channel_size
            .max(self.config.batch_size.saturating_mul(4));
        let mut retry_q: VecDeque<PendingPublish> = VecDeque::new();
        let mut backoff = Duration::from_millis(100);
        let max_backoff = Duration::from_secs(5);
        info!(
            "Publisher started (dup_window={:?}, max_retry_age={:?}, concurrency={})",
            verified_dup_window, max_retry_age, PUBLISH_CONCURRENCY
        );

        loop {
            if !retry_q.is_empty() {
                expire_old_retries(&mut retry_q, max_retry_age);
                wait_until_connected(&client).await;
                self.publish_pending(&client, &js, &mut retry_q, timeout_duration, max_retry_age)
                    .await;
                if !retry_q.is_empty() {
                    sleep(backoff).await;
                    backoff = min(backoff.saturating_mul(2), max_backoff);
                    continue;
                }
                backoff = Duration::from_millis(100);
            }

            let msg = match self.rx.recv().await {
                Some(msg) => msg,
                None => {
                    return self
                        .drain_retries_until_empty(
                            &client,
                            &js,
                            &mut retry_q,
                            timeout_duration,
                            max_retry_age,
                        )
                        .await;
                }
            };

            let mut batch = Vec::with_capacity(self.config.batch_size);
            batch.push(PendingPublish::new(msg.0, msg.1));

            let mut closed = false;
            while batch.len() < self.config.batch_size {
                match self.rx.try_recv() {
                    Ok((subject, payload)) => batch.push(PendingPublish::new(subject, payload)),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        closed = true;
                        break;
                    }
                }
            }

            let mut pending: VecDeque<PendingPublish> = batch.into();
            wait_until_connected(&client).await;
            self.publish_pending(&client, &js, &mut pending, timeout_duration, max_retry_age)
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

            if closed {
                return self
                    .drain_retries_until_empty(
                        &client,
                        &js,
                        &mut retry_q,
                        timeout_duration,
                        max_retry_age,
                    )
                    .await;
            }
        }
    }

    async fn drain_retries_until_empty(
        &self,
        client: &Client,
        js: &jetstream::Context,
        retry_q: &mut VecDeque<PendingPublish>,
        timeout_duration: Duration,
        max_retry_age: Duration,
    ) -> Result<()> {
        let mut backoff = Duration::from_millis(100);
        let max_backoff = Duration::from_secs(5);
        let mut attempts = 0u32;
        while !retry_q.is_empty() {
            expire_old_retries(retry_q, max_retry_age);
            if retry_q.is_empty() {
                break;
            }
            attempts += 1;
            wait_until_connected(client).await;
            self.publish_pending(client, js, retry_q, timeout_duration, max_retry_age)
                .await;
            if retry_q.is_empty() {
                break;
            }
            if attempts >= 120 {
                return Err(anyhow::anyhow!(
                    "publisher shutting down with {} unacked flow message(s)",
                    retry_q.len()
                ));
            }
            sleep(backoff).await;
            backoff = min(backoff.saturating_mul(2), max_backoff);
        }
        info!("Publisher channel closed, shutting down");
        Ok(())
    }

    async fn publish_pending(
        &self,
        client: &Client,
        js: &jetstream::Context,
        pending: &mut VecDeque<PendingPublish>,
        timeout_duration: Duration,
        max_retry_age: Duration,
    ) {
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
            return;
        }
        let limit = pending.len().min(self.config.batch_size.max(1));
        if limit == 0 {
            return;
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
            let js = js.clone();
            let client = client.clone();
            let sem = semaphore.clone();
            let metrics = self.host_slice_metrics.clone();
            set.spawn(async move {
                // Recheck age immediately before send — a long concurrent pass can
                // push later items past the dedup window if only checked once.
                if item.first_seen.elapsed() > max_retry_age {
                    error!(
                        "Dropping publish for subject {} id={} at send (age {:?} > {:?})",
                        item.subject,
                        item.msg_id,
                        item.first_seen.elapsed(),
                        max_retry_age
                    );
                    return Ok(());
                }
                let _permit = match sem.acquire_owned().await {
                    Ok(p) => p,
                    Err(_) => return Err(item),
                };
                if item.first_seen.elapsed() > max_retry_age {
                    error!(
                        "Dropping publish for subject {} id={} after permit wait (age {:?} > {:?})",
                        item.subject,
                        item.msg_id,
                        item.first_seen.elapsed(),
                        max_retry_age
                    );
                    return Ok(());
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
                    return Err(item);
                }

                match js.send_publish(item.subject.clone(), publish).await {
                    Ok(ack) => match timeout(timeout_duration, ack).await {
                        Ok(Ok(_seq)) => {
                            metrics.record_publish(&item.subject, bytes);
                            Ok(())
                        }
                        Ok(Err(e)) => {
                            error!(
                                "NATS publish ack failed for subject {} id={} (will retry): {}",
                                item.subject, item.msg_id, e
                            );
                            Err(item)
                        }
                        Err(_) => {
                            // Do NOT requeue on timeout: async-nats may still hold the
                            // original Command::Request across reconnect; a second publish
                            // after duplicate_window expires would create a duplicate row.
                            warn!(
                                "NATS ack timed out after {:?} for subject {} id={}; not retrying (reconnect-buffer safety)",
                                timeout_duration, item.subject, item.msg_id
                            );
                            Ok(())
                        }
                    },
                    Err(e) => {
                        error!(
                            "Failed to publish to NATS subject {} id={}: {}",
                            item.subject, item.msg_id, e
                        );
                        Err(item)
                    }
                }
            });
        }

        let mut failed = VecDeque::new();
        while let Some(joined) = set.join_next().await {
            match joined {
                Ok(Ok(())) => {}
                Ok(Err(item)) => failed.push_back(item),
                Err(e) => error!("publish task join error: {}", e),
            }
        }

        // Preserve remaining unattempted (if any) then failures.
        failed.append(pending);
        *pending = failed;
    }

    async fn connect_once(&mut self) -> Result<(Client, jetstream::Context, Duration)> {
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
        let js = jetstream::new(client.clone());

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
            let dup_window = ensure_legacy_events_subjects_only(&js, &restore).await?;
            // Verify ownership then clear marker.
            self.pending_rehome.clear();
            clear_rehome_marker(&rehome_path);
            info!(
                "Connected to NATS at {} (legacy events stream, dup_window={:?})",
                self.config.nats_url, dup_window
            );
            return Ok((client, js, dup_window));
        }

        // Dedicated flows stream path
        {
            // Rehome flow subjects off events onto the dedicated stream.
            match rehome_subjects_from_events(
                &js,
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

            let dup_window = match ensure_flows_stream(
                &js,
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
                    window
                }
                Err(err) => {
                    if !self.pending_rehome.is_empty() {
                        match restore_subjects_to_events(&js, &self.pending_rehome).await {
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

            Ok((client, js, dup_window))
        }
    }

    async fn connect_with_retry(&mut self) -> Result<(Client, jetstream::Context, Duration)> {
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
    Ok(info.config.duplicate_window)
}

#[derive(Debug, Clone)]
struct PendingPublish {
    subject: String,
    payload: Vec<u8>,
    msg_id: String,
    first_seen: Instant,
}

impl PendingPublish {
    fn new(subject: String, payload: Vec<u8>) -> Self {
        Self {
            subject,
            payload,
            msg_id: next_msg_id(),
            first_seen: Instant::now(),
        }
    }
}

fn expire_old_retries(retry_q: &mut VecDeque<PendingPublish>, max_age: Duration) {
    let before = retry_q.len();
    retry_q.retain(|item| {
        if item.first_seen.elapsed() <= max_age {
            true
        } else {
            error!(
                "Dropping publish retry for subject {} id={} after {:?} (exceeds retry horizon under duplicate_window)",
                item.subject,
                item.msg_id,
                item.first_seen.elapsed()
            );
            false
        }
    });
    let dropped = before.saturating_sub(retry_q.len());
    if dropped > 0 {
        warn!("Expired {} publish retries past max retry age", dropped);
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

/// Derive retry horizon strictly from a **verified** stream duplicate_window.
/// Never invent a larger fallback — that would allow double-accept after reconnect.
/// A zero window means no server-side dedup: expire retries immediately.
fn max_retry_age_from_window(window: Duration) -> Duration {
    if window.is_zero() {
        return Duration::ZERO;
    }
    // Keep margin under the dedup window for concurrent pass latency.
    let margin = Duration::from_secs(15).min(window / 4);
    let derived = window.saturating_sub(margin);
    if derived.is_zero() {
        window / 2
    } else {
        derived
    }
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
    fn max_retry_age_never_exceeds_verified_window() {
        assert_eq!(max_retry_age_from_window(Duration::ZERO), Duration::ZERO);
        let age_60 = max_retry_age_from_window(Duration::from_secs(60));
        assert!(age_60 < Duration::from_secs(60));
        assert!(age_60 > Duration::ZERO);
        let age_120 = max_retry_age_from_window(Duration::from_secs(120));
        assert!(age_120 <= Duration::from_secs(105)); // 120 - 15
        assert!(age_120 >= Duration::from_secs(90));
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
