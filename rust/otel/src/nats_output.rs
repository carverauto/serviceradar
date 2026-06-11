use anyhow::{Result, anyhow};
use async_nats::jetstream::{
    context::{PublishAckFuture, PublishErrorKind},
    stream::StorageType,
};
use async_nats::{Client, ConnectOptions, jetstream};
use log::{debug, error, info, warn};
use prost::Message;
use std::path::PathBuf;
use std::time::Duration;
use tokio::sync::{Mutex, RwLock, Semaphore};
use tokio::time::timeout;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use crate::opentelemetry::proto::logs::v1::{ResourceLogs, ScopeLogs};
use crate::opentelemetry::proto::metrics::v1::{ResourceMetrics, ScopeMetrics};
use crate::opentelemetry::proto::trace::v1::{ResourceSpans, ScopeSpans};
use crate::output::{PublishOutcome, TelemetryOutput};

// Re-exported for backwards compatibility; the type now lives with the
// output trait it belongs to.
pub use crate::output::PerformanceMetric;

const MAX_PROTO_PUBLISH_BYTES: usize = 900 * 1024;

/// Default bound on concurrently in-flight JetStream chunk publishes.
pub const DEFAULT_MAX_INFLIGHT_PUBLISHES: usize = 32;

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
    /// Maximum number of concurrently in-flight chunk publishes across all
    /// export requests. Per-request chunk ordering stays sequential; this
    /// only bounds cross-request fan-out so a publish burst cannot overwhelm
    /// JetStream.
    pub max_inflight_publishes: usize,
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
            max_inflight_publishes: DEFAULT_MAX_INFLIGHT_PUBLISHES,
        }
    }
}

/// JetStream-backed [`TelemetryOutput`] (the central-deployment backend).
///
/// Publishes hold no global lock: the `jetstream::Context` is `Clone` and
/// internally synchronized, so concurrent export requests publish
/// independently. Mutable state is confined to two narrow synchronization
/// points, neither held across a publish/ack await:
///
/// - `state` (`RwLock`): locked only long enough to clone out or swap the
///   current JetStream context.
/// - `recovery` (`Mutex`): serializes reconnect + ensure_stream so a publish
///   error storm triggers one reconnection instead of N.
pub struct NATSOutput {
    config: NATSConfig,
    state: RwLock<ConnectionState>,
    /// Serializes reconnect/stream-ensure only; never held during publishes.
    recovery: Mutex<()>,
    /// Bounds concurrently in-flight chunk publishes
    /// ([`NATSConfig::max_inflight_publishes`]).
    publish_permits: Semaphore,
    disabled: bool,
}

#[derive(Default)]
struct ConnectionState {
    jetstream: Option<jetstream::Context>,
    /// Bumped after every recovery attempt (success or failure) so
    /// concurrent publishers can tell whether another task already
    /// reconnected while they waited.
    generation: u64,
}

/// Splits an OTLP export into publishable chunks. The second tuple element is
/// the number of individual records dropped because a single record's encoded
/// size exceeds `max_publish_bytes`; such records can never be published, so
/// they are rejected (and reported via partial_success) instead of poisoning
/// the whole batch into an infinite client retry loop.
fn split_logs_request(
    logs: &ExportLogsServiceRequest,
    max_publish_bytes: usize,
) -> (Vec<ExportLogsServiceRequest>, usize) {
    if logs.encoded_len() <= max_publish_bytes {
        return (vec![logs.clone()], 0);
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
) -> (Vec<ExportLogsServiceRequest>, usize) {
    let mut chunks = Vec::new();
    let mut rejected = 0usize;
    let mut current = ExportLogsServiceRequest {
        resource_logs: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            rejected += 1;
            warn!(
                "Dropping oversized OTEL log record: {unit_size} encoded bytes exceeds the {max_publish_bytes} byte publish budget"
            );
            continue;
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

    (chunks, rejected)
}

fn split_traces_request(
    traces: &ExportTraceServiceRequest,
    max_publish_bytes: usize,
) -> (Vec<ExportTraceServiceRequest>, usize) {
    if traces.encoded_len() <= max_publish_bytes {
        return (vec![traces.clone()], 0);
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
) -> (Vec<ExportTraceServiceRequest>, usize) {
    let mut chunks = Vec::new();
    let mut rejected = 0usize;
    let mut current = ExportTraceServiceRequest {
        resource_spans: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            rejected += 1;
            warn!(
                "Dropping oversized OTEL span: {unit_size} encoded bytes exceeds the {max_publish_bytes} byte publish budget"
            );
            continue;
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

    (chunks, rejected)
}

fn split_metrics_request(
    metrics: &ExportMetricsServiceRequest,
    max_publish_bytes: usize,
) -> (Vec<ExportMetricsServiceRequest>, usize) {
    if metrics.encoded_len() <= max_publish_bytes {
        return (vec![metrics.clone()], 0);
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
) -> (Vec<ExportMetricsServiceRequest>, usize) {
    let mut chunks = Vec::new();
    let mut rejected = 0usize;
    let mut current = ExportMetricsServiceRequest {
        resource_metrics: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            // OTLP metrics partial_success counts rejected data points, not
            // rejected Metric containers.
            rejected += metric_request_data_points(&unit);
            warn!(
                "Dropping oversized OTEL metric: {unit_size} encoded bytes exceeds the {max_publish_bytes} byte publish budget"
            );
            continue;
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

    (chunks, rejected)
}

/// Counts the metric data points contained in an export request.
fn metric_request_data_points(request: &ExportMetricsServiceRequest) -> usize {
    use crate::opentelemetry::proto::metrics::v1::metric::Data;

    request
        .resource_metrics
        .iter()
        .flat_map(|rm| rm.scope_metrics.iter())
        .flat_map(|sm| sm.metrics.iter())
        .map(|metric| match metric.data {
            Some(Data::Gauge(ref gauge)) => gauge.data_points.len(),
            Some(Data::Sum(ref sum)) => sum.data_points.len(),
            Some(Data::Histogram(ref histogram)) => histogram.data_points.len(),
            Some(Data::ExponentialHistogram(ref histogram)) => histogram.data_points.len(),
            Some(Data::Summary(ref summary)) => summary.data_points.len(),
            None => 0,
        })
        .sum()
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
        Ok(Self::from_parts(config, Some(jetstream), false))
    }

    pub fn disabled() -> Self {
        info!("NATS output disabled (no-op)");
        Self::from_parts(NATSConfig::default(), None, true)
    }

    fn from_parts(
        config: NATSConfig,
        jetstream: Option<jetstream::Context>,
        disabled: bool,
    ) -> Self {
        let permits = config.max_inflight_publishes.max(1);
        Self {
            state: RwLock::new(ConnectionState {
                jetstream,
                generation: 0,
            }),
            recovery: Mutex::new(()),
            publish_permits: Semaphore::new(permits),
            config,
            disabled,
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

    /// Returns the current JetStream context (cloned; `jetstream::Context`
    /// is internally synchronized), reconnecting first if absent. No lock is
    /// held when this returns.
    async fn current_jetstream(&self) -> Result<(jetstream::Context, u64)> {
        let observed_generation = {
            let state = self.state.read().await;
            if let Some(js) = &state.jetstream {
                return Ok((js.clone(), state.generation));
            }
            state.generation
        };

        warn!(
            "JetStream context missing before publish; attempting reconnect for stream '{}'",
            self.config.stream
        );
        self.recover(observed_generation).await
    }

    /// Reconnects and re-ensures the stream behind the narrow `recovery`
    /// lock. Publishers that lost the recovery race reuse the fresh context
    /// instead of reconnecting again; if the racing recovery failed, this
    /// attempt proceeds with its own reconnect.
    async fn recover(&self, observed_generation: u64) -> Result<(jetstream::Context, u64)> {
        let _guard = self.recovery.lock().await;

        {
            let state = self.state.read().await;
            // If a concurrent recovery succeeded while we waited for the
            // lock, reuse its context. If it ran and failed (generation
            // bumped, context still absent), fall through and try again
            // ourselves.
            if state.generation != observed_generation
                && let Some(js) = &state.jetstream
            {
                return Ok((js.clone(), state.generation));
            }
        }

        warn!(
            "Attempting to recover NATS JetStream context for stream '{}'",
            self.config.stream
        );
        match Self::connect(&self.config).await {
            Ok((_client, jetstream)) => {
                ensure_stream(&jetstream, &self.config).await?;
                let mut state = self.state.write().await;
                state.jetstream = Some(jetstream.clone());
                state.generation += 1;
                let generation = state.generation;
                drop(state);
                info!(
                    "Successfully recovered JetStream stream '{}'",
                    self.config.stream
                );
                Ok((jetstream, generation))
            }
            Err(e) => {
                error!(
                    "Failed to reconnect to NATS while recovering stream '{}': {e}",
                    self.config.stream
                );
                let mut state = self.state.write().await;
                state.jetstream = None;
                state.generation += 1;
                Err(e)
            }
        }
    }

    /// Best-effort recovery after a publish/ack error that indicates the
    /// stream is missing. Failures are logged, never propagated — the
    /// original publish error is what the caller reports.
    async fn try_recover_after_error(&self, observed_generation: u64, what: &str) {
        warn!(
            "JetStream stream '{}' missing during {what}; attempting recovery",
            self.config.stream
        );
        if let Err(recover_err) = self.recover(observed_generation).await {
            error!(
                "Failed to recover JetStream stream '{}' after {what} error: {recover_err}",
                self.config.stream
            );
        }
    }

    fn publish_error_indicates_missing_stream(err: &dyn std::fmt::Display) -> bool {
        err.to_string()
            .to_ascii_lowercase()
            .contains("no stream found")
    }

    /// Publishes one encoded chunk and waits for the JetStream ack.
    ///
    /// Holds no lock across the publish/ack awaits; a semaphore permit
    /// bounds the number of concurrently in-flight chunk publishes across
    /// all export requests.
    async fn publish_chunk(&self, subject: &str, payload: Vec<u8>, signal: &str) -> Result<()> {
        let _permit = self
            .publish_permits
            .acquire()
            .await
            .map_err(|_| anyhow!("NATS publish semaphore closed"))?;

        let (js, generation) = self.current_jetstream().await?;

        let ack: PublishAckFuture = match js.publish(subject.to_string(), payload.into()).await {
            Ok(future) => future,
            Err(e) => {
                error!("Failed to publish {signal} to NATS: {e}");
                if Self::publish_error_indicates_missing_stream(&e) {
                    self.try_recover_after_error(generation, &format!("{signal} publish"))
                        .await;
                }
                return Err(e.into());
            }
        };

        debug!(
            "Waiting for NATS acknowledgment for {signal} (timeout: {:?})",
            self.config.timeout
        );
        match timeout(self.config.timeout, ack).await {
            Ok(Ok(ack_result)) => {
                debug!(
                    "NATS {signal} publish acknowledged: stream={}, sequence={}",
                    ack_result.stream, ack_result.sequence
                );
                Ok(())
            }
            Ok(Err(e)) => {
                error!("NATS {signal} acknowledgment failed: {e}");
                if e.kind() == PublishErrorKind::StreamNotFound {
                    self.try_recover_after_error(generation, &format!("{signal} acknowledgment"))
                        .await;
                }
                Err(anyhow!("NATS {signal} acknowledgment failed: {e}"))
            }
            Err(_) => {
                warn!(
                    "NATS {signal} ack timed out after {:?}",
                    self.config.timeout
                );
                Err(anyhow!("NATS {signal} publish timeout"))
            }
        }
    }

}

#[tonic::async_trait]
impl TelemetryOutput for NATSOutput {
    /// Publishes traces to NATS. `rejected` counts individual spans dropped
    /// because a single span's encoded size exceeds the publish budget;
    /// callers report these via OTLP partial_success.
    async fn publish_traces(&self, traces: &ExportTraceServiceRequest) -> Result<PublishOutcome> {
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
            return Ok(PublishOutcome {
                published: span_count,
                rejected: 0,
            });
        }

        let (trace_chunks, rejected) = split_traces_request(traces, MAX_PROTO_PUBLISH_BYTES);
        if rejected > 0 {
            crate::metrics::record_rejected("traces", "oversize", rejected);
        }
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
            self.publish_chunk(&traces_subject, payload, "traces")
                .await?;
        }

        info!(
            "Successfully published {} spans to NATS in {} message(s)",
            span_count.saturating_sub(rejected),
            trace_chunks.len()
        );
        Ok(PublishOutcome {
            published: span_count.saturating_sub(rejected),
            rejected,
        })
    }

    /// Publishes logs to NATS. `rejected` counts individual log records
    /// dropped because a single record's encoded size exceeds the publish
    /// budget; callers report these via OTLP partial_success.
    async fn publish_logs(&self, logs: &ExportLogsServiceRequest) -> Result<PublishOutcome> {
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
            return Ok(PublishOutcome {
                published: logs_count,
                rejected: 0,
            });
        }

        let (log_chunks, rejected) = split_logs_request(logs, MAX_PROTO_PUBLISH_BYTES);
        if rejected > 0 {
            crate::metrics::record_rejected("logs", "oversize", rejected);
        }
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
            self.publish_chunk(&logs_subject, payload, "logs").await?;
        }

        info!(
            "Successfully published {} log records to NATS in {} message(s)",
            logs_count.saturating_sub(rejected),
            log_chunks.len()
        );
        Ok(PublishOutcome {
            published: logs_count.saturating_sub(rejected),
            rejected,
        })
    }

    async fn publish_derived_metrics(
        &self,
        metrics: &[PerformanceMetric],
    ) -> Result<PublishOutcome> {
        if metrics.is_empty() {
            return Ok(PublishOutcome::default());
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
            return Ok(PublishOutcome {
                published: metrics.len(),
                rejected: 0,
            });
        }

        self.publish_chunk(&otel_metrics_subject, json_payload, "derived metrics")
            .await?;

        info!(
            "Successfully published {} performance metrics to NATS",
            metrics.len()
        );
        Ok(PublishOutcome {
            published: metrics.len(),
            rejected: 0,
        })
    }

    /// Publishes raw OTLP metrics to NATS. `rejected` counts individual
    /// metric data points dropped because a single metric's encoded size
    /// exceeds the publish budget; callers report these via partial_success.
    async fn publish_raw_metrics(
        &self,
        metrics_request: &ExportMetricsServiceRequest,
    ) -> Result<PublishOutcome> {
        debug!("Publishing raw OTLP metrics request to NATS");

        let data_point_count = metric_request_data_points(metrics_request);

        if self.disabled {
            debug!("NATS output disabled; dropping raw metrics payload");
            return Ok(PublishOutcome {
                published: data_point_count,
                rejected: 0,
            });
        }

        let raw_subject = format!("{}.metrics.raw", self.config.subject);

        let (metric_chunks, rejected) =
            split_metrics_request(metrics_request, MAX_PROTO_PUBLISH_BYTES);
        if rejected > 0 {
            crate::metrics::record_rejected("metrics", "oversize", rejected);
        }
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
            self.publish_chunk(&raw_subject, payload, "raw metrics")
                .await?;
        }

        info!(
            "Successfully published raw OTLP metrics request to NATS in {} message(s)",
            metric_chunks.len()
        );
        Ok(PublishOutcome {
            published: data_point_count.saturating_sub(rejected),
            rejected,
        })
    }
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

        let (chunks, rejected) = split_logs_request(&logs, 5_000);
        assert_eq!(rejected, 0);
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

        let (chunks, rejected) = split_traces_request(&traces, 6_000);
        assert_eq!(rejected, 0);
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

        let (chunks, rejected) = split_metrics_request(&metrics, 8_000);
        assert_eq!(rejected, 0);
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

    fn small_span(idx: u64, name: &str) -> Span {
        Span {
            trace_id: vec![1; 16],
            span_id: vec![2; 8],
            parent_span_id: vec![],
            flags: 0,
            name: name.to_string(),
            kind: SpanKind::Internal as i32,
            start_time_unix_nano: idx,
            end_time_unix_nano: idx + 1,
            attributes: vec![],
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
        }
    }

    #[test]
    fn pack_trace_units_drops_oversized_single_span_and_keeps_rest() {
        let budget = 2_000usize;
        // One span whose encoded size alone exceeds the budget, plus small spans.
        let oversized = small_span(0, &"x".repeat(4_000));
        let traces = ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: Some(test_resource("trace-oversize")),
                scope_spans: vec![ScopeSpans {
                    scope: Some(InstrumentationScope {
                        name: "scope".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    spans: vec![
                        oversized,
                        small_span(1, "small-1"),
                        small_span(2, "small-2"),
                        small_span(3, "small-3"),
                    ],
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let (chunks, rejected) = split_traces_request(&traces, budget);
        assert_eq!(rejected, 1, "exactly the oversized span is rejected");
        assert!(!chunks.is_empty(), "remaining spans must still be packed");
        assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= budget));

        let surviving_spans: usize = chunks
            .iter()
            .flat_map(|chunk| chunk.resource_spans.iter())
            .flat_map(|rs| rs.scope_spans.iter())
            .map(|ss| ss.spans.len())
            .sum();
        assert_eq!(surviving_spans, 3);
    }

    #[test]
    fn pack_trace_units_all_oversized_yields_no_chunks() {
        let budget = 1_000usize;
        let traces = ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: Some(test_resource("trace-oversize-all")),
                scope_spans: vec![ScopeSpans {
                    scope: None,
                    spans: vec![
                        small_span(0, &"y".repeat(3_000)),
                        small_span(1, &"z".repeat(3_000)),
                    ],
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let (chunks, rejected) = split_traces_request(&traces, budget);
        assert_eq!(rejected, 2);
        assert!(chunks.is_empty());
    }

    #[test]
    fn pack_log_units_drops_oversized_single_record_and_keeps_rest() {
        let budget = 2_000usize;
        let make_record = |idx: u64, body: String| LogRecord {
            time_unix_nano: idx,
            observed_time_unix_nano: idx,
            severity_number: SeverityNumber::Info as i32,
            severity_text: "INFO".to_string(),
            body: Some(AnyValue {
                value: Some(
                    crate::opentelemetry::proto::common::v1::any_value::Value::StringValue(body),
                ),
            }),
            attributes: vec![],
            dropped_attributes_count: 0,
            flags: 0,
            trace_id: vec![],
            span_id: vec![],
            event_name: format!("log-{idx}"),
        };

        let logs = ExportLogsServiceRequest {
            resource_logs: vec![ResourceLogs {
                resource: Some(test_resource("log-oversize")),
                scope_logs: vec![ScopeLogs {
                    scope: None,
                    log_records: vec![
                        make_record(0, "x".repeat(5_000)),
                        make_record(1, "small".to_string()),
                        make_record(2, "small".to_string()),
                    ],
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let (chunks, rejected) = split_logs_request(&logs, budget);
        assert_eq!(rejected, 1);
        assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= budget));

        let surviving_records: usize = chunks
            .iter()
            .flat_map(|chunk| chunk.resource_logs.iter())
            .flat_map(|rl| rl.scope_logs.iter())
            .map(|sl| sl.log_records.len())
            .sum();
        assert_eq!(surviving_records, 2);
    }

    #[test]
    fn pack_metric_units_counts_rejected_data_points() {
        let budget = 2_000usize;
        let make_metric = |idx: u64, description: String, data_points: usize| {
            Metric {
            name: format!("metric-{idx}"),
            description,
            unit: "1".to_string(),
            metadata: vec![],
            data: Some(
                crate::opentelemetry::proto::metrics::v1::metric::Data::Gauge(Gauge {
                    data_points: (0..data_points)
                        .map(|dp| NumberDataPoint {
                            attributes: vec![],
                            start_time_unix_nano: idx,
                            time_unix_nano: idx + dp as u64,
                            exemplars: vec![],
                            flags: 0,
                            value: Some(
                                crate::opentelemetry::proto::metrics::v1::number_data_point::Value::AsDouble(
                                    dp as f64,
                                ),
                            ),
                        })
                        .collect(),
                }),
            ),
        }
        };

        let metrics = ExportMetricsServiceRequest {
            resource_metrics: vec![ResourceMetrics {
                resource: Some(test_resource("metric-oversize")),
                scope_metrics: vec![ScopeMetrics {
                    scope: None,
                    metrics: vec![
                        // Oversized metric carrying 3 data points.
                        make_metric(0, "d".repeat(5_000), 3),
                        make_metric(1, "small".to_string(), 1),
                        make_metric(2, "small".to_string(), 1),
                    ],
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        };

        let (chunks, rejected) = split_metrics_request(&metrics, budget);
        assert_eq!(rejected, 3, "all data points of the oversized metric count");
        assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= budget));

        let surviving_metrics: usize = chunks
            .iter()
            .flat_map(|chunk| chunk.resource_metrics.iter())
            .flat_map(|rm| rm.scope_metrics.iter())
            .map(|sm| sm.metrics.len())
            .sum();
        assert_eq!(surviving_metrics, 2);
    }
}
