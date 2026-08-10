use crate::config::{Config, SecurityMode};
use crate::metrics::HostSliceMetricsRegistry;
use anyhow::{Context, Result};
use async_nats::jetstream::{
    self,
    stream::{DiscardPolicy, RetentionPolicy, StorageType},
};
use async_nats::{Client, ConnectOptions};
use log::{error, info, warn};
use std::cmp::min;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TryRecvError;
use tokio::time::{sleep, timeout};

pub struct Publisher {
    config: Arc<Config>,
    rx: mpsc::Receiver<(String, Vec<u8>)>,
    host_slice_metrics: Arc<HostSliceMetricsRegistry>,
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
        }
    }

    pub async fn run(mut self) -> Result<()> {
        let (_, js) = self.connect_with_retry().await?;

        let mut batch: Vec<(String, Vec<u8>)> = Vec::with_capacity(self.config.batch_size);
        let timeout_duration = Duration::from_millis(self.config.publish_timeout_ms);

        info!("Publisher started");

        loop {
            let msg = match self.rx.recv().await {
                Some(msg) => msg,
                None => {
                    if !batch.is_empty() {
                        self.publish_batch(&js, &mut batch, timeout_duration).await;
                    }
                    info!("Publisher channel closed, shutting down");
                    return Ok(());
                }
            };

            batch.push(msg);

            let mut closed = false;
            while batch.len() < self.config.batch_size {
                match self.rx.try_recv() {
                    Ok(msg) => batch.push(msg),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        closed = true;
                        break;
                    }
                }
            }

            if !batch.is_empty() {
                self.publish_batch(&js, &mut batch, timeout_duration).await;
            }

            if closed {
                info!("Publisher channel closed, shutting down");
                return Ok(());
            }
        }
    }

    async fn publish_batch(
        &self,
        js: &jetstream::Context,
        batch: &mut Vec<(String, Vec<u8>)>,
        timeout_duration: Duration,
    ) {
        for (subject, msg) in batch.drain(..) {
            let bytes = msg.len();

            match js.publish(subject.clone(), msg.into()).await {
                Ok(ack) => {
                    self.host_slice_metrics.record_publish(&subject, bytes);

                    if timeout(timeout_duration, ack).await.is_err() {
                        warn!("NATS ack timed out after {:?}", timeout_duration);
                    }
                }
                Err(e) => {
                    error!("Failed to publish to NATS: {}", e);
                }
            }
        }
    }

    async fn connect_once(&self) -> Result<(Client, jetstream::Context)> {
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

        // JetStream allows a subject on only one stream. Rehome flow subjects
        // off `events` first, then attach the full removed set to the target
        // stream (including extension subjects not in this process config).
        let rehomed = if self.config.stream_name != "events" {
            match rehome_subjects_from_events(&js, &required_subjects).await {
                Ok(subjects) => subjects,
                Err(err) => {
                    warn!(
                        "Could not rehome flow subjects off shared events stream (continuing): {}",
                        err
                    );
                    Vec::new()
                }
            }
        } else {
            Vec::new()
        };

        let mut target_subjects = required_subjects.clone();
        for subject in &rehomed {
            if !target_subjects.iter().any(|s| s == subject) {
                target_subjects.push(subject.clone());
            }
        }
        target_subjects.sort();
        target_subjects.dedup();

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
            Ok(()) => {}
            Err(err) => {
                if !rehomed.is_empty() {
                    if let Err(restore_err) = restore_subjects_to_events(&js, &rehomed).await {
                        error!(
                            "Failed to restore flow subjects to events after target stream error: {}",
                            restore_err
                        );
                    }
                }
                return Err(err);
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

    async fn connect_with_retry(&self) -> Result<(Client, jetstream::Context)> {
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
async fn rehome_subjects_from_events(
    js: &jetstream::Context,
    required_subjects: &[String],
) -> Result<Vec<String>> {
    let mut events = match js.get_stream("events").await {
        Ok(stream) => stream,
        Err(_) => return Ok(Vec::new()),
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

    info!(
        "Removing {} flow subject(s) from shared events stream so dedicated stream can own them: {:?}",
        removed.len(),
        removed
    );
    js.update_stream(updated).await?;
    Ok(removed)
}

async fn restore_subjects_to_events(js: &jetstream::Context, subjects: &[String]) -> Result<()> {
    if subjects.is_empty() {
        return Ok(());
    }

    let mut events = match js.get_stream("events").await {
        Ok(stream) => stream,
        Err(_) => return Ok(()),
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
                if !updated_config.subjects.contains(required) {
                    updated_config.subjects.push(required.clone());
                    needs_update = true;
                }
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
                js.get_stream(stream_name).await?;
            }
            Ok(())
        }
        Err(_) => {
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
            js.get_or_create_stream(stream_config).await?;
            Ok(())
        }
    }
}

pub(crate) fn is_rehomeable_flow_subject(subject: &str, required_subjects: &[String]) -> bool {
    if subject.starts_with("flows.raw.") {
        return true;
    }
    // Host-slice subjects only rehome when this collector is configured to publish them.
    subject.starts_with("flow.host-slice.") && required_subjects.iter().any(|req| req == subject)
}
