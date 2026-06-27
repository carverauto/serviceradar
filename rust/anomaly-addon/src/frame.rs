// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Per-frame scoring: decode a metric-feed frame, score every eligible point, and
//! push verdict telemetry; plus the broadcast->mpsc telemetry stream bridge.

use std::sync::{Arc, Mutex};

use addon_sdk::TelemetryBatchBuilder;
use addon_sdk::metric_pb::MetricBatch;
use addon_sdk::pb::{MetricFeedFrame, TelemetryBatch, TelemetryRecord};
use prost::Message;
use tokio::sync::{broadcast, mpsc};
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

use crate::addon::{lock_engine, lock_scoring_health};
use crate::config::{NativeTelemetryDropCounters, VERDICT_CHANNEL_DEPTH};
use crate::engine::{AnomalyTransition, DetectorEngine, SeriesProfile};
use crate::health::{ScoringFrameUpdate, ScoringHealth};
use crate::identity::{
    is_snmp_metric_class, metric_class, series_key_for, snmp_polled_device_identity,
};
use crate::metrics_classify::{
    counter_raw_value, counter_reset_anchor, counter_width, is_cumulative_counter,
    is_process_metric, max_counter_rate_per_second, series_profile_for,
};
use crate::shed::{ShedReport, shed_record};
use crate::verdict::verdict_record;
use addon_sdk::TelemetryStream;

/// Decode one feed frame's `MetricBatch`, score every eligible point, and push a
/// verdict telemetry batch for any breaches.
pub(crate) async fn process_frame(
    engine: &Arc<Mutex<DetectorEngine>>,
    verdict_tx: &broadcast::Sender<TelemetryBatch>,
    telemetry_drops: &NativeTelemetryDropCounters,
    scoring_health: &Arc<Mutex<ScoringHealth>>,
    frame: &MetricFeedFrame,
) {
    let batch = match MetricBatch::decode(frame.payload.as_slice()) {
        Ok(batch) => batch,
        Err(_) => return, // poison payload: drop the frame, never block the feed
    };
    let resource = batch.resource.unwrap_or_default();

    // Lock the engine only to score; never hold the std Mutex across an await.
    let mut records: Vec<TelemetryRecord> = Vec::new();
    let mut shed_report: Option<ShedReport> = None;
    let mut scored_samples = 0_u64;
    let mut last_scored_at_unix_nano = 0_u64;
    {
        let mut engine = lock_engine(engine);
        let dropped_before = engine.dropped_at_capacity;
        for metric in &batch.metrics {
            if is_process_metric(metric) {
                // Process/PID series are excluded from anomaly centrally
                // (sample_extractor) and at the edge for the same reason.
                continue;
            }

            // Monotonic cumulative counters (SNMP interface octets, etc.) cannot
            // be z-scored as raw values; rate-normalize each reading to a
            // per-second rate the same way central does before scoring.
            let counter = is_cumulative_counter(metric);
            let metric_class = metric_class(metric);

            // Per-series fidelity profile (dispersion floors + saturation gate).
            // A rate-normalized counter has NO saturation ceiling, so it stays
            // purely z-based (no gate) — a real flood must still fire. A
            // saturation gauge (cpu/mem/disk used_percent) gets the directional +
            // absolute-floor gate and the dispersion floors so a benign near-
            // constant level cannot explode into a Critical.
            let profile = if counter {
                SeriesProfile::default()
            } else {
                series_profile_for(metric)
            };

            for point in &metric.points {
                if is_snmp_metric_class(metric_class)
                    && snmp_polled_device_identity(&resource, metric_class, metric, point)
                        .is_empty()
                {
                    continue;
                }

                let series_key = series_key_for(&resource, metric, point);

                let value = if counter {
                    match engine.normalize_counter_with_max_rate(
                        &series_key,
                        counter_raw_value(point),
                        point.observed_at_unix_nano,
                        &counter_reset_anchor(point),
                        counter_width(metric, point),
                        max_counter_rate_per_second(metric, point),
                    ) {
                        Some(rate) => rate,
                        // Warmup / reset / gap / non-monotonic: no sample this point.
                        None => continue,
                    }
                } else {
                    point.value
                };

                scored_samples = scored_samples.saturating_add(1);
                last_scored_at_unix_nano =
                    last_scored_at_unix_nano.max(point.observed_at_unix_nano);

                if let Some(evaluated) = engine.evaluate_transition(
                    &series_key,
                    value,
                    point.observed_at_unix_nano,
                    profile,
                ) && matches!(
                    evaluated.transition,
                    AnomalyTransition::Open | AnomalyTransition::Clear
                ) {
                    records.push(verdict_record(
                        &resource,
                        metric,
                        point,
                        &series_key,
                        &evaluated.verdict,
                        evaluated.transition,
                        evaluated.episode,
                    ));
                }
            }
        }

        let dropped_after = engine.dropped_at_capacity;
        if dropped_after > dropped_before {
            shed_report = Some(ShedReport {
                dropped_delta: dropped_after - dropped_before,
                dropped_total: dropped_after,
                tracked_series: engine.series_count(),
                tracked_counters: engine.counter_count(),
                max_series: engine.max_series(),
            });
        }
    }

    let emitted_records = records.len() as u64;

    if let Some(report) = shed_report {
        records.push(shed_record(&resource, frame.feed_id, report));
    }

    lock_scoring_health(scoring_health).record_frame(ScoringFrameUpdate {
        feed_id: frame.feed_id,
        scored_samples,
        emitted_verdicts: emitted_records,
        last_scored_at_unix_nano,
    });

    if records.is_empty() {
        return;
    }

    let mut builder = TelemetryBatchBuilder::new("anomaly-addon", resource.agent_id.clone());
    for record in records {
        builder = builder.push_record(record);
    }
    if verdict_tx.send(builder.build()).is_err() {
        telemetry_drops.record_no_subscriber_batch();
    }
}

pub(crate) fn telemetry_stream_from_receiver(
    mut rx: broadcast::Receiver<TelemetryBatch>,
    telemetry_drops: Arc<NativeTelemetryDropCounters>,
) -> TelemetryStream {
    let (tx, out_rx) = mpsc::channel::<Result<TelemetryBatch, Status>>(VERDICT_CHANNEL_DEPTH);

    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(batch) => match tx.try_send(Ok(batch)) {
                    Ok(()) => {}
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        telemetry_drops.record_outbound_full_batch();
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => break,
                },
                Err(broadcast::error::RecvError::Lagged(count)) => {
                    telemetry_drops.record_lagged_batches(count);
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    Box::pin(ReceiverStream::new(out_rx))
}
