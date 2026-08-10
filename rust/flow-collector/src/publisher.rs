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
use std::sync::atomic::{AtomicU64, Ordering};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TryRecvError;
use tokio::time::{sleep, timeout};

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
        let (_, js) = self.connect_with_retry().await?;
        mark_publisher_ready(&self.config);

        let timeout_duration = Duration::from_millis(self.config.publish_timeout_ms);
        let max_retry_queue = self.config.channel_size.max(self.config.batch_size.saturating_mul(4));
        let mut retry_q: VecDeque<PendingPublish> = VecDeque::new();
        let mut backoff = Duration::from_millis(100);
        let max_backoff = Duration::from_secs(5);

        info!("Publisher started");

        loop {
            // Drive retained failures from an independent retry path so a quiet
            // exporter cannot strand messages behind a blocked recv().
            if !retry_q.is_empty() {
                self.publish_pending(&js, &mut retry_q, timeout_duration, max_retry_queue)
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
                    // Channel closed: drain retries until empty or give up with error.
                    let mut attempts = 0u32;
                    while !retry_q.is_empty() {
                        attempts += 1;
                        self.publish_pending(&js, &mut retry_q, timeout_duration, max_retry_queue)
                            .await;
                        if retry_q.is_empty() {
                            break;
                        }
                        if attempts >= 60 {
                            return Err(anyhow::anyhow!(
                                "publisher shutting down with {} unacked flow message(s)",
                                retry_q.len()
                            ));
                        }
                        sleep(backoff).await;
                        backoff = min(backoff.saturating_mul(2), max_backoff);
                    }
                    info!("Publisher channel closed, shutting down");
                    return Ok(());
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
            self.publish_pending(&js, &mut pending, timeout_duration, max_retry_queue)
                .await;
            // Move residual failures onto the durable retry queue.
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
                // Same shutdown drain as channel-closed path.
                let mut attempts = 0u32;
                while !retry_q.is_empty() {
                    attempts += 1;
                    self.publish_pending(&js, &mut retry_q, timeout_duration, max_retry_queue)
                        .await;
                    if retry_q.is_empty() {
                        break;
                    }
                    if attempts >= 60 {
                        return Err(anyhow::anyhow!(
                            "publisher shutting down with {} unacked flow message(s)",
                            retry_q.len()
                        ));
                    }
                    sleep(backoff).await;
                    backoff = min(backoff.saturating_mul(2), max_backoff);
                }
                info!("Publisher channel closed, shutting down");
                return Ok(());
            }
        }
    }

    async fn publish_pending(
        &self,
        js: &jetstream::Context,
        pending: &mut VecDeque<PendingPublish>,
        timeout_duration: Duration,
        _max_retry_queue: usize,
    ) {
        let mut still_failed: VecDeque<PendingPublish> = VecDeque::new();
        let limit = pending.len().min(self.config.batch_size.max(1));

        for _ in 0..limit {
            let Some(item) = pending.pop_front() else {
                break;
            };
            let bytes = item.payload.len();
            let publish = PublishMessage::build()
                .payload(item.payload.clone().into())
                .message_id(item.msg_id.clone());

            match js.send_publish(item.subject.clone(), publish).await {
                Ok(ack) => match timeout(timeout_duration, ack).await {
                    Ok(Ok(_seq)) => {
                        self.host_slice_metrics
                            .record_publish(&item.subject, bytes);
                    }
                    Ok(Err(e)) => {
                        error!(
                            "NATS publish ack failed for subject {} id={} (will retry): {}",
                            item.subject, item.msg_id, e
                        );
                        still_failed.push_back(item);
                    }
                    Err(_) => {
                        warn!(
                            "NATS ack timed out after {:?} for subject {} id={} (will retry)",
                            timeout_duration, item.subject, item.msg_id
                        );
                        still_failed.push_back(item);
                    }
                },
                Err(e) => {
                    error!(
                        "Failed to publish to NATS subject {} id={}: {}",
                        item.subject, item.msg_id, e
                    );
                    still_failed.push_back(item);
                }
            }
        }

        // Preserve order: remaining unattempted first, then new failures.
        let mut rest = std::mem::take(pending);
        still_failed.append(&mut rest);
        *pending = still_failed;
    }

    async fn connect_once(&mut self) -> Result<(Client, jetstream::Context)> {
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

        // Recover durable rehome marker from a previous process that may have
        // detached subjects from events without attaching them to the target.
        if let Some(marker) = load_rehome_marker(&rehome_path)?
            && marker.target_stream == self.config.stream_name
        {
            for subject in marker.subjects {
                if !self.pending_rehome.iter().any(|s| s == &subject) {
                    self.pending_rehome.push(subject);
                }
            }
            info!(
                "Loaded {} subject(s) from durable rehome marker at {}",
                self.pending_rehome.len(),
                rehome_path.display()
            );
        }

        if self.config.stream_name == "events" {
            // Legacy conffiles still target events. Never reshape the shared
            // multi-signal stream with flow retention defaults — subject-merge only.
            warn!(
                "flow-collector stream_name is 'events' (legacy). Refusing to apply                  stream_max_bytes/max_age to the shared events bus. Migrate config to                  stream_name=flows (see docs/docs/netflow.md)."
            );
            ensure_legacy_events_subjects_only(&js, &required_subjects).await?;
        } else {
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

            match ensure_flows_stream(
                &js,
                &self.config.stream_name,
                &target_subjects,
                self.config.stream_max_bytes,
                desired_max_age,
                self.config.stream_replicas,
            )
            .await
            {
                Ok(()) => {
                    self.pending_rehome.clear();
                    clear_rehome_marker(&rehome_path);
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
                                return Err(err.context(format!(
                                    "restore also failed: {restore_err}"
                                )));
                            }
                        }
                    }
                    return Err(err);
                }
            }
        }

        info!(
            "Connected to NATS at {} and ensured stream '{}' exists (max_bytes={}, max_age={:?}, replicas={})",
            self.config.nats_url,
            self.config.stream_name,
            self.config.stream_max_bytes,
            desired_max_age,
            self.config.stream_replicas
        );

        Ok((client, js))
    }

    async fn connect_with_retry(&mut self) -> Result<(Client, jetstream::Context)> {
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

    // Persist before detach so a restart can rediscover extension subjects.
    write_rehome_marker(
        rehome_path,
        &RehomeMarker {
            target_stream: target_stream.to_string(),
            subjects: removed.clone(),
        },
    )?;

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
) -> Result<()> {
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
    if needs_update {
        // Keep prior retention shape — only subject list may change.
        updated.max_bytes = existing_max_bytes;
        updated.max_age = existing_max_age;
        js.update_stream(updated).await?;
        info!("Merged flow subjects into legacy events stream without reshaping retention");
    }
    Ok(())
}


#[derive(Debug, Clone)]
struct PendingPublish {
    subject: String,
    payload: Vec<u8>,
    msg_id: String,
}

impl PendingPublish {
    fn new(subject: String, payload: Vec<u8>) -> Self {
        Self {
            subject,
            payload,
            msg_id: next_msg_id(),
        }
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
    if let Ok(path) = std::env::var("FLOW_COLLECTOR_READY_PATH") {
        return PathBuf::from(path);
    }
    // Co-locate with rehome marker on the data volume.
    let rehome = rehome_state_path(config);
    rehome
        .parent()
        .map(|p| p.join("flow-collector.ready"))
        .unwrap_or_else(|| PathBuf::from("/var/lib/serviceradar/flow-collector.ready"))
}

fn mark_publisher_ready(config: &Config) {
    let path = ready_marker_path(config);
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Err(err) = fs::write(&path, b"ready
") {
        warn!(
            "Failed to write readiness marker {}: {} (probe may stay unready)",
            path.display(),
            err
        );
    } else {
        info!("Publisher ready marker written to {}", path.display());
    }
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
        if !updated.subjects.iter().any(|s| s == subject) {
            updated.subjects.push(subject.clone());
            changed = true;
        }
    }

    if changed {
        warn!(
            "Restoring {} flow subject(s) onto events after target stream ensure failed",
            subjects.len()
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
) -> Result<()> {
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

            if needs_update {
                js.update_stream(updated_config).await?;
                let mut verified = js.get_stream(stream_name).await?;
                let verified_info = verified.info().await?;
                for required in target_subjects {
                    if !verified_info.config.subjects.iter().any(|s| subject_covers(s, required) || s == required) {
                        return Err(anyhow::anyhow!(
                            "stream '{stream_name}' missing required subject '{required}' after update"
                        ));
                    }
                }
            }
            Ok(())
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
                ..Default::default()
            };
            // Prefer create_stream over get_or_create: get_or_create can return an
            // existing handle without applying our config when races occur.
            js.create_stream(stream_config).await?;
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
            Ok(())
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
            subjects: vec!["flows.raw.ipfix".to_string(), "flows.raw.netflow".to_string()],
        };
        write_rehome_marker(&path, &marker).unwrap();
        let loaded = load_rehome_marker(&path).unwrap().expect("marker present");
        assert_eq!(loaded.target_stream, "flows");
        assert_eq!(loaded.subjects, marker.subjects);
        clear_rehome_marker(&path);
        assert!(load_rehome_marker(&path).unwrap().is_none());
    }

    #[test]
    fn wildcard_star_does_not_cover_gt() {
        assert!(!subject_covers("flows.raw.*", "flows.raw.>"));
        assert!(subject_covers("flows.raw.>", "flows.raw.*"));
        let normalized = normalize_stream_subjects(vec![
            "flows.raw.*".to_string(),
            "flows.raw.>".to_string(),
        ]);
        assert_eq!(normalized, vec!["flows.raw.>".to_string()]);
    }
}
