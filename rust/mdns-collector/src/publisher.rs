use crate::config::{Config, SecurityMode};
use anyhow::{Context, Result};
use async_nats::jetstream::{self, stream::StorageType};
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
    rx: mpsc::Receiver<Vec<u8>>,
}

impl Publisher {
    pub fn new(config: Arc<Config>, rx: mpsc::Receiver<Vec<u8>>) -> Self {
        Self { config, rx }
    }

    pub async fn run(mut self) -> Result<()> {
        let (_, js) = self.connect_with_retry().await?;

        let mut batch = Vec::with_capacity(self.config.batch_size);
        let timeout_duration = Duration::from_millis(self.config.publish_timeout_ms);

        info!(
            "mDNS publisher started, publishing to subject: {}",
            self.config.subject
        );

        loop {
            let msg = match self.rx.recv().await {
                Some(msg) => msg,
                None => {
                    if !batch.is_empty() {
                        self.publish_batch(&js, &mut batch, timeout_duration).await;
                    }
                    info!("mDNS publisher channel closed, shutting down");
                    return Ok(());
                }
            };

            batch.push(msg);

            // Drain any immediately-available messages to build a batch
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
                info!("mDNS publisher channel closed, shutting down");
                return Ok(());
            }
        }
    }

    async fn publish_batch(
        &self,
        js: &jetstream::Context,
        batch: &mut Vec<Vec<u8>>,
        timeout_duration: Duration,
    ) {
        for msg in batch.drain(..) {
            match js.publish(self.config.subject.clone(), msg.into()).await {
                Ok(ack) => {
                    if timeout(timeout_duration, ack).await.is_err() {
                        warn!("NATS ack timed out after {:?}", timeout_duration);
                    }
                }
                Err(e) => {
                    error!("Failed to publish mDNS record to NATS: {}", e);
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
                .with_context(|| {
                    format!("Failed to load NATS creds file {}", creds_file)
                })?;
        }

        let client = options.connect(&self.config.nats_url).await?;
        let js = jetstream::new(client.clone());

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::DropPolicy;

    fn test_config() -> Config {
        Config {
            listen_addr: "0.0.0.0:5353".to_string(),
            buffer_size: 65536,
            multicast_groups: vec!["224.0.0.251".to_string()],
            listen_interface: None,
            nats_url: "nats://localhost:4222".to_string(),
            nats_creds_file: None,
            stream_name: "events".to_string(),
            subject: "discovery.raw.mdns".to_string(),
            stream_subjects: None,
            stream_max_bytes: 10 * 1024 * 1024 * 1024,
            partition: "default".to_string(),
            channel_size: 1000,
            batch_size: 100,
            publish_timeout_ms: 5000,
            drop_policy: DropPolicy::DropOldest,
            dedup_ttl_secs: 300,
            dedup_max_entries: 100_000,
            dedup_cleanup_interval_secs: 60,
            security: None,
            metrics_addr: None,
        }
    }

    #[tokio::test]
    async fn test_publisher_creation() {
        let config = Arc::new(test_config());
        let (_tx, rx) = mpsc::channel(1000);
        let publisher = Publisher::new(config, rx);
        assert_eq!(publisher.config.subject, "discovery.raw.mdns");
    }
}
