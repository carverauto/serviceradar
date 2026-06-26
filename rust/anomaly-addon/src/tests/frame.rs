// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::sync::{Arc, Mutex};

use addon_sdk::HealthStatus;
use addon_sdk::metric_pb::{Metric, MetricBatch, MetricPoint, MetricResource};
use addon_sdk::pb::MetricFeedFrame;
use prost::Message;
use tokio::sync::broadcast;

use super::support::{
    assert_no_batch, metric_feed_frame, metric_feed_frame_from_batch, process_anomaly_value,
    recv_single_event, sysmon_cpu_debug_spike_batch, telemetry_drop_counters,
};
use crate::engine::{DetectorEngine, EngineConfig};
use crate::frame::process_frame;
use crate::health::{EngineHealthSnapshot, ScoringHealth};
use crate::identity::safe_component;

#[tokio::test]
async fn process_frame_reports_capacity_shed_once_per_frame() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        max_series: 1,
        min_samples: 1,
        confirm_slots: 1,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(4);
    let batch = MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "cpu.usage_percent".to_string(),
            metric_type: "sysmon.cpu".to_string(),
            points: vec![
                MetricPoint {
                    value: 10.0,
                    observed_at_unix_nano: 1,
                    series_identity_hint: "series-a".to_string(),
                    ..Default::default()
                },
                MetricPoint {
                    value: 20.0,
                    observed_at_unix_nano: 2,
                    series_identity_hint: "series-b".to_string(),
                    ..Default::default()
                },
                MetricPoint {
                    value: 30.0,
                    observed_at_unix_nano: 3,
                    series_identity_hint: "series-c".to_string(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        }],
        ..Default::default()
    };
    let frame = MetricFeedFrame {
        feed_id: 7,
        source: None,
        payload: batch.encode_to_vec(),
    };

    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;

    let sent = rx.recv().await.expect("telemetry batch");
    assert_eq!(sent.records.len(), 1);
    let event: serde_json::Value = serde_json::from_slice(&sent.records[0].payload).unwrap();
    assert_eq!(event["status_code"], "anomaly_capacity_shed");
    assert_eq!(event["unmapped"]["dropped_series_delta"], 2);
    assert_eq!(event["unmapped"]["feed_id"], 7);
    let engine_snapshot = {
        let engine = engine.lock().expect("engine");
        EngineHealthSnapshot {
            tracked_series: engine.series_count(),
            tracked_counters: 0,
            max_series: 1,
            dropped_total: engine.dropped_at_capacity,
        }
    };
    let health = scoring_health
        .lock()
        .expect("health")
        .health_summary(engine_snapshot);
    assert_eq!(health.status, HealthStatus::Degraded);
    assert!(health.detail.contains("state=capacity_shed"));
    assert_eq!(event["unmapped"]["tracked_counters"], 0);
    assert_eq!(engine.lock().unwrap().dropped_at_capacity, 2);
}

#[tokio::test]
async fn poisoned_engine_mutex_recovers_before_scoring() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        max_series: 7,
        ..EngineConfig::default()
    })));
    let poison_engine = engine.clone();

    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(move || {
        let _guard = poison_engine.lock().expect("lock before poison");
        panic!("poison engine mutex");
    });
    std::panic::set_hook(hook);
    assert!(result.is_err());
    assert!(engine.lock().is_err(), "test must poison the engine mutex");

    let (tx, _rx) = broadcast::channel(4);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &metric_feed_frame(1, 100.0),
    )
    .await;

    let guard = engine.lock().expect("process_frame clears engine poison");
    assert_eq!(guard.series_count(), 1);
    assert_eq!(guard.max_series(), 7);
}

#[tokio::test]
async fn process_frame_counts_telemetry_without_subscriber() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 10,
        ..EngineConfig::default()
    })));
    let (tx, _) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();

    for ts in 1..=20 {
        process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, ts).await;
    }
    assert_eq!(telemetry_drops.snapshot().no_subscriber_batches, 0);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 21).await;
    assert_eq!(telemetry_drops.snapshot().no_subscriber_batches, 0);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 22).await;
    assert_eq!(telemetry_drops.snapshot().no_subscriber_batches, 1);
}

#[tokio::test]
async fn process_frame_emits_only_anomaly_open_and_clear_transitions() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 10,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();

    for ts in 1..=20 {
        process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, ts).await;
    }
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 21).await;
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 22).await;
    let open = recv_single_event(&mut rx);
    assert_eq!(open["status"], "open");
    assert_eq!(open["anomaly"]["state"], "anomaly_open");
    assert_eq!(open["anomaly"]["detector_state"], "anomalous");

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 23).await;
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, 24).await;
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, 25).await;
    let clear = recv_single_event(&mut rx);
    assert_eq!(clear["status"], "inactive");
    assert_eq!(clear["anomaly"]["state"], "anomaly_clear");
    assert_eq!(clear["anomaly"]["detector_state"], "clean");
    assert!(
        !clear["message"]
            .as_str()
            .unwrap_or_default()
            .contains("pending_anomaly")
    );
}

#[tokio::test]
async fn sysmon_debug_spike_smoke_emits_one_open_finding() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 10,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let start = 1_812_456_000_000_000_000_u64;
    let sample_time = |seconds: u64| start + (seconds * 1_000_000_000);

    for ts in 1..=20 {
        let frame = metric_feed_frame_from_batch(
            ts,
            sysmon_cpu_debug_spike_batch(25.0, sample_time(ts)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }
    assert_no_batch(&mut rx);

    for ts in 21..=26 {
        let frame = metric_feed_frame_from_batch(
            ts,
            sysmon_cpu_debug_spike_batch(95.0, sample_time(ts)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    let open = recv_single_event(&mut rx);
    assert_no_batch(&mut rx);
    let expected_open_time = sample_time(21);

    assert_eq!(open["status"], "open");
    assert_eq!(open["anomaly"]["state"], "anomaly_open");
    assert_eq!(open["time"], (expected_open_time / 1_000_000) as i64);
    assert_eq!(open["anomaly"]["observed_at_unix_nano"], expected_open_time);
    assert_eq!(open["device_uid"], "device-a");
    assert_eq!(open["device_id"], "device-a");
    assert_eq!(open["source_identity"]["agent_id"], "agent-a");
    assert_eq!(open["source_identity"]["host_id"], "host-a");
    assert_eq!(open["source_identity"]["device_id"], "device-a");
    assert_eq!(open["source_identity"]["partition"], "demo");
    assert_eq!(open["source_identity"]["metric_name"], "cpu.usage_percent");
    assert_eq!(open["source_identity"]["metric_class"], "sysmon.cpu");
    assert_eq!(
        open["source_identity"]["series_key"],
        [
            "v2".to_string(),
            safe_component("partition", "demo"),
            safe_component("identity", "device-a"),
            safe_component("metric", "cpu.usage_percent"),
        ]
        .join("|")
    );
    assert_eq!(open["source_identity"]["tags"]["core_id"], "1");
    assert_eq!(open["source_identity"]["tags"]["label"], "cpu1");
}
