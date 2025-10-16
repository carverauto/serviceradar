use anyhow::{Result, anyhow};
use async_nats::jetstream::{
    context::{PublishAckFuture, PublishErrorKind},
    stream::StorageType,
};
use async_nats::{Client, ConnectOptions, jetstream};
use log::{debug, error, info, warn};
use prost::Message;
use serde::Serialize;
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::timeout;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;

#[derive(Clone, Debug)]
pub struct NATSConfig {
    pub url: String,
    pub subject: String,
    pub stream: String,
    pub timeout: Duration,
    pub max_bytes: i64,
    pub max_age: Duration,
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
            max_bytes: 2 * 1024 * 1024 * 1024,
            max_age: Duration::from_secs(30 * 60),
            tls_cert: None,
            tls_key: None,
            tls_ca: None,
        }
    }
}

pub struct NATSOutput {
    config: NATSConfig,
    jetstream: Option<jetstream::Context>,
    disabled: bool,
}

async fn ensure_stream(jetstream: &jetstream::Context, config: &NATSConfig) -> Result<()> {
    debug!("Creating/verifying JetStream stream: {}", config.stream);
    let subjects = vec![
        format!("{}.traces", config.subject),
        format!("{}.logs", config.subject),
        format!("{}.metrics", config.subject),
        format!("{}.metrics.raw", config.subject),
    ];
    debug!("Stream will handle subjects: {subjects:?}");

    let desired_config = jetstream::stream::Config {
        name: config.stream.clone(),
        subjects: subjects.clone(),
        storage: StorageType::File,
        max_bytes: config.max_bytes,
        max_age: config.max_age,
        ..Default::default()
    };

    match jetstream.get_or_create_stream(desired_config.clone()).await {
        Ok(mut stream) => {
            let stream_info = stream.info().await?;
            let existing_subjects = &stream_info.config.subjects;
            let mut needs_update = false;
            let mut updated_config = stream_info.config.clone();

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

                for subject in subjects {
                    if !updated_config.subjects.contains(&subject) {
                        updated_config.subjects.push(subject);
                        needs_update = true;
                    }
                }
            }

            if updated_config.max_bytes != config.max_bytes {
                debug!(
                    "Updating stream '{}' max_bytes from {} to {}",
                    config.stream, updated_config.max_bytes, config.max_bytes
                );
                updated_config.max_bytes = config.max_bytes;
                needs_update = true;
            }

            if updated_config.max_age != config.max_age {
                debug!(
                    "Updating stream '{}' max_age from {:?} to {:?}",
                    config.stream, updated_config.max_age, config.max_age
                );
                updated_config.max_age = config.max_age;
                needs_update = true;
            }

            if needs_update {
                debug!("Applying stream config update: {:?}", updated_config);
                match jetstream.update_stream(updated_config).await {
                    Ok(updated_info) => {
                        info!(
                            "Successfully updated stream '{}' configuration",
                            config.stream
                        );
                        debug!(
                            "Updated config: subjects={:?}, max_bytes={}, max_age={:?}",
                            updated_info.config.subjects,
                            updated_info.config.max_bytes,
                            updated_info.config.max_age
                        );
                    }
                    Err(e) => {
                        error!(
                            "Failed to update stream '{}' configuration: {e}",
                            config.stream
                        );
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
            error!("Stream config was: {desired_config:?}");
            return Err(e.into());
        }
    }

    Ok(())
}

impl NATSOutput {
    pub async fn new(config: NATSConfig) -> Result<Self> {
        info!("Initializing NATS output");
        debug!("NATS config: {config:?}");

        let (_client, jetstream) = Self::connect(&config).await?;
        ensure_stream(&jetstream, &config).await?;

        info!("NATS output initialized successfully");
        Ok(Self {
            config,
            jetstream: Some(jetstream),
            disabled: false,
        })
    }

    pub fn disabled() -> Self {
        info!("NATS output disabled (no-op)");
        Self {
            config: NATSConfig::default(),
            jetstream: None,
            disabled: true,
        }
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

    async fn recover_stream(&mut self) -> Result<()> {
        warn!(
            "Attempting to recover NATS JetStream context for stream '{}'",
            self.config.stream
        );
        match Self::connect(&self.config).await {
            Ok((_client, jetstream)) => {
                ensure_stream(&jetstream, &self.config).await?;
                self.jetstream = Some(jetstream);
                info!(
                    "Successfully recovered JetStream stream '{}'",
                    self.config.stream
                );
                Ok(())
            }
            Err(e) => {
                error!(
                    "Failed to reconnect to NATS while recovering stream '{}': {e}",
                    self.config.stream
                );
                self.jetstream = None;
                Err(e)
            }
        }
    }

    async fn get_or_recover_jetstream(&mut self) -> Result<jetstream::Context> {
        if let Some(js) = self.jetstream.clone() {
            return Ok(js);
        }

        warn!(
            "JetStream context missing before publish; attempting reconnect for stream '{}'",
            self.config.stream
        );
        self.recover_stream().await?;
        self.jetstream
            .clone()
            .ok_or_else(|| anyhow!("JetStream context unavailable after recovery"))
    }

    fn publish_error_indicates_missing_stream(err: &dyn std::fmt::Display) -> bool {
        err.to_string()
            .to_ascii_lowercase()
            .contains("no stream found")
    }

    pub async fn publish_traces(&mut self, traces: &ExportTraceServiceRequest) -> Result<()> {
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

        // Publish with acknowledgment - use traces-specific subject
        let traces_subject = format!("{}.traces", self.config.subject); // events.otel.traces
        debug!("Publishing traces to subject: {traces_subject}");
        if self.disabled {
            debug!("NATS output disabled; dropping traces");
            return Ok(());
        }
        let js = self.get_or_recover_jetstream().await?;
        let ack: PublishAckFuture = match js.publish(traces_subject, payload.into()).await {
            Ok(future) => future,
            Err(e) => {
                error!("Failed to publish traces to NATS: {e}");
                if Self::publish_error_indicates_missing_stream(&e) {
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after traces publish error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(e.into());
            }
        };

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
                if e.kind() == PublishErrorKind::StreamNotFound {
                    warn!(
                        "JetStream stream '{}' missing during traces publish acknowledgment; attempting recovery",
                        self.config.stream
                    );
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after traces ack error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(anyhow::anyhow!("NATS acknowledgment failed: {}", e));
            }
            Err(_) => {
                warn!("NATS ack timed out after {:?}", self.config.timeout);
                return Err(anyhow::anyhow!("NATS publish timeout"));
            }
        }

        Ok(())
    }

    pub async fn publish_logs(&mut self, logs: &ExportLogsServiceRequest) -> Result<()> {
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
        if self.disabled {
            debug!("NATS output disabled; dropping logs");
            return Ok(());
        }
        let js = self.get_or_recover_jetstream().await?;
        let ack: PublishAckFuture = match js.publish(logs_subject, payload.into()).await {
            Ok(future) => future,
            Err(e) => {
                error!("Failed to publish logs to NATS: {e}");
                if Self::publish_error_indicates_missing_stream(&e) {
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after logs publish error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(e.into());
            }
        };

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
                if e.kind() == PublishErrorKind::StreamNotFound {
                    warn!(
                        "JetStream stream '{}' missing during logs publish acknowledgment; attempting recovery",
                        self.config.stream
                    );
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after logs ack error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(anyhow::anyhow!("NATS logs acknowledgment failed: {}", e));
            }
            Err(_) => {
                warn!("NATS logs ack timed out after {:?}", self.config.timeout);
                return Err(anyhow::anyhow!("NATS logs publish timeout"));
            }
        }

        Ok(())
    }

    pub async fn publish_metrics(&mut self, metrics: &[PerformanceMetric]) -> Result<()> {
        if metrics.is_empty() {
            return Ok(());
        }

        debug!("Publishing {} performance metrics to NATS", metrics.len());

        // Convert metrics to JSON
        let json_payload = serde_json::to_vec(metrics)?;
        debug!("Encoded metrics data: {} bytes", json_payload.len());

        // Publish to otel metrics subject for derived analytics
        let otel_metrics_subject = format!("{}.metrics", self.config.subject);
        debug!("Publishing performance metrics to subject: {otel_metrics_subject}");

        if self.disabled {
            debug!("NATS output disabled; dropping metrics");
            return Ok(());
        }
        let js = self.get_or_recover_jetstream().await?;
        let ack: PublishAckFuture = match js
            .publish(otel_metrics_subject, json_payload.into())
            .await
        {
            Ok(future) => future,
            Err(e) => {
                error!("Failed to publish metrics to NATS: {e}");
                if Self::publish_error_indicates_missing_stream(&e) {
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after metrics publish error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(e.into());
            }
        };

        // Wait for acknowledgment with timeout
        debug!(
            "Waiting for NATS acknowledgment for metrics (timeout: {:?})",
            self.config.timeout
        );
        match timeout(self.config.timeout, ack).await {
            Ok(Ok(ack_result)) => {
                debug!(
                    "NATS metrics publish acknowledged: stream={}, sequence={}",
                    ack_result.stream, ack_result.sequence
                );
                info!(
                    "Successfully published {} performance metrics to NATS",
                    metrics.len()
                );
            }
            Ok(Err(e)) => {
                error!("NATS metrics acknowledgment failed: {e}");
                if e.kind() == PublishErrorKind::StreamNotFound {
                    warn!(
                        "JetStream stream '{}' missing during metrics publish acknowledgment; attempting recovery",
                        self.config.stream
                    );
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after metrics ack error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(anyhow::anyhow!("NATS metrics acknowledgment failed: {}", e));
            }
            Err(_) => {
                warn!("NATS metrics ack timed out after {:?}", self.config.timeout);
                return Err(anyhow::anyhow!("NATS metrics publish timeout"));
            }
        }

        Ok(())
    }

    pub async fn publish_raw_metrics(
        &mut self,
        metrics_request: &ExportMetricsServiceRequest,
    ) -> Result<()> {
        debug!("Publishing raw OTLP metrics request to NATS");

        if self.disabled {
            debug!("NATS output disabled; dropping raw metrics payload");
            return Ok(());
        }

        let mut payload = Vec::new();
        metrics_request.encode(&mut payload)?;
        debug!("Encoded raw OTLP metrics payload: {} bytes", payload.len());

        let raw_subject = format!("{}.metrics.raw", self.config.subject);
        debug!("Publishing OTLP metrics to subject: {raw_subject}");

        let js = self.get_or_recover_jetstream().await?;
        let ack: PublishAckFuture = match js.publish(raw_subject, payload.into()).await {
            Ok(future) => future,
            Err(e) => {
                error!("Failed to publish raw OTLP metrics to NATS: {e}");
                if Self::publish_error_indicates_missing_stream(&e) {
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after raw metrics publish error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(e.into());
            }
        };

        debug!(
            "Waiting for NATS acknowledgment for raw metrics (timeout: {:?})",
            self.config.timeout
        );
        match timeout(self.config.timeout, ack).await {
            Ok(Ok(ack_result)) => {
                debug!(
                    "NATS raw metrics publish acknowledged: stream={}, sequence={}",
                    ack_result.stream, ack_result.sequence
                );
                info!("Successfully published raw OTLP metrics request to NATS");
            }
            Ok(Err(e)) => {
                error!("NATS raw metrics acknowledgment failed: {e}");
                if e.kind() == PublishErrorKind::StreamNotFound {
                    warn!(
                        "JetStream stream '{}' missing during raw metrics acknowledgment; attempting recovery",
                        self.config.stream
                    );
                    if let Err(recover_err) = self.recover_stream().await {
                        error!(
                            "Failed to recover JetStream stream '{}' after raw metrics ack error: {recover_err}",
                            self.config.stream
                        );
                    }
                }
                return Err(anyhow::anyhow!(
                    "NATS raw metrics acknowledgment failed: {}",
                    e
                ));
            }
            Err(_) => {
                warn!(
                    "NATS raw metrics ack timed out after {:?}",
                    self.config.timeout
                );
                return Err(anyhow::anyhow!("NATS raw metrics publish timeout"));
            }
        }

        Ok(())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PerformanceMetric {
    pub timestamp: String, // ISO 8601 timestamp
    pub trace_id: String,
    pub span_id: String,
    pub service_name: String,
    pub span_name: String,
    pub span_kind: String,
    pub duration_ms: f64,
    pub duration_seconds: f64,
    pub metric_type: String, // "span", "http", "grpc", "slow_span"

    // Optional HTTP fields
    pub http_method: Option<String>,
    pub http_route: Option<String>,
    pub http_status_code: Option<String>,

    // Optional gRPC fields
    pub grpc_service: Option<String>,
    pub grpc_method: Option<String>,
    pub grpc_status_code: Option<String>,

    // Performance flags
    pub is_slow: bool, // true if > 100ms

    // Additional metadata
    pub component: String, // "otel-collector"
    pub level: String,     // "info", "warn" for slow spans
}
