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
use crate::output::{
    INGEST_IDENTITY_HEADER, IngestContext, PerformanceMetric, PublishOutcome, TelemetryOutput,
    encode_derived_metric_batch,
};

use super::NATSOutput;
use super::chunker::{
    MAX_PROTO_PUBLISH_BYTES, metric_request_data_points, split_logs_request, split_metrics_request,
    split_traces_request,
};

/// Builds the NATS headers stamped on every chunk published for an
/// authenticated request (`Sr-Ingest-Identity: <identity>`). Downstream
/// consumers (zen, db-event-writer) ignore headers they do not know.
fn identity_headers(identity: &str) -> async_nats::HeaderMap {
    let mut headers = async_nats::HeaderMap::new();
    headers.insert(INGEST_IDENTITY_HEADER, identity);
    headers
}

impl NATSOutput {
    /// Publishes one encoded chunk and waits for the JetStream ack.
    ///
    /// Holds no lock across the publish/ack awaits; a semaphore permit
    /// bounds the number of concurrently in-flight chunk publishes across
    /// all export requests.
    ///
    /// When `identity` is set the chunk is published with the
    /// `Sr-Ingest-Identity` header so downstream consumers can attribute
    /// the data to the authenticated sender.
    async fn publish_chunk(
        &self,
        subject: &str,
        payload: Vec<u8>,
        signal: &str,
        identity: Option<&str>,
    ) -> Result<()> {
        let _permit = self
            .publish_permits
            .acquire()
            .await
            .map_err(|_| anyhow!("NATS publish semaphore closed"))?;

        let (js, generation) = self.current_jetstream().await?;

        let publish_result = match identity {
            Some(identity) => {
                js.publish_with_headers(
                    subject.to_string(),
                    identity_headers(identity),
                    payload.into(),
                )
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
            self.publish_chunk(&traces_subject, payload, "traces", ctx.identity.as_deref())
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
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            debug!(
                "Encoded log chunk {}/{}: {} bytes",
                index + 1,
                log_chunks.len(),
                payload.len()
            );
            self.publish_chunk(&logs_subject, payload, "logs", ctx.identity.as_deref())
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
            ctx.identity.as_deref(),
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
                ctx.identity.as_deref(),
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
    use super::*;

    #[test]
    fn identity_headers_carry_sr_ingest_identity() {
        let headers = identity_headers("tenant-a");
        assert_eq!(
            headers.get(INGEST_IDENTITY_HEADER).map(|v| v.as_str()),
            Some("tenant-a")
        );
    }
}
