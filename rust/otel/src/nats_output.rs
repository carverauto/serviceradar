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
use crate::opentelemetry::proto::logs::v1::{ResourceLogs, ScopeLogs};
use crate::opentelemetry::proto::metrics::v1::{ResourceMetrics, ScopeMetrics};
use crate::opentelemetry::proto::trace::v1::{ResourceSpans, ScopeSpans};

const MAX_PROTO_PUBLISH_BYTES: usize = 900 * 1024;

#[derive(Clone, Debug)]
pub struct NATSConfig {
    pub url: String,
    pub subject: String,
    pub stream: String,
    pub logs_subject: Option<String>,
    pub timeout: Duration,
    pub max_bytes: i64,
    pub max_age: Duration,
    pub stream_replicas: usize,
    pub creds_file: Option<PathBuf>,
    pub tls_cert: Option<PathBuf>,
    pub tls_key: Option<PathBuf>,
    pub tls_ca: Option<PathBuf>,
}

impl Default for NATSConfig {
    fn default() -> Self {
        Self {
            url: "nats://localhost:4222".to_string(),
            subject: "otel".to_string(),
            stream: "events".to_string(),
            logs_subject: None,
            timeout: Duration::from_secs(30),
            max_bytes: 2 * 1024 * 1024 * 1024,
            max_age: Duration::from_secs(30 * 60),
            stream_replicas: 1,
            creds_file: None,
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

fn split_logs_request(
    logs: &ExportLogsServiceRequest,
    max_publish_bytes: usize,
) -> Result<Vec<ExportLogsServiceRequest>> {
    if logs.encoded_len() <= max_publish_bytes {
        return Ok(vec![logs.clone()]);
    }

    let mut units = Vec::new();
    for resource_log in &logs.resource_logs {
        for scope_log in &resource_log.scope_logs {
            for log_record in &scope_log.log_records {
                units.push(ExportLogsServiceRequest {
                    resource_logs: vec![ResourceLogs {
                        resource: resource_log.resource.clone(),
                        scope_logs: vec![ScopeLogs {
                            scope: scope_log.scope.clone(),
                            log_records: vec![log_record.clone()],
                            schema_url: scope_log.schema_url.clone(),
                        }],
                        schema_url: resource_log.schema_url.clone(),
                    }],
                });
            }
        }
    }

    pack_log_units(units, max_publish_bytes)
}

fn pack_log_units(
    units: Vec<ExportLogsServiceRequest>,
    max_publish_bytes: usize,
) -> Result<Vec<ExportLogsServiceRequest>> {
    let mut chunks = Vec::new();
    let mut current = ExportLogsServiceRequest {
        resource_logs: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            return Err(anyhow!(
                "single OTEL log record exceeds NATS payload budget: {} > {} bytes",
                unit_size,
                max_publish_bytes
            ));
        }

        let mut candidate = current.clone();
        candidate.resource_logs.extend(unit.resource_logs.clone());

        if !current.resource_logs.is_empty() && candidate.encoded_len() > max_publish_bytes {
            chunks.push(current);
            current = unit;
        } else {
            current.resource_logs.extend(unit.resource_logs);
        }
    }

    if !current.resource_logs.is_empty() {
        chunks.push(current);
    }

    Ok(chunks)
}

fn split_traces_request(
    traces: &ExportTraceServiceRequest,
    max_publish_bytes: usize,
) -> Result<Vec<ExportTraceServiceRequest>> {
    if traces.encoded_len() <= max_publish_bytes {
        return Ok(vec![traces.clone()]);
    }

    let mut units = Vec::new();
    for resource_span in &traces.resource_spans {
        for scope_span in &resource_span.scope_spans {
            for span in &scope_span.spans {
                units.push(ExportTraceServiceRequest {
                    resource_spans: vec![ResourceSpans {
                        resource: resource_span.resource.clone(),
                        scope_spans: vec![ScopeSpans {
                            scope: scope_span.scope.clone(),
                            spans: vec![span.clone()],
                            schema_url: scope_span.schema_url.clone(),
                        }],
                        schema_url: resource_span.schema_url.clone(),
                    }],
                });
            }
        }
    }

    pack_trace_units(units, max_publish_bytes)
}

fn pack_trace_units(
    units: Vec<ExportTraceServiceRequest>,
    max_publish_bytes: usize,
) -> Result<Vec<ExportTraceServiceRequest>> {
    let mut chunks = Vec::new();
    let mut current = ExportTraceServiceRequest {
        resource_spans: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            return Err(anyhow!(
                "single OTEL span exceeds NATS payload budget: {} > {} bytes",
                unit_size,
                max_publish_bytes
            ));
        }

        let mut candidate = current.clone();
        candidate.resource_spans.extend(unit.resource_spans.clone());

        if !current.resource_spans.is_empty() && candidate.encoded_len() > max_publish_bytes {
            chunks.push(current);
            current = unit;
        } else {
            current.resource_spans.extend(unit.resource_spans);
        }
    }

    if !current.resource_spans.is_empty() {
        chunks.push(current);
    }

    Ok(chunks)
}

fn split_metrics_request(
    metrics: &ExportMetricsServiceRequest,
    max_publish_bytes: usize,
) -> Result<Vec<ExportMetricsServiceRequest>> {
    if metrics.encoded_len() <= max_publish_bytes {
        return Ok(vec![metrics.clone()]);
    }

    let mut units = Vec::new();
    for resource_metrics in &metrics.resource_metrics {
        for scope_metrics in &resource_metrics.scope_metrics {
            for metric in &scope_metrics.metrics {
                units.push(ExportMetricsServiceRequest {
                    resource_metrics: vec![ResourceMetrics {
                        resource: resource_metrics.resource.clone(),
                        scope_metrics: vec![ScopeMetrics {
                            scope: scope_metrics.scope.clone(),
                            metrics: vec![metric.clone()],
                            schema_url: scope_metrics.schema_url.clone(),
                        }],
                        schema_url: resource_metrics.schema_url.clone(),
                    }],
                });
            }
        }
    }

    pack_metric_units(units, max_publish_bytes)
}

fn pack_metric_units(
    units: Vec<ExportMetricsServiceRequest>,
    max_publish_bytes: usize,
) -> Result<Vec<ExportMetricsServiceRequest>> {
    let mut chunks = Vec::new();
    let mut current = ExportMetricsServiceRequest {
        resource_metrics: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            return Err(anyhow!(
                "single OTEL metric exceeds NATS payload budget: {} > {} bytes",
                unit_size,
                max_publish_bytes
            ));
        }

        let mut candidate = current.clone();
        candidate
            .resource_metrics
            .extend(unit.resource_metrics.clone());

        if !current.resource_metrics.is_empty() && candidate.encoded_len() > max_publish_bytes {
            chunks.push(current);
            current = unit;
        } else {
            current.resource_metrics.extend(unit.resource_metrics);
        }
    }

    if !current.resource_metrics.is_empty() {
        chunks.push(current);
    }

    Ok(chunks)
}

fn subject_matches(pattern: &str, subject: &str) -> bool {
    let pattern_tokens: Vec<&str> = pattern.split('.').collect();
    let subject_tokens: Vec<&str> = subject.split('.').collect();

    let mut subject_index = 0;
    for (idx, token) in pattern_tokens.iter().enumerate() {
        match *token {
            ">" => return idx == pattern_tokens.len() - 1,
            "*" => {
                if subject_index >= subject_tokens.len() {
                    return false;
                }
                subject_index += 1;
            }
            literal => {
                if subject_index >= subject_tokens.len() || subject_tokens[subject_index] != literal
                {
                    return false;
                }
                subject_index += 1;
            }
        }
    }

    subject_index == subject_tokens.len()
}

fn missing_subjects(existing_subjects: &[String], required_subjects: &[String]) -> Vec<String> {
    required_subjects
        .iter()
        .filter(|required| {
            !existing_subjects
                .iter()
                .any(|existing| subject_matches(existing, required))
        })
        .cloned()
        .collect()
}

fn subject_is_wildcard(subject: &str) -> bool {
    subject.split('.').any(|token| matches!(token, "*" | ">"))
}

fn reconcile_subjects(existing_subjects: &[String], required_subjects: &[String]) -> Vec<String> {
    let mut reconciled = existing_subjects.to_vec();

    for required in required_subjects {
        if subject_is_wildcard(required) {
            reconciled
                .retain(|existing| existing == required || !subject_matches(required, existing));
        }

        if !reconciled
            .iter()
            .any(|existing| subject_matches(existing, required))
        {
            reconciled.push(required.clone());
        }
    }

    reconciled
}

async fn ensure_stream(jetstream: &jetstream::Context, config: &NATSConfig) -> Result<()> {
    debug!("Creating/verifying JetStream stream: {}", config.stream);
    let logs_subject = config
        .logs_subject
        .clone()
        .unwrap_or_else(|| format!("{}.logs", config.subject));
    let subjects = vec![
        format!("{}.traces.>", config.subject),
        format!("{}.metrics.>", config.subject),
        logs_subject.clone(),
    ];
    debug!("Stream will handle subjects: {subjects:?}");

    let desired_config = jetstream::stream::Config {
        name: config.stream.clone(),
        subjects: subjects.clone(),
        storage: StorageType::File,
        max_bytes: config.max_bytes,
        max_age: config.max_age,
        num_replicas: config.stream_replicas,
        ..Default::default()
    };

    match jetstream.get_or_create_stream(desired_config.clone()).await {
        Ok(mut stream) => {
            let stream_info = stream.info().await?;
            let existing_subjects = &stream_info.config.subjects;
            let mut needs_update = false;
            let mut updated_config = stream_info.config.clone();

            let missing_subjects = missing_subjects(existing_subjects, &subjects);

            if !missing_subjects.is_empty() {
                warn!(
                    "Stream '{}' exists but is missing subjects: {:?}",
                    config.stream, missing_subjects
                );
                warn!("Current subjects: {existing_subjects:?}");

                for subject in missing_subjects {
                    updated_config.subjects.push(subject);
                    needs_update = true;
                }
            }

            let reconciled_subjects = reconcile_subjects(existing_subjects, &subjects);
            if reconciled_subjects != *existing_subjects {
                let removed_subjects: Vec<String> = existing_subjects
                    .iter()
                    .filter(|subject| !reconciled_subjects.contains(*subject))
                    .cloned()
                    .collect();
                if !removed_subjects.is_empty() {
                    warn!(
                        "Stream '{}' has legacy subjects covered by required wildcards; removing to avoid JetStream overlap: {:?}",
                        config.stream, removed_subjects
                    );
                }
                updated_config.subjects = reconciled_subjects;
                needs_update = true;
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

            if updated_config.num_replicas != config.stream_replicas {
                debug!(
                    "Updating stream '{}' replicas from {} to {}",
                    config.stream, updated_config.num_replicas, config.stream_replicas
                );
                updated_config.num_replicas = config.stream_replicas;
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
            // Stream may already exist with different subjects (e.g., created by another
            // pipeline like Flowgger). Fall back to fetching and updating it.
            warn!(
                "get_or_create_stream failed for '{}': {e}; attempting fetch-and-update",
                config.stream
            );
            match jetstream.get_stream(&config.stream).await {
                Ok(mut stream) => {
                    let stream_info = stream.info().await?;
                    let existing_subjects = &stream_info.config.subjects;
                    let mut updated_config = stream_info.config.clone();
                    let mut needs_update = false;
                    let missing_subjects = missing_subjects(&updated_config.subjects, &subjects);

                    for subject in missing_subjects {
                        updated_config.subjects.push(subject);
                        needs_update = true;
                    }

                    let reconciled_subjects = reconcile_subjects(existing_subjects, &subjects);
                    if reconciled_subjects != *existing_subjects {
                        let removed_subjects: Vec<String> = existing_subjects
                            .iter()
                            .filter(|subject| !reconciled_subjects.contains(*subject))
                            .cloned()
                            .collect();
                        if !removed_subjects.is_empty() {
                            warn!(
                                "Stream '{}' has legacy subjects covered by required wildcards; removing to avoid JetStream overlap: {:?}",
                                config.stream, removed_subjects
                            );
                        }
                        updated_config.subjects = reconciled_subjects;
                        needs_update = true;
                    }

                    if updated_config.max_bytes != config.max_bytes {
                        updated_config.max_bytes = config.max_bytes;
                        needs_update = true;
                    }
                    if updated_config.max_age != config.max_age {
                        updated_config.max_age = config.max_age;
                        needs_update = true;
                    }
                    if updated_config.num_replicas != config.stream_replicas {
                        updated_config.num_replicas = config.stream_replicas;
                        needs_update = true;
                    }

                    if needs_update {
                        info!(
                            "Updating existing stream '{}' to add subjects: {:?}",
                            config.stream, subjects
                        );
                        jetstream
                            .update_stream(updated_config)
                            .await
                            .map_err(|ue| {
                                anyhow!(
                                    "Failed to update stream '{}' after config mismatch: {ue}",
                                    config.stream
                                )
                            })?;
                        info!("Successfully updated stream '{}'", config.stream);
                    } else {
                        info!(
                            "Stream '{}' already has all required subjects",
                            config.stream
                        );
                    }
                }
                Err(fetch_err) => {
                    error!(
                        "Failed to fetch existing stream '{}': {fetch_err}",
                        config.stream
                    );
                    return Err(anyhow!(
                        "Cannot create or update stream '{}': create={e}, fetch={fetch_err}",
                        config.stream
                    ));
                }
            }
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

        if let Some(creds_file) = &config.creds_file {
            debug!("Using NATS creds file: {creds_file:?}");
            options = options.credentials_file(creds_file).await?;
        }

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

        let traces_subject = format!("{}.traces.raw", self.config.subject);
        if self.disabled {
            debug!("NATS output disabled; dropping traces");
            return Ok(());
        }

        let trace_chunks = split_traces_request(traces, MAX_PROTO_PUBLISH_BYTES)?;
        debug!(
            "Publishing {} trace chunk(s) to subject: {}",
            trace_chunks.len(),
            traces_subject
        );

        for (index, chunk) in trace_chunks.iter().enumerate() {
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            debug!(
                "Encoded trace chunk {}/{}: {} bytes",
                index + 1,
                trace_chunks.len(),
                payload.len()
            );

            let js = self.get_or_recover_jetstream().await?;
            let ack: PublishAckFuture = match js
                .publish(traces_subject.clone(), payload.into())
                .await
            {
                Ok(future) => future,
                Err(e) => {
                    error!("Failed to publish traces to NATS: {e}");
                    if Self::publish_error_indicates_missing_stream(&e) {
                        match self.recover_stream().await {
                            Ok(_) => {}
                            Err(recover_err) => {
                                error!(
                                    "Failed to recover JetStream stream '{}' after traces publish error: {recover_err}",
                                    self.config.stream
                                );
                            }
                        }
                    }
                    return Err(e.into());
                }
            };

            debug!(
                "Waiting for NATS acknowledgment for trace chunk {}/{} (timeout: {:?})",
                index + 1,
                trace_chunks.len(),
                self.config.timeout
            );
            match timeout(self.config.timeout, ack).await {
                Ok(Ok(ack_result)) => {
                    debug!(
                        "NATS trace chunk acknowledged: stream={}, sequence={}",
                        ack_result.stream, ack_result.sequence
                    );
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
        }

        info!(
            "Successfully published {} spans to NATS in {} message(s)",
            span_count,
            trace_chunks.len()
        );
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

        let logs_subject = self
            .config
            .logs_subject
            .clone()
            .unwrap_or_else(|| format!("{}.logs", self.config.subject));
        if self.disabled {
            debug!("NATS output disabled; dropping logs");
            return Ok(());
        }

        let log_chunks = split_logs_request(logs, MAX_PROTO_PUBLISH_BYTES)?;
        debug!(
            "Publishing {} log chunk(s) to subject: {}",
            log_chunks.len(),
            logs_subject
        );

        for (index, chunk) in log_chunks.iter().enumerate() {
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            debug!(
                "Encoded log chunk {}/{}: {} bytes",
                index + 1,
                log_chunks.len(),
                payload.len()
            );

            let js = self.get_or_recover_jetstream().await?;
            let ack: PublishAckFuture = match js.publish(logs_subject.clone(), payload.into()).await
            {
                Ok(future) => future,
                Err(e) => {
                    error!("Failed to publish logs to NATS: {e}");
                    if Self::publish_error_indicates_missing_stream(&e) {
                        match self.recover_stream().await {
                            Ok(_) => {}
                            Err(recover_err) => {
                                error!(
                                    "Failed to recover JetStream stream '{}' after logs publish error: {recover_err}",
                                    self.config.stream
                                );
                            }
                        }
                    }
                    return Err(e.into());
                }
            };

            debug!(
                "Waiting for NATS acknowledgment for log chunk {}/{} (timeout: {:?})",
                index + 1,
                log_chunks.len(),
                self.config.timeout
            );
            match timeout(self.config.timeout, ack).await {
                Ok(Ok(ack_result)) => {
                    debug!(
                        "NATS logs chunk acknowledged: stream={}, sequence={}",
                        ack_result.stream, ack_result.sequence
                    );
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
        }

        info!(
            "Successfully published {} log records to NATS in {} message(s)",
            logs_count,
            log_chunks.len()
        );
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

        // Publish derived metrics beneath the wildcarded OTEL metrics stream prefix.
        let otel_metrics_subject = format!("{}.metrics.derived", self.config.subject);
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
                    match self.recover_stream().await {
                        Ok(_) => {}
                        Err(recover_err) => {
                            error!(
                                "Failed to recover JetStream stream '{}' after metrics publish error: {recover_err}",
                                self.config.stream
                            );
                        }
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

        let raw_subject = format!("{}.metrics.raw", self.config.subject);

        let metric_chunks = split_metrics_request(metrics_request, MAX_PROTO_PUBLISH_BYTES)?;
        debug!(
            "Publishing {} raw metrics chunk(s) to subject: {}",
            metric_chunks.len(),
            raw_subject
        );

        for (index, chunk) in metric_chunks.iter().enumerate() {
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            debug!(
                "Encoded raw metrics chunk {}/{}: {} bytes",
                index + 1,
                metric_chunks.len(),
                payload.len()
            );

            let js = self.get_or_recover_jetstream().await?;
            let ack: PublishAckFuture = match js.publish(raw_subject.clone(), payload.into()).await
            {
                Ok(future) => future,
                Err(e) => {
                    error!("Failed to publish raw OTLP metrics to NATS: {e}");
                    if Self::publish_error_indicates_missing_stream(&e) {
                        match self.recover_stream().await {
                            Ok(_) => {}
                            Err(recover_err) => {
                                error!(
                                    "Failed to recover JetStream stream '{}' after raw metrics publish error: {recover_err}",
                                    self.config.stream
                                );
                            }
                        }
                    }
                    return Err(e.into());
                }
            };

            debug!(
                "Waiting for NATS acknowledgment for raw metrics chunk {}/{} (timeout: {:?})",
                index + 1,
                metric_chunks.len(),
                self.config.timeout
            );
            match timeout(self.config.timeout, ack).await {
                Ok(Ok(ack_result)) => {
                    debug!(
                        "NATS raw metrics chunk acknowledged: stream={}, sequence={}",
                        ack_result.stream, ack_result.sequence
                    );
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
        }

        info!(
            "Successfully published raw OTLP metrics request to NATS in {} message(s)",
            metric_chunks.len()
        );
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::opentelemetry::proto::common::v1::{AnyValue, InstrumentationScope, KeyValue};
    use crate::opentelemetry::proto::logs::v1::{LogRecord, SeverityNumber};
    use crate::opentelemetry::proto::metrics::v1::{Gauge, Metric, NumberDataPoint};
    use crate::opentelemetry::proto::resource::v1::Resource;
    use crate::opentelemetry::proto::trace::v1::{Span, Status as SpanStatus, span::SpanKind};

    fn test_resource(service_name: &str) -> Resource {
        Resource {
            attributes: vec![KeyValue {
                key: "service.name".to_string(),
                value: Some(AnyValue {
                    value: Some(
                        crate::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                            service_name.to_string(),
                        ),
                    ),
                }),
            }],
            dropped_attributes_count: 0,
            entity_refs: vec![],
        }
    }

    #[test]
    fn split_logs_request_chunks_oversized_exports() {
        let oversized_body = "x".repeat(2_000);
        let logs = ExportLogsServiceRequest {
            resource_logs: vec![ResourceLogs {
                resource: Some(test_resource("log-test")),
                scope_logs: vec![ScopeLogs {
                    scope: Some(InstrumentationScope {
                        name: "logger".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    log_records: (0..8)
                        .map(|idx| LogRecord {
                            time_unix_nano: idx,
                            observed_time_unix_nano: idx,
                            severity_number: SeverityNumber::Info as i32,
                            severity_text: "INFO".to_string(),
                            body: Some(AnyValue {
                                value: Some(crate::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    oversized_body.clone(),
                                )),
                            }),
                            attributes: vec![],
                            dropped_attributes_count: 0,
                            flags: 0,
                            trace_id: vec![],
                            span_id: vec![],
                            event_name: format!("log-{idx}"),
                        })
                        .collect(),
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let chunks = split_logs_request(&logs, 5_000).expect("split logs request");
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= 5_000));

        let total_logs = chunks
            .iter()
            .map(|chunk| {
                chunk
                    .resource_logs
                    .iter()
                    .map(|rl| {
                        rl.scope_logs
                            .iter()
                            .map(|sl| sl.log_records.len())
                            .sum::<usize>()
                    })
                    .sum::<usize>()
            })
            .sum::<usize>();
        assert_eq!(total_logs, 8);
    }

    #[test]
    fn split_traces_request_chunks_oversized_exports() {
        let oversized_name = "span".repeat(400);
        let traces = ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: Some(test_resource("trace-test")),
                scope_spans: vec![ScopeSpans {
                    scope: Some(InstrumentationScope {
                        name: "scope".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    spans: (0..12)
                        .map(|idx| Span {
                            trace_id: vec![1; 16],
                            span_id: vec![2; 8],
                            parent_span_id: vec![],
                            flags: 0,
                            name: format!("{oversized_name}-{idx}"),
                            kind: SpanKind::Internal as i32,
                            start_time_unix_nano: idx,
                            end_time_unix_nano: idx + 1,
                            attributes: vec![KeyValue {
                                key: "key".to_string(),
                                value: Some(AnyValue {
                                    value: Some(crate::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                        "value".repeat(200),
                                    )),
                                }),
                            }],
                            dropped_attributes_count: 0,
                            events: vec![],
                            dropped_events_count: 0,
                            links: vec![],
                            dropped_links_count: 0,
                            status: Some(SpanStatus {
                                message: String::new(),
                                code: 1,
                            }),
                            trace_state: String::new(),
                        })
                        .collect(),
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let chunks = split_traces_request(&traces, 6_000).expect("split traces request");
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= 6_000));

        let total_spans = chunks
            .iter()
            .map(|chunk| {
                chunk
                    .resource_spans
                    .iter()
                    .map(|rs| {
                        rs.scope_spans
                            .iter()
                            .map(|ss| ss.spans.len())
                            .sum::<usize>()
                    })
                    .sum::<usize>()
            })
            .sum::<usize>();
        assert_eq!(total_spans, 12);
    }

    #[test]
    fn subject_matching_respects_nats_wildcards() {
        assert!(subject_matches("logs.>", "logs.otel"));
        assert!(subject_matches("logs.*", "logs.otel"));
        assert!(subject_matches("otel.metrics.>", "otel.metrics.raw"));
        assert!(!subject_matches("logs.otel", "logs.>"));
        assert!(!subject_matches("logs.*", "logs.otel.raw"));
    }

    #[test]
    fn missing_subjects_skips_required_subjects_covered_by_existing_wildcards() {
        let existing_subjects = vec!["logs.>".to_string(), "otel.metrics".to_string()];
        let required_subjects = vec![
            "logs.otel".to_string(),
            "logs.audit".to_string(),
            "otel.metrics".to_string(),
            "otel.metrics.raw".to_string(),
        ];

        assert_eq!(
            missing_subjects(&existing_subjects, &required_subjects),
            vec!["otel.metrics.raw".to_string()]
        );
    }

    #[test]
    fn reconcile_subjects_replaces_legacy_specific_subjects_with_required_wildcards() {
        let existing_subjects = vec![
            "otel.traces".to_string(),
            "otel.metrics".to_string(),
            "otel.metrics.raw".to_string(),
            "logs.otel".to_string(),
        ];
        let required_subjects = vec![
            "otel.traces.>".to_string(),
            "otel.metrics.>".to_string(),
            "logs.otel".to_string(),
        ];

        assert_eq!(
            reconcile_subjects(&existing_subjects, &required_subjects),
            vec![
                "logs.otel".to_string(),
                "otel.traces.>".to_string(),
                "otel.metrics.>".to_string(),
            ]
        );
    }

    #[test]
    fn split_metrics_request_chunks_oversized_exports() {
        let metrics = ExportMetricsServiceRequest {
            resource_metrics: vec![ResourceMetrics {
                resource: Some(test_resource("metric-test")),
                scope_metrics: vec![ScopeMetrics {
                    scope: Some(InstrumentationScope {
                        name: "scope".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    metrics: (0..10)
                        .map(|idx| Metric {
                            name: format!("metric-{idx}"),
                            description: "description".repeat(100),
                            unit: "1".to_string(),
                            metadata: vec![],
                            data: Some(crate::opentelemetry::proto::metrics::v1::metric::Data::Gauge(
                                Gauge {
                                    data_points: vec![NumberDataPoint {
                                        attributes: vec![KeyValue {
                                            key: "attr".to_string(),
                                            value: Some(AnyValue {
                                                value: Some(crate::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                                    "value".repeat(200),
                                                )),
                                            }),
                                        }],
                                        start_time_unix_nano: idx,
                                        time_unix_nano: idx + 1,
                                        exemplars: vec![],
                                        flags: 0,
                                        value: Some(
                                            crate::opentelemetry::proto::metrics::v1::number_data_point::Value::AsDouble(
                                                idx as f64,
                                            ),
                                        ),
                                    }],
                                },
                            )),
                        })
                        .collect(),
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let chunks = split_metrics_request(&metrics, 8_000).expect("split metrics request");
        assert!(chunks.len() > 1);
        assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= 8_000));

        let total_metrics = chunks
            .iter()
            .map(|chunk| {
                chunk
                    .resource_metrics
                    .iter()
                    .map(|rm| {
                        rm.scope_metrics
                            .iter()
                            .map(|sm| sm.metrics.len())
                            .sum::<usize>()
                    })
                    .sum::<usize>()
            })
            .sum::<usize>();
        assert_eq!(total_metrics, 10);
    }
}
