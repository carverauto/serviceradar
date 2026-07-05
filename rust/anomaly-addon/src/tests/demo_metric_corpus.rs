// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// SPDX-License-Identifier: Apache-2.0

use std::sync::{Arc, Mutex};

use addon_sdk::metric_pb::MetricBatch;
use addon_sdk::pb::MetricFeedFrame;
use prost::Message;
use tokio::sync::broadcast;
use tokio::sync::broadcast::error::TryRecvError;

use super::demo_metric_corpus_data::CAPTURED_DEMO_METRIC_PAYLOADS;
use super::support::telemetry_drop_counters;
use crate::engine::{DetectorEngine, EngineConfig};
use crate::frame::process_frame;
use crate::health::ScoringHealth;

#[tokio::test]
async fn captured_demo_metric_corpus_replays_without_critical_or_unbounded_scores() {
    let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
        max_series: 200_000,
        ..EngineConfig::default()
    })));
    let (tx, mut rx) = broadcast::channel(64);
    let telemetry_drops = telemetry_drop_counters();
    let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));

    let mut decoded_batches = 0usize;
    let mut decoded_points = 0usize;
    let mut emitted_events: Vec<serde_json::Value> = Vec::new();

    for captured in CAPTURED_DEMO_METRIC_PAYLOADS {
        assert!(!captured.subject.is_empty());
        assert!(captured.sequence > 0);

        let payload = hex::decode(captured.payload_hex).expect("fixture payload is hex");
        let batch =
            MetricBatch::decode(payload.as_slice()).expect("fixture decodes as MetricBatch");
        decoded_batches += 1;
        decoded_points += batch
            .metrics
            .iter()
            .map(|metric| metric.points.len())
            .sum::<usize>();

        let frame = MetricFeedFrame {
            feed_id: captured.sequence,
            source: None,
            payload,
        };
        process_frame(&engine, &tx, &telemetry_drops, &scoring_health, &frame).await;

        loop {
            match rx.try_recv() {
                Ok(batch) => emitted_events.extend(
                    batch
                        .records
                        .into_iter()
                        .map(|record| serde_json::from_slice::<serde_json::Value>(&record.payload))
                        .collect::<Result<Vec<_>, _>>()
                        .expect("telemetry payload is JSON"),
                ),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Lagged(skipped)) => panic!("test receiver lagged by {skipped}"),
                Err(TryRecvError::Closed) => panic!("test broadcast channel closed"),
            }
        }
    }

    assert_eq!(decoded_batches, CAPTURED_DEMO_METRIC_PAYLOADS.len());
    assert!(
        decoded_points > 0,
        "captured corpus must contain metric points"
    );

    let anomaly_events: Vec<_> = emitted_events
        .iter()
        .filter(|event| event.get("anomaly").is_some())
        .collect();
    let critical_count = anomaly_events
        .iter()
        .filter(|event| event["severity_id"] == 5)
        .count();
    let critical_share = if anomaly_events.is_empty() {
        0.0
    } else {
        critical_count as f64 / anomaly_events.len() as f64
    };

    assert!(
        critical_share < 0.01,
        "captured demo corpus Critical share must stay below 1%, got {critical_count}/{}",
        anomaly_events.len()
    );
    assert!(
        anomaly_events.iter().all(|event| event["anomaly"]["score"]
            .as_f64()
            .is_some_and(|score| score <= 50.0)),
        "stored anomaly scores from captured demo corpus must stay bounded at 50"
    );
}
