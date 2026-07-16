// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use addon_sdk::HealthStatus;
use addon_sdk::metric_pb::{Metric, MetricBatch, MetricPoint, MetricResource};
use addon_sdk::pb::MetricFeedFrame;
use prost::Message;
use tokio::sync::broadcast;

use super::support::{
    assert_no_batch, metric_feed_frame, metric_feed_frame_from_batch, process_anomaly_value,
    recv_single_event, sysmon_cpu_core_batch, sysmon_cpu_debug_spike_batch,
    sysmon_cpu_multi_core_batch, telemetry_drop_counters,
};
use crate::engine::{DetectorEngine, EngineConfig, MetricClassOverride};
use crate::frame::process_frame;
use crate::health::{EngineHealthSnapshot, ScoringHealth};
use crate::identity::safe_component;

fn tag_component(key: &str, value: &str) -> String {
    safe_component(&format!("tag_{}", hex::encode(key.as_bytes())), value)
}

fn multi_series_custom_batch(values: &[(&str, f64)], observed_at_unix_nano: u64) -> MetricBatch {
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
            points: values
                .iter()
                .map(|(series, value)| MetricPoint {
                    value: *value,
                    observed_at_unix_nano,
                    series_identity_hint: (*series).to_string(),
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }],
        ..Default::default()
    }
}

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
            drift_inactive_no_baseline_total: engine.drift_inactive_no_baseline,
            clamped_samples_total: engine.clamped_samples,
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
async fn snmp_points_without_target_identity_are_not_scored_on_the_agent_series() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 10,
        min_samples: 1,
        n_sigma: 1.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let batch = MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-dusk01".to_string(),
            host_id: "dusk01".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "ifHCInOctets".to_string(),
            metric_type: "snmp.interface".to_string(),
            points: vec![MetricPoint {
                value: 10_000.0,
                observed_at_unix_nano: 1_812_456_000_000_000_000,
                if_index: 6,
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    };

    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &metric_feed_frame_from_batch(42, batch),
    )
    .await;

    assert_no_batch(&mut rx);
    assert_eq!(engine.lock().unwrap().series_count(), 0);
}

#[tokio::test]
async fn metric_denylist_skips_cpu_frequency() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let batch = MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            device_id: "device-a".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "cpu.frequency_hz".to_string(),
            metric_type: "sysmon.cpu".to_string(),
            points: vec![MetricPoint {
                value: 1_000_000_000.0,
                observed_at_unix_nano: 1,
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    };

    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &metric_feed_frame_from_batch(43, batch),
    )
    .await;

    assert_no_batch(&mut rx);
    assert_eq!(engine.lock().unwrap().series_count(), 0);
    assert_eq!(scoring_health.lock().unwrap().scored_samples, 0);
}

#[tokio::test]
async fn metric_class_disabled_skips_cpu_scoring_and_state() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 10,
        min_samples: 1,
        n_sigma: 1.0,
        confirm_slots: 1,
        max_series: 10,
        metric_class_overrides: HashMap::from([(
            "cpu".to_string(),
            MetricClassOverride {
                enabled: Some(false),
                ..MetricClassOverride::default()
            },
        )]),
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));

    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &metric_feed_frame_from_batch(44, sysmon_cpu_core_batch(1, 95.0, 44)),
    )
    .await;

    assert_no_batch(&mut rx);
    assert_eq!(engine.lock().unwrap().series_count(), 0);
    assert_eq!(scoring_health.lock().unwrap().scored_samples, 0);
}

#[tokio::test]
async fn snmp_points_with_canonical_polled_device_are_scored_without_target_ip() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 10,
        min_samples: 1,
        n_sigma: 1.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let batch = MetricBatch {
        resource: Some(MetricResource {
            agent_id: "agent-dusk01".to_string(),
            host_id: "dusk01".to_string(),
            device_id: "sr:farm01".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "ifHCInOctets".to_string(),
            metric_type: "snmp.interface".to_string(),
            points: vec![MetricPoint {
                value: 10_000.0,
                observed_at_unix_nano: 1_812_456_000_000_000_000,
                if_index: 6,
                ..Default::default()
            }],
            ..Default::default()
        }],
        ..Default::default()
    };

    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &metric_feed_frame_from_batch(43, batch),
    )
    .await;

    assert_no_batch(&mut rx);
    assert_eq!(engine.lock().unwrap().series_count(), 1);
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
    assert_eq!(open["anomaly"]["episode_started_at_unix_nano"], 21);
    assert_eq!(open["anomaly"]["episode_ended_at_unix_nano"], 22);
    assert_eq!(open["anomaly"]["episode_peak_value"], 1000.0);
    assert_eq!(open["anomaly"]["episode_peak_at_unix_nano"], 21);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 23).await;
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, 24).await;
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, 25).await;
    let clear = recv_single_event(&mut rx);
    assert_eq!(clear["status"], "inactive");
    assert_eq!(clear["anomaly"]["state"], "anomaly_clear");
    assert_eq!(clear["anomaly"]["detector_state"], "clean");
    assert_eq!(clear["anomaly"]["episode_started_at_unix_nano"], 21);
    assert_eq!(clear["anomaly"]["episode_ended_at_unix_nano"], 25);
    assert_eq!(clear["anomaly"]["episode_peak_value"], 1000.0);
    assert_eq!(clear["anomaly"]["episode_peak_at_unix_nano"], 21);
    assert!(
        !clear["message"]
            .as_str()
            .unwrap_or_default()
            .contains("pending_anomaly")
    );
}

#[tokio::test]
async fn process_frame_flap_reopen_bypasses_the_open_cooldown() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        emission_cooldown_secs: 300,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();

    for ts in 1..=8 {
        process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, ts).await;
    }
    assert_no_batch(&mut rx);

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 9).await;
    let open = recv_single_event(&mut rx);
    assert_eq!(open["transition"], "open");

    process_anomaly_value(&engine, &tx, &telemetry_drops, 100.0, 10).await;
    let clear = recv_single_event(&mut rx);
    assert_eq!(clear["transition"], "clear");

    process_anomaly_value(&engine, &tx, &telemetry_drops, 1_000.0, 11).await;
    let reopened = recv_single_event(&mut rx);
    assert_eq!(reopened["transition"], "update");
    assert_eq!(reopened["anomaly"]["state"], "anomaly_update");
    assert_eq!(reopened["anomaly"]["update_reason"], "flapping");
}

#[tokio::test]
async fn process_frame_budget_sheds_with_accounted_rollup_and_storm_entry() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 20,
        emission_budget_per_tick: 2,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let series = ["s0", "s1", "s2", "s3", "s4"];

    for ts in 1..=8 {
        let warm: Vec<_> = series.iter().map(|series| (*series, 100.0)).collect();
        process_frame(
            &engine,
            &tx,
            &telemetry_drops,
            &scoring_health,
            &metric_feed_frame_from_batch(ts, multi_series_custom_batch(&warm, ts)),
        )
        .await;
    }
    assert_no_batch(&mut rx);

    let high: Vec<_> = series.iter().map(|series| (*series, 1_000.0)).collect();
    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &metric_feed_frame_from_batch(9, multi_series_custom_batch(&high, 9)),
    )
    .await;

    let batch = rx.try_recv().expect("telemetry batch");
    assert_eq!(batch.records.len(), 3, "2 opens + 1 emission shed rollup");
    let events: Vec<serde_json::Value> = batch
        .records
        .iter()
        .map(|record| serde_json::from_slice(&record.payload).expect("event json"))
        .collect();
    let anomaly_count = events
        .iter()
        .filter(|event| event["event_type"].as_str() == Some("anomaly"))
        .count();
    let rollup = events
        .iter()
        .find(|event| event["status_code"].as_str() == Some("anomaly_emission_shed"))
        .expect("emission shed rollup");

    assert_eq!(anomaly_count, 2);
    assert_eq!(rollup["unmapped"]["detected_transitions"], 5);
    assert_eq!(rollup["unmapped"]["emitted_transitions"], 2);
    assert_eq!(rollup["unmapped"]["budget_shed"], 3);
    assert_eq!(rollup["unmapped"]["accounted_transitions"], 3);
    assert_eq!(rollup["unmapped"]["storm_entered"], true);
}

#[tokio::test]
async fn sustained_sysmon_cpu_spike_emits_one_open_then_one_clear_with_episode_window() {
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
    let sample_time = |slot: u64| start + (slot * 30 * 1_000_000_000);

    for ts in 1..=8 {
        let frame =
            metric_feed_frame_from_batch(ts, sysmon_cpu_core_batch(1, 25.0, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }
    assert_no_batch(&mut rx);

    for ts in 9..=11 {
        let frame =
            metric_feed_frame_from_batch(ts, sysmon_cpu_core_batch(1, 95.0, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    let open = recv_single_event(&mut rx);
    assert_no_batch(&mut rx);
    let expected_open_time = sample_time(10);

    assert_eq!(open["status"], "open");
    assert_eq!(open["anomaly"]["state"], "anomaly_open");
    assert_eq!(open["time"], (expected_open_time / 1_000_000) as i64);
    assert_eq!(open["anomaly"]["observed_at_unix_nano"], expected_open_time);
    assert_eq!(
        open["anomaly"]["episode_started_at_unix_nano"],
        sample_time(9)
    );
    assert_eq!(
        open["anomaly"]["episode_ended_at_unix_nano"],
        expected_open_time
    );
    assert_eq!(open["anomaly"]["episode_peak_value"], 95.0);
    assert_eq!(open["anomaly"]["episode_peak_at_unix_nano"], sample_time(9));
    assert_eq!(open["anomaly"]["consecutive_anomalous"], 2);
    assert!(
        !open["anomaly"]["signals"]
            .as_array()
            .expect("signals array")
            .is_empty()
    );
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
            tag_component("core_id", "1"),
            tag_component("label", "cpu1"),
        ]
        .join("|")
    );
    assert_eq!(open["source_identity"]["tags"]["core_id"], "1");
    assert_eq!(open["source_identity"]["tags"]["label"], "cpu1");

    for ts in 12..=14 {
        let frame =
            metric_feed_frame_from_batch(ts, sysmon_cpu_core_batch(1, 25.0, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    let clear = recv_single_event(&mut rx);
    assert_no_batch(&mut rx);
    let expected_clear_time = sample_time(13);

    assert_eq!(clear["status"], "inactive");
    assert_eq!(clear["anomaly"]["state"], "anomaly_clear");
    assert_eq!(clear["anomaly"]["detector_state"], "clean");
    assert_eq!(clear["time"], (expected_clear_time / 1_000_000) as i64);
    assert_eq!(
        clear["anomaly"]["observed_at_unix_nano"],
        expected_clear_time
    );
    assert_eq!(
        clear["anomaly"]["episode_started_at_unix_nano"],
        sample_time(9)
    );
    assert_eq!(
        clear["anomaly"]["episode_ended_at_unix_nano"],
        expected_clear_time
    );
    assert_eq!(clear["anomaly"]["episode_peak_value"], 95.0);
    assert_eq!(
        clear["anomaly"]["episode_peak_at_unix_nano"],
        sample_time(9)
    );
}

#[tokio::test]
async fn short_cpu_spike_inside_one_evaluation_slot_does_not_open() {
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

    // Warm enough completed CPU evaluation slots. CPU points are max-aggregated
    // into 30s slots before the detector sees them.
    for slot in 1..=8 {
        let ts = slot * 30;
        let frame =
            metric_feed_frame_from_batch(slot, sysmon_cpu_core_batch(1, 25.0, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }
    assert_no_batch(&mut rx);

    // Multiple high-frequency points inside one 30s CPU slot are one anomalous
    // evaluation slot, not enough to satisfy confirm_slots=2.
    for offset in [1, 5, 10, 20, 29] {
        let frame = metric_feed_frame_from_batch(
            100 + offset,
            sysmon_cpu_core_batch(1, 97.0, sample_time(9 * 30 + offset)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    // Advancing into following clean slots evaluates the spike slot once, then
    // resets the pending confirmation before it can open.
    for slot in [10, 11] {
        let frame = metric_feed_frame_from_batch(
            slot,
            sysmon_cpu_core_batch(1, 25.0, sample_time(slot * 30)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    assert_no_batch(&mut rx);
}

#[tokio::test]
async fn recurring_cpu_spikes_separated_by_clean_slots_do_not_accumulate_confirmation() {
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
    let sample_time = |slot: u64| start + (slot * 30 * 1_000_000_000);

    for ts in 1..=8 {
        let frame =
            metric_feed_frame_from_batch(ts, sysmon_cpu_core_batch(1, 25.0, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }
    assert_no_batch(&mut rx);

    // These are recurring, visible CPU peaks, but each peak is only one completed
    // CPU evaluation slot. The clean slot between peaks resets pending
    // confirmation, so normal periodic bursts do not accumulate into an open
    // anomaly.
    for (feed_id, slot, value) in [
        (100, 9, 97.0),
        (101, 10, 25.0),
        (102, 11, 97.0),
        (103, 12, 25.0),
        (104, 13, 97.0),
        (105, 14, 25.0),
        (106, 15, 25.0),
    ] {
        let frame = metric_feed_frame_from_batch(
            feed_id,
            sysmon_cpu_core_batch(1, value, sample_time(slot)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    assert_no_batch(&mut rx);
}

#[tokio::test]
async fn process_frame_does_not_emit_raw_cusum_drift_without_a_baseline() {
    // End-to-end through the production frame path: a gentle upward ramp the
    // rolling z-score absorbs into its mean must not produce raw/frozen-anchor
    // drift when the metric class has no delivered seasonal baseline.
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(128);
    let telemetry_drops = telemetry_drop_counters();

    // Warm a tight stationary baseline so the CUSUM anchor freezes at ~(100, 1).
    for ts in 0..30u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        process_anomaly_value(&engine, &tx, &telemetry_drops, v, ts + 1).await;
    }
    // Gentle ramp: each step is sub-threshold for the rolling z-score.
    for i in 1..=30u64 {
        let v = 100.0 + 0.4 * i as f64;
        process_anomaly_value(&engine, &tx, &telemetry_drops, v, 30 + i).await;
    }

    let mut methods = Vec::new();
    let mut drift_event: Option<serde_json::Value> = None;
    while let Ok(batch) = rx.try_recv() {
        for record in batch.records {
            let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
            let method = event["detector_method"]
                .as_str()
                .unwrap_or_default()
                .to_string();
            if method == "cusum_drift" && drift_event.is_none() {
                drift_event = Some(event.clone());
            }
            methods.push(method);
        }
    }

    assert!(
        !methods.iter().any(|m| m == "rolling_robust_zscore"),
        "the point z-score must NOT have flagged the gradual ramp (it missed it)"
    );
    assert!(
        drift_event.is_none(),
        "raw drift without a baseline must stay silent, saw methods: {methods:?}"
    );
}

#[tokio::test]
async fn multi_core_cpu_points_do_not_count_as_consecutive_samples_for_one_series() {
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
    let sample_time = |slot: u64| start + (slot * 30 * 1_000_000_000);

    for ts in 1..=8 {
        let frame =
            metric_feed_frame_from_batch(ts, sysmon_cpu_debug_spike_batch(25.0, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    let first_spike =
        metric_feed_frame_from_batch(9, sysmon_cpu_debug_spike_batch(95.0, sample_time(9)));
    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &first_spike,
    )
    .await;
    assert_no_batch(&mut rx);

    let second_spike =
        metric_feed_frame_from_batch(10, sysmon_cpu_debug_spike_batch(95.0, sample_time(10)));
    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &second_spike,
    )
    .await;
    assert_no_batch(&mut rx);

    let third_spike =
        metric_feed_frame_from_batch(11, sysmon_cpu_debug_spike_batch(95.0, sample_time(11)));
    process_frame(
        &engine,
        &tx,
        &telemetry_drops,
        &scoring_health,
        &third_spike,
    )
    .await;

    let batch = rx.try_recv().expect("sustained spike emits one batch");
    assert_eq!(batch.records.len(), 5);

    let events = batch
        .records
        .iter()
        .map(|record| {
            serde_json::from_slice::<serde_json::Value>(&record.payload).expect("event json")
        })
        .collect::<Vec<_>>();
    let series_keys = events
        .iter()
        .map(|event| {
            event["source_identity"]["series_key"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect::<std::collections::BTreeSet<_>>();
    let host_events = events
        .iter()
        .filter(|event| event["source_identity"]["tags"].get("core_id").is_none())
        .collect::<Vec<_>>();
    let per_core_events = events
        .iter()
        .filter(|event| event["source_identity"]["tags"].get("core_id").is_some())
        .count();

    assert_eq!(series_keys.len(), 5);
    assert_eq!(per_core_events, 4);
    assert_eq!(host_events.len(), 1);
    assert_eq!(
        host_events[0]["source_identity"]["series_key"],
        [
            "v2".to_string(),
            safe_component("partition", "demo"),
            safe_component("identity", "device-a"),
            safe_component("metric", "cpu.usage_percent"),
        ]
        .join("|")
    );
}

#[tokio::test]
async fn one_busy_core_does_not_emit_host_cpu_aggregate_open() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 20,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let start = 1_812_456_000_000_000_000_u64;
    let sample_time = |slot: u64| start + (slot * 30 * 1_000_000_000);
    let mostly_idle = [(0, 25.0), (1, 25.0), (2, 25.0), (3, 25.0)];

    for ts in 1..=8 {
        let frame = metric_feed_frame_from_batch(
            ts,
            sysmon_cpu_multi_core_batch(&mostly_idle, sample_time(ts)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }
    assert_no_batch(&mut rx);

    let one_busy = [(0, 95.0), (1, 25.0), (2, 25.0), (3, 25.0)];
    for ts in 9..=11 {
        let frame = metric_feed_frame_from_batch(
            ts,
            sysmon_cpu_multi_core_batch(&one_busy, sample_time(ts)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    let batch = rx
        .try_recv()
        .expect("single busy core emits per-core event");
    assert_eq!(batch.records.len(), 1);
    let event: serde_json::Value = serde_json::from_slice(&batch.records[0].payload).unwrap();
    assert_eq!(event["source_identity"]["tags"]["core_id"], "0");
    assert!(
        event["source_identity"]["series_key"]
            .as_str()
            .expect("series key")
            .contains(&tag_component("core_id", "0"))
    );
    assert_no_batch(&mut rx);
}

#[tokio::test]
async fn host_wide_cpu_saturation_emits_critical_eligible_host_aggregate() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 20,
        critical_min_duration_secs: 1,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(8);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
    let start = 1_812_456_000_000_000_000_u64;
    let sample_time = |slot: u64| start + (slot * 30 * 1_000_000_000);
    let idle = [(0, 25.0), (1, 25.0), (2, 25.0), (3, 25.0)];
    let saturated = [(0, 95.0), (1, 95.0), (2, 95.0), (3, 95.0)];

    for ts in 1..=8 {
        let frame =
            metric_feed_frame_from_batch(ts, sysmon_cpu_multi_core_batch(&idle, sample_time(ts)));
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }
    assert_no_batch(&mut rx);

    for ts in 9..=11 {
        let frame = metric_feed_frame_from_batch(
            ts,
            sysmon_cpu_multi_core_batch(&saturated, sample_time(ts)),
        );
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;
    }

    let batch = rx.try_recv().expect("host-wide saturation emits events");
    let events = batch
        .records
        .iter()
        .map(|record| {
            serde_json::from_slice::<serde_json::Value>(&record.payload).expect("event json")
        })
        .collect::<Vec<_>>();
    let host = events
        .iter()
        .find(|event| event["source_identity"]["tags"].get("core_id").is_none())
        .expect("host aggregate event");

    assert_eq!(events.len(), 5);
    assert_eq!(host["severity_id"], 5);
    assert_eq!(host["anomaly"]["sample_value"], 95.0);
    assert_eq!(
        host["source_identity"]["series_key"],
        [
            "v2".to_string(),
            safe_component("partition", "demo"),
            safe_component("identity", "device-a"),
            safe_component("metric", "cpu.usage_percent"),
        ]
        .join("|")
    );
}
