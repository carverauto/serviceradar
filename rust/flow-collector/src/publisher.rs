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

        // JetStream allows a subject on only one stream. When moving off the
        // historical shared `events` bus onto dedicated `flows`, strip flow
        // subjects from `events` first so STREAM.CREATE does not hit overlap.
        if self.config.stream_name != "events"
            && let Err(err) = rehome_subjects_from_events(&js, &required_subjects).await
        {
            warn!(
                "Could not rehome flow subjects off shared events stream (continuing): {}",
                err
            );
        }

        match js.get_stream(&self.config.stream_name).await {
            Ok(mut existing_stream) => {
                let info = existing_stream.info().await?;
                let mut updated_config = info.config.clone();
                let mut needs_update = false;

                for required in &required_subjects {
                    if !updated_config.subjects.contains(required) {
                        updated_config.subjects.push(required.clone());
                        needs_update = true;
                    }
                }

                if updated_config.num_replicas != self.config.stream_replicas {
                    updated_config.num_replicas = self.config.stream_replicas;
                    needs_update = true;
                }

                if updated_config.max_bytes != self.config.stream_max_bytes {
                    info!(
                        "Updating stream '{}' max_bytes from {} to {}",
                        self.config.stream_name,
                        updated_config.max_bytes,
                        self.config.stream_max_bytes
                    );
                    updated_config.max_bytes = self.config.stream_max_bytes;
                    needs_update = true;
                }

                if updated_config.max_age != desired_max_age {
                    info!(
                        "Updating stream '{}' max_age from {:?} to {:?}",
                        self.config.stream_name, updated_config.max_age, desired_max_age
                    );
                    updated_config.max_age = desired_max_age;
                    needs_update = true;
                }

                // Keep limits + discard-old so lag cannot grow the stream forever.
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
                    js.get_stream(&self.config.stream_name).await?;
                }
            }
            Err(_) => {
                let stream_config = jetstream::stream::Config {
                    name: self.config.stream_name.clone(),
                    subjects: required_subjects.clone(),
                    storage: StorageType::File,
                    retention: RetentionPolicy::Limits,
                    discard: DiscardPolicy::Old,
                    max_bytes: self.config.stream_max_bytes,
                    max_age: desired_max_age,
                    num_replicas: self.config.stream_replicas,
                    ..Default::default()
                };
                js.get_or_create_stream(stream_config).await?;
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

/// Removes `required_subjects` from the shared `events` stream when present so a
/// dedicated flows stream can own them exclusively.
async fn rehome_subjects_from_events(
    js: &jetstream::Context,
    required_subjects: &[String],
) -> Result<()> {
    let mut events = match js.get_stream("events").await {
        Ok(stream) => stream,
        Err(_) => return Ok(()),
    };

    let info = events.info().await?;
    let before = info.config.subjects.len();
    let mut updated = info.config.clone();
    updated
        .subjects
        .retain(|s| !required_subjects.iter().any(|req| req == s) && !s.starts_with("flows.raw."));

    if updated.subjects.len() == before {
        return Ok(());
    }

    info!(
        "Removing flow subjects from shared events stream ({} → {} subjects) so stream can own them exclusively",
        before,
        updated.subjects.len()
    );
    js.update_stream(updated).await?;
    Ok(())
}
