//! Chunk publishing: semaphore-bounded in-flight publishes, JetStream ack
//! handling, and the per-signal [`TelemetryOutput`] implementation.

use anyhow::{Result, anyhow};
use async_nats::jetstream::context::{PublishAckFuture, PublishErrorKind};
use log::{debug, error, info, warn};
use prost::Message;
use tokio::time::timeout;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use crate::opentelemetry::proto::common::v1::any_value;
use crate::output::{
    DEVICE_ID_ATTRIBUTE, INGEST_IDENTITY_HEADER, IngestContext, PerformanceMetric, PublishOutcome,
    SR_DEVICE_ID_HEADER, TelemetryOutput, encode_derived_metric_batch,
};

use super::NATSOutput;
use super::chunker::{
    MAX_PROTO_PUBLISH_BYTES, metric_request_data_points, split_logs_request, split_metrics_request,
    split_traces_request,
};

/// Builds the NATS headers for a published chunk. Returns `None` when both
/// inputs are absent so callers never publish a needless empty-header message.
/// Downstream consumers (zen, db-event-writer) ignore headers they do not know.
fn build_headers(identity: Option<&str>, device_ids: &[String]) -> Option<async_nats::HeaderMap> {
    if identity.is_none() && device_ids.is_empty() {
        return None;
    }
    let mut headers = async_nats::HeaderMap::new();
    if let Some(id) = identity {
        headers.insert(INGEST_IDENTITY_HEADER, id);
    }
    for device_id in device_ids {
        headers.append(SR_DEVICE_ID_HEADER, device_id.as_str());
    }
    Some(headers)
}

/// Extracts the unique `serviceradar.device_id` string values from every log
/// record attribute in `chunk`. Deduplicates in insertion order; skips blank
/// values. Returns an empty `Vec` when no records carry the attribute.
fn log_chunk_device_ids(chunk: &ExportLogsServiceRequest) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    for rl in &chunk.resource_logs {
        for sl in &rl.scope_logs {
            for record in &sl.log_records {
                for attr in &record.attributes {
                    if attr.key != DEVICE_ID_ATTRIBUTE {
                        continue;
                    }
                    if let Some(av) = &attr.value
                        && let Some(any_value::Value::StringValue(id)) = &av.value
                        && !id.is_empty()
                        && !ids.contains(id)
                    {
                        ids.push(id.clone());
                    }
                }
            }
        }
    }
    ids
}

impl NATSOutput {
    /// Publishes one encoded chunk and waits for the JetStream ack.
    ///
    /// Holds no lock across the publish/ack awaits; a semaphore permit
    /// bounds the number of concurrently in-flight chunk publishes across
    /// all export requests.
    ///
    /// When `headers` is set the chunk is published with those headers so
    /// downstream consumers can attribute the data without inspecting the
    /// payload. See [`build_headers`] for the canonical header builder.
    async fn publish_chunk(
        &self,
        subject: &str,
        payload: Vec<u8>,
        signal: &str,
        headers: Option<async_nats::HeaderMap>,
    ) -> Result<()> {
        let _permit = self
            .publish_permits
            .acquire()
            .await
            .map_err(|_| anyhow!("NATS publish semaphore closed"))?;

        let (js, generation) = self.current_jetstream().await?;

        let publish_result = match headers {
            Some(h) => {
                js.publish_with_headers(subject.to_string(), h, payload.into())
                    .await
            }
            None => js.publish(subject.to_string(), payload.into()).await,
        };

        let ack: PublishAckFuture = match publish_result {
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
    async fn publish_traces(
        &self,
        traces: &ExportTraceServiceRequest,
        ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
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
            self.publish_chunk(
                &traces_subject,
                payload,
                "traces",
                build_headers(ctx.identity.as_deref(), &[]),
            )
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
    async fn publish_logs(
        &self,
        logs: &ExportLogsServiceRequest,
        ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
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
            let device_ids = log_chunk_device_ids(chunk);
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            debug!(
                "Encoded log chunk {}/{}: {} bytes, {} device(s)",
                index + 1,
                log_chunks.len(),
                payload.len(),
                device_ids.len(),
            );
            self.publish_chunk(
                &logs_subject,
                payload,
                "logs",
                build_headers(ctx.identity.as_deref(), &device_ids),
            )
            .await?;
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
        ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
        if metrics.is_empty() {
            return Ok(PublishOutcome::default());
        }

        debug!("Publishing {} performance metrics to NATS", metrics.len());

        let payload = encode_derived_metric_batch(metrics);
        debug!(
            "Encoded derived metrics protobuf data: {} bytes",
            payload.len()
        );

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

        self.publish_chunk(
            &otel_metrics_subject,
            payload,
            "derived metrics",
            build_headers(ctx.identity.as_deref(), &[]),
        )
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
        ctx: &IngestContext,
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
            self.publish_chunk(
                &raw_subject,
                payload,
                "raw metrics",
                build_headers(ctx.identity.as_deref(), &[]),
            )
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
    use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
    use crate::opentelemetry::proto::common::v1::{AnyValue, KeyValue, any_value};
    use crate::opentelemetry::proto::logs::v1::{LogRecord, ResourceLogs, ScopeLogs};

    use super::*;

    fn make_log_request_with_device(device_id: &str) -> ExportLogsServiceRequest {
        ExportLogsServiceRequest {
            resource_logs: vec![ResourceLogs {
                scope_logs: vec![ScopeLogs {
                    log_records: vec![LogRecord {
                        attributes: vec![KeyValue {
                            key: DEVICE_ID_ATTRIBUTE.to_owned(),
                            value: Some(AnyValue {
                                value: Some(any_value::Value::StringValue(device_id.to_owned())),
                            }),
                        }],
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            }],
        }
    }

    #[test]
    fn build_headers_stamps_ingest_identity() {
        let headers = build_headers(Some("tenant-a"), &[]).unwrap();
        assert_eq!(
            headers.get(INGEST_IDENTITY_HEADER).map(|v| v.as_str()),
            Some("tenant-a")
        );
    }

    #[test]
    fn build_headers_stamps_device_id() {
        let ids = vec!["dev-abc".to_owned()];
        let headers = build_headers(None, &ids).unwrap();
        assert_eq!(
            headers.get(SR_DEVICE_ID_HEADER).map(|v| v.as_str()),
            Some("dev-abc")
        );
    }

    #[test]
    fn build_headers_stamps_both_when_present() {
        let ids = vec!["dev-xyz".to_owned()];
        let headers = build_headers(Some("tenant-b"), &ids).unwrap();
        assert_eq!(
            headers.get(INGEST_IDENTITY_HEADER).map(|v| v.as_str()),
            Some("tenant-b")
        );
        assert_eq!(
            headers.get(SR_DEVICE_ID_HEADER).map(|v| v.as_str()),
            Some("dev-xyz")
        );
    }

    #[test]
    fn build_headers_returns_none_when_both_absent() {
        assert!(build_headers(None, &[]).is_none());
    }

    #[test]
    fn log_chunk_device_ids_extracts_from_record_attribute() {
        let chunk = make_log_request_with_device("dev-abc");
        assert_eq!(log_chunk_device_ids(&chunk), vec!["dev-abc"]);
    }

    #[test]
    fn log_chunk_device_ids_deduplicates_across_records() {
        let chunk = ExportLogsServiceRequest {
            resource_logs: vec![ResourceLogs {
                scope_logs: vec![ScopeLogs {
                    log_records: vec![
                        LogRecord {
                            attributes: vec![KeyValue {
                                key: DEVICE_ID_ATTRIBUTE.to_owned(),
                                value: Some(AnyValue {
                                    value: Some(any_value::Value::StringValue(
                                        "dev-abc".to_owned(),
                                    )),
                                }),
                            }],
                            ..Default::default()
                        },
                        LogRecord {
                            attributes: vec![KeyValue {
                                key: DEVICE_ID_ATTRIBUTE.to_owned(),
                                value: Some(AnyValue {
                                    value: Some(any_value::Value::StringValue(
                                        "dev-abc".to_owned(),
                                    )),
                                }),
                            }],
                            ..Default::default()
                        },
                    ],
                    ..Default::default()
                }],
                ..Default::default()
            }],
        };
        assert_eq!(log_chunk_device_ids(&chunk), vec!["dev-abc"]);
    }

    #[test]
    fn log_chunk_device_ids_empty_when_no_attribute() {
        let chunk = ExportLogsServiceRequest {
            resource_logs: vec![ResourceLogs {
                scope_logs: vec![ScopeLogs {
                    log_records: vec![LogRecord {
                        attributes: vec![KeyValue {
                            key: "some.other.attr".to_owned(),
                            value: Some(AnyValue {
                                value: Some(any_value::Value::StringValue("val".to_owned())),
                            }),
                        }],
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                ..Default::default()
            }],
        };
        assert!(log_chunk_device_ids(&chunk).is_empty());
    }
}
