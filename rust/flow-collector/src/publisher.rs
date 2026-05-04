use crate::config::Config;
use crate::nats_client;
use anyhow::Result;
use async_nats::jetstream::{self, stream::StorageType};
use async_nats::Client;
use log::{error, info, warn};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TryRecvError;
use tokio::time::timeout;

pub struct Publisher {
    config: Arc<Config>,
    rx: mpsc::Receiver<(String, Vec<u8>)>,
}

impl Publisher {
    pub fn new(config: Arc<Config>, rx: mpsc::Receiver<(String, Vec<u8>)>) -> Self {
        Self { config, rx }
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
            match js.publish(subject, msg.into()).await {
                Ok(ack) => {
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
        let (client, js) = nats_client::connect_once(&self.config.nats_url, &self.config).await?;

        let required_subjects = self.config.stream_subjects_resolved();
        match js.get_stream(&self.config.stream_name).await {
            Ok(mut existing_stream) => {
                let info = existing_stream.info().await?;
                let mut current_subjects = info.config.subjects.clone();
                let mut needs_update = false;

                for required in &required_subjects {
                    if !current_subjects.contains(required) {
                        current_subjects.push(required.clone());
                        needs_update = true;
                    }
                }

                if needs_update {
                    let mut updated_config = info.config.clone();
                    updated_config.subjects = current_subjects;
                    updated_config.num_replicas = self.config.stream_replicas;
                    js.update_stream(updated_config).await?;
                    js.get_stream(&self.config.stream_name).await?;
                } else if info.config.num_replicas != self.config.stream_replicas {
                    let mut updated_config = info.config.clone();
                    updated_config.num_replicas = self.config.stream_replicas;
                    js.update_stream(updated_config).await?;
                    js.get_stream(&self.config.stream_name).await?;
                }
            }
            Err(_) => {
                let stream_config = jetstream::stream::Config {
                    name: self.config.stream_name.clone(),
                    subjects: required_subjects.clone(),
                    storage: StorageType::File,
                    max_bytes: self.config.stream_max_bytes,
                    max_age: Duration::from_secs(24 * 60 * 60),
                    num_replicas: self.config.stream_replicas,
                    ..Default::default()
                };
                js.get_or_create_stream(stream_config).await?;
            }
        }

        info!(
            "Connected to NATS at {} and ensured stream '{}' exists",
            self.config.nats_url, self.config.stream_name
        );

        Ok((client, js))
    }

    /// Wraps `connect_once` (which connects + sets up the events stream)
    /// with the shared retry helper.
    async fn connect_with_retry(&self) -> Result<(Client, jetstream::Context)> {
        let mut attempt: u32 = 0;
        let initial_backoff = Duration::from_millis(500);
        let max_backoff = Duration::from_secs(30);
        let mut backoff = initial_backoff;
        let max_attempts = 60;

        loop {
            attempt += 1;
            match self.connect_once().await {
                Ok(conn) => {
                    if attempt > 1 {
                        info!("Publisher NATS connected on attempt {}", attempt);
                    }
                    return Ok(conn);
                }
                Err(err) => {
                    if attempt >= max_attempts {
                        error!(
                            "Publisher NATS connection attempt {} failed: {}. Giving up after {} attempts.",
                            attempt, err, max_attempts
                        );
                        return Err(err);
                    }

                    warn!(
                        "Publisher NATS connection attempt {} failed: {}. Retrying in {:?}...",
                        attempt, err, backoff
                    );
                    tokio::time::sleep(backoff).await;

                    let doubled = backoff.checked_mul(2).unwrap_or(max_backoff);
                    backoff = std::cmp::min(doubled, max_backoff);
                }
            }
        }
    }
}
