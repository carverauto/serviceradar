use anyhow::Result;
use async_nats::jetstream::{context::PublishAckFuture, stream::StorageType};
use async_nats::{Client, ConnectOptions, jetstream};
use log::{debug, error, info, warn};
use prost::Message;
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::timeout;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;

#[derive(Clone, Debug)]
pub struct NATSConfig {
    pub url: String,
    pub subject: String,
    pub stream: String,
    pub timeout: Duration,
    pub tls_cert: Option<PathBuf>,
    pub tls_key: Option<PathBuf>,
    pub tls_ca: Option<PathBuf>,
}

impl Default for NATSConfig {
    fn default() -> Self {
        Self {
            url: "nats://localhost:4222".to_string(),
            subject: "events.otel".to_string(),
            stream: "events".to_string(),
            timeout: Duration::from_secs(30),
            tls_cert: None,
            tls_key: None,
            tls_ca: None,
        }
    }
}

pub struct NATSOutput {
    config: NATSConfig,
    jetstream: jetstream::Context,
}

impl NATSOutput {
    pub async fn new(config: NATSConfig) -> Result<Self> {
        info!("Initializing NATS output");
        debug!("NATS config: {config:?}");

        let (_client, jetstream) = Self::connect(&config).await?;

        // Ensure the target stream exists
        debug!("Creating/verifying JetStream stream: {}", config.stream);
        // Configure stream to handle both traces and logs subjects
        let subjects = vec![config.subject.clone(), format!("{}.logs", config.subject)];
        debug!("Stream will handle subjects: {subjects:?}");

        let stream_config = jetstream::stream::Config {
            name: config.stream.clone(),
            subjects: subjects.clone(),
            storage: StorageType::File,
            ..Default::default()
        };

        // Try to get or create the stream
        match jetstream.get_or_create_stream(stream_config.clone()).await {
            Ok(mut stream) => {
                let stream_info = stream.info().await?;
                let existing_subjects = &stream_info.config.subjects;

                // Check if all required subjects are present
                let missing_subjects: Vec<_> = subjects
                    .iter()
                    .filter(|s| !existing_subjects.contains(s))
                    .collect();

                if !missing_subjects.is_empty() {
                    warn!(
                        "Stream '{}' exists but is missing subjects: {:?}",
                        config.stream, missing_subjects
                    );
                    warn!("Current subjects: {existing_subjects:?}");

                    // Update the stream to include missing subjects
                    let mut updated_config = stream_info.config.clone();
                    for subject in subjects {
                        if !updated_config.subjects.contains(&subject) {
                            updated_config.subjects.push(subject);
                        }
                    }

                    debug!(
                        "Updating stream with new subjects: {:?}",
                        updated_config.subjects
                    );
                    match jetstream.update_stream(updated_config).await {
                        Ok(updated_info) => {
                            info!(
                                "Successfully updated stream '{}' with subjects: {:?}",
                                config.stream, updated_info.config.subjects
                            );
                        }
                        Err(e) => {
                            error!(
                                "Failed to update stream '{}' with new subjects: {e}",
                                config.stream
                            );
                            warn!("Stream exists but may not handle all message types correctly");
                        }
                    }
                } else {
                    info!(
                        "JetStream stream '{}' ready with subjects: {:?}",
                        config.stream, existing_subjects
                    );
                }
            }
            Err(e) => {
                error!(
                    "Failed to create/verify JetStream stream '{}': {e}",
                    config.stream
                );
                error!("Stream config was: {stream_config:?}");
                return Err(e.into());
            }
        }

        info!("NATS output initialized successfully");
        Ok(Self { config, jetstream })
    }

    async fn connect(config: &NATSConfig) -> Result<(Client, jetstream::Context)> {
        debug!("Connecting to NATS server: {}", config.url);
        let mut options = ConnectOptions::new();

        // Apply CA file if provided
        if let Some(ca_file) = &config.tls_ca {
            debug!("Using TLS CA file: {ca_file:?}");
            options = options.add_root_certificates(ca_file.clone());
        }

        // Apply client certificate and key for mTLS
        if let (Some(cert_file), Some(key_file)) = (&config.tls_cert, &config.tls_key) {
            debug!("Using TLS client certificate: {cert_file:?}, key: {key_file:?}");
            options = options.add_client_certificate(cert_file.clone(), key_file.clone());
        }

        let client = match options.connect(&config.url).await {
            Ok(c) => {
                info!("Connected to NATS server successfully");
                c
            }
            Err(e) => {
                error!("Failed to connect to NATS server: {e}");
                return Err(e.into());
            }
        };

        debug!("Creating JetStream context");
        let jetstream = jetstream::new(client.clone());

        Ok((client, jetstream))
    }

    pub async fn publish_traces(&self, traces: &ExportTraceServiceRequest) -> Result<()> {
        let span_count = traces
            .resource_spans
            .iter()
            .map(|rs| {
                rs.scope_spans
                    .iter()
                    .map(|ss| ss.spans.len())
                    .sum::<usize>()
            })
            .sum::<usize>();

        debug!(
            "Publishing {} resource spans with {} total spans to NATS",
            traces.resource_spans.len(),
            span_count
        );

        // Encode traces as protobuf
        let mut payload = Vec::new();
        traces.encode(&mut payload)?;

        debug!("Encoded trace data: {} bytes", payload.len());

        // Publish with acknowledgment
        debug!("Publishing to subject: {}", self.config.subject);
        let ack: PublishAckFuture = self
            .jetstream
            .publish(self.config.subject.clone(), payload.into())
            .await
            .map_err(|e| {
                error!("Failed to publish to NATS: {e}");
                e
            })?;

        // Wait for acknowledgment with timeout
        debug!(
            "Waiting for NATS acknowledgment (timeout: {:?})",
            self.config.timeout
        );
        match timeout(self.config.timeout, ack).await {
            Ok(Ok(ack_result)) => {
                debug!(
                    "NATS publish acknowledged: stream={}, sequence={}",
                    ack_result.stream, ack_result.sequence
                );
                info!("Successfully published {span_count} spans to NATS");
            }
            Ok(Err(e)) => {
                error!("NATS acknowledgment failed: {e}");
                return Err(anyhow::anyhow!("NATS acknowledgment failed: {}", e));
            }
            Err(_) => {
                warn!("NATS ack timed out after {:?}", self.config.timeout);
                return Err(anyhow::anyhow!("NATS publish timeout"));
            }
        }

        Ok(())
    }

    pub async fn publish_logs(&self, logs: &ExportLogsServiceRequest) -> Result<()> {
        let logs_count = logs
            .resource_logs
            .iter()
            .map(|rl| {
                rl.scope_logs
                    .iter()
                    .map(|sl| sl.log_records.len())
                    .sum::<usize>()
            })
            .sum::<usize>();

        debug!(
            "Publishing {} resource logs with {} total log records to NATS",
            logs.resource_logs.len(),
            logs_count
        );

        // Encode logs as protobuf
        let mut payload = Vec::new();
        logs.encode(&mut payload)?;

        debug!("Encoded logs data: {} bytes", payload.len());

        // Publish with acknowledgment - use a different subject for logs
        let logs_subject = format!("{}.logs", self.config.subject);
        debug!("Publishing to subject: {logs_subject}");
        let ack: PublishAckFuture = self
            .jetstream
            .publish(logs_subject, payload.into())
            .await
            .map_err(|e| {
                error!("Failed to publish logs to NATS: {e}");
                e
            })?;

        // Wait for acknowledgment with timeout
        debug!(
            "Waiting for NATS acknowledgment for logs (timeout: {:?})",
            self.config.timeout
        );
        match timeout(self.config.timeout, ack).await {
            Ok(Ok(ack_result)) => {
                debug!(
                    "NATS logs publish acknowledged: stream={}, sequence={}",
                    ack_result.stream, ack_result.sequence
                );
                info!("Successfully published {logs_count} log records to NATS");
            }
            Ok(Err(e)) => {
                error!("NATS logs acknowledgment failed: {e}");
                return Err(anyhow::anyhow!("NATS logs acknowledgment failed: {}", e));
            }
            Err(_) => {
                warn!("NATS logs ack timed out after {:?}", self.config.timeout);
                return Err(anyhow::anyhow!("NATS logs publish timeout"));
            }
        }

        Ok(())
    }
}
