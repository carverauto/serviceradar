// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Shared test fixtures and helpers for the crate-internal test suite.

use std::sync::{Arc, Mutex};

use addon_sdk::TelemetryBatchBuilder;
use addon_sdk::metric_pb::{Metric, MetricBatch, MetricPoint, MetricResource, StringMapEntry};
use addon_sdk::pb::{MetricFeedFrame, TelemetryBatch};
use prost::Message;
use tokio::sync::{broadcast, mpsc};
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

use crate::config::NativeTelemetryDropCounters;
use crate::engine::DetectorEngine;
use crate::frame::process_frame;
use crate::health::ScoringHealth;
use addon_sdk::MetricFeedStream;

pub(super) use broadcast::error::TryRecvError;

pub(super) fn entry(key: &str, value: &str) -> StringMapEntry {
    StringMapEntry {
        key: key.to_string(),
        value: value.to_string(),
    }
}

pub(super) fn metric_of_type(metric_type: &str) -> Metric {
    Metric {
        name: format!("{metric_type}.used_percent"),
        metric_type: metric_type.to_string(),
        ..Default::default()
    }
}

pub(super) fn metric_named(name: &str, metric_type: &str) -> Metric {
    Metric {
        name: name.to_string(),
        metric_type: metric_type.to_string(),
        ..Default::default()
    }
}

pub(super) fn anomaly_metric_batch(value: f64, observed_at_unix_nano: u64) -> MetricBatch {
    MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            device_id: "device-a".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "custom.value".to_string(),
            metric_type: "custom".to_string(),
            points: vec![MetricPoint {
                value,
                observed_at_unix_nano,
                series_identity_hint: "series-a".to_string(),
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    }
}

pub(super) fn sysmon_cpu_debug_spike_batch(value: f64, observed_at_unix_nano: u64) -> MetricBatch {
    sysmon_cpu_multi_core_batch(
        &[(0, value), (1, value), (2, value), (3, value)],
        observed_at_unix_nano,
    )
}

pub(super) fn sysmon_cpu_multi_core_batch(
    values: &[(u32, f64)],
    observed_at_unix_nano: u64,
) -> MetricBatch {
    let metrics = values
        .iter()
        .map(|(core_id, value)| Metric {
            name: "cpu.usage_percent".to_string(),
            metric_type: "sysmon.cpu".to_string(),
            unit: "%".to_string(),
            points: vec![MetricPoint {
                value: *value,
                observed_at_unix_nano,
                attributes: vec![
                    entry("core_id", &core_id.to_string()),
                    entry("label", &format!("cpu{core_id}")),
                ],
                ..Default::default()
            }],
            ..Default::default()
        })
        .collect();

    MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            device_id: "device-a".to_string(),
            host_ip: "10.0.0.10".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        }),
        metrics,
        ..Default::default()
    }
}

pub(super) fn sysmon_cpu_core_batch(
    core_id: u32,
    value: f64,
    observed_at_unix_nano: u64,
) -> MetricBatch {
    MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            device_id: "device-a".to_string(),
            host_ip: "10.0.0.10".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "cpu.usage_percent".to_string(),
            metric_type: "sysmon.cpu".to_string(),
            unit: "%".to_string(),
            points: vec![MetricPoint {
                value,
                observed_at_unix_nano,
                attributes: vec![
                    entry("core_id", &core_id.to_string()),
                    entry("label", &format!("cpu{core_id}")),
                ],
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    }
}

pub(super) fn metric_feed_frame_from_batch(feed_id: u64, batch: MetricBatch) -> MetricFeedFrame {
    MetricFeedFrame {
        feed_id,
        source: None,
        payload: batch.encode_to_vec(),
    }
}

pub(super) fn metric_feed_frame(feed_id: u64, value: f64) -> MetricFeedFrame {
    MetricFeedFrame {
        feed_id,
        source: None,
        payload: anomaly_metric_batch(value, feed_id).encode_to_vec(),
    }
}

pub(super) fn metric_feed_stream() -> (
    mpsc::Sender<Result<MetricFeedFrame, Status>>,
    MetricFeedStream,
) {
    let (tx, rx) = mpsc::channel(4);
    (tx, Box::pin(ReceiverStream::new(rx)))
}

pub(super) async fn process_anomaly_value(
    engine: &Arc<Mutex<DetectorEngine>>,
    tx: &broadcast::Sender<TelemetryBatch>,
    telemetry_drops: &NativeTelemetryDropCounters,
    value: f64,
    observed_at_unix_nano: u64,
) {
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let frame = MetricFeedFrame {
        feed_id: observed_at_unix_nano,
        source: None,
        payload: anomaly_metric_batch(value, observed_at_unix_nano).encode_to_vec(),
    };

    process_frame(engine, tx, telemetry_drops, &scoring_health, &frame).await;
}

pub(super) fn assert_no_batch(rx: &mut broadcast::Receiver<TelemetryBatch>) {
    assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
}

pub(super) fn recv_single_event(rx: &mut broadcast::Receiver<TelemetryBatch>) -> serde_json::Value {
    let batch = rx.try_recv().expect("telemetry batch");
    assert_eq!(batch.records.len(), 1);
    serde_json::from_slice(&batch.records[0].payload).expect("event json")
}

pub(super) fn empty_telemetry_batch(source_instance: &str) -> TelemetryBatch {
    TelemetryBatchBuilder::new("test", source_instance).build()
}

pub(super) fn telemetry_drop_counters() -> Arc<NativeTelemetryDropCounters> {
    Arc::new(NativeTelemetryDropCounters::default())
}
