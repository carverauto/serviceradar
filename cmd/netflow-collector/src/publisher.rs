use crate::config::{Config, SecurityConfig, SecurityMode};
use anyhow::Result;
use async_nats::jetstream::{self, context::PublishAckFuture, stream::StorageType};
use async_nats::{Client, ConnectOptions};
use log::{error, info, warn};
use std::cmp::min;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
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

        info!("Publisher started, publishing to subject: {}", self.config.subject);

        loop {
            // Receive messages from the listener channel
            match self.rx.recv().await {
                Some(msg) => {
                    batch.push(msg);

                    // Publish when batch is full or channel is empty
                    if batch.len() >= self.config.batch_size {
                        self.publish_batch(&js, &mut batch, timeout_duration).await;
                    }
                }
                None => {
                    // Channel closed, publish remaining messages and exit
                    if !batch.is_empty() {
                        self.publish_batch(&js, &mut batch, timeout_duration).await;
                    }
                    info!("Publisher channel closed, shutting down");
                    return Ok(());
                }
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
                    // Wait for ack with timeout
                    if timeout(timeout_duration, ack).await.is_err() {
                        warn!("NATS ack timed out after {:?}", timeout_duration);
                        // TODO: Increment metrics counter for timeouts
                    }
                }
                Err(e) => {
                    error!("Failed to publish to NATS: {}", e);
                    // TODO: Increment metrics counter for publish failures
                }
            }
        }
    }

    async fn connect_once(&self) -> Result<(Client, jetstream::Context)> {
        let mut options = ConnectOptions::new();

        // Apply security configuration
        if let Some(sec) = &self.config.security {
            match sec.mode {
                SecurityMode::Mtls => {
                    // Apply CA file if provided
                    if let Some(ca_path) = sec.ca_file_path() {
                        options = options.add_root_certificates(ca_path);
                    }

                    // Apply client certificate and key for mTLS
                    if let (Some(cert_path), Some(key_path)) =
                        (sec.cert_file_path(), sec.key_file_path())
                    {
                        options = options.add_client_certificate(cert_path, key_path);
                    }
                }
                SecurityMode::Spiffe => {
                    // SPIFFE will be handled via spiffe.rs module
                    // For now, connect without TLS
                    warn!("SPIFFE mode not yet implemented, connecting without TLS");
                }
                SecurityMode::None => {
                    // No TLS
                }
            }
        }

        // Connect to NATS server
        let client = options.connect(&self.config.nats_url).await?;
        let js = jetstream::new(client.clone());

        // Ensure the target stream exists
        let stream_config = jetstream::stream::Config {
            name: self.config.stream_name.clone(),
            subjects: vec![self.config.subject.clone()],
            storage: StorageType::File,
            max_bytes: 10 * 1024 * 1024 * 1024, // 10 GB
            max_age: Duration::from_secs(24 * 60 * 60), // 24 hours
            ..Default::default()
        };

        js.get_or_create_stream(stream_config).await?;

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
        let max_attempts = 60; // Retry for ~30 minutes with exponential backoff

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

                    // Exponential backoff
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

    #[tokio::test]
    async fn test_publisher_creation() {
        let config = Arc::new(Config {
            listen_addr: "0.0.0.0:2055".to_string(),
            buffer_size: 65536,
            nats_url: "nats://localhost:4222".to_string(),
            stream_name: "flows".to_string(),
            subject: "flows.raw.netflow".to_string(),
            partition: "default".to_string(),
            channel_size: 1000,
            batch_size: 100,
            publish_timeout_ms: 5000,
            drop_policy: crate::config::DropPolicy::DropOldest,
            security: None,
            metrics_addr: None,
        });

        let (_tx, rx) = mpsc::channel(1000);
        let publisher = Publisher::new(config, rx);
        assert!(publisher.config.subject == "flows.raw.netflow");
    }
}
