// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

use addon_sdk::{Addon, HealthStatus};

use crate::AnomalyAddon;
use crate::addon::{lock_engine, lock_scoring_health};
use crate::config::{ADDON_VERSION, DEFAULT_SCORING_STALE_AFTER_NS};
use crate::health::{EngineHealthSnapshot, ScoringFrameUpdate, ScoringHealth};

#[test]
fn health_summary_reports_no_scored_samples() {
    let summary = ScoringHealth::default().health_summary(EngineHealthSnapshot {
        tracked_series: 0,
        tracked_counters: 0,
        max_series: 50_000,
        dropped_total: 0,
        drift_inactive_no_baseline_total: 0,
        clamped_samples_total: 0,
    });

    assert_eq!(summary.status, HealthStatus::Degraded);
    assert!(summary.detail.contains("state=no_scored_samples"));
    assert!(summary.detail.contains("scored_samples=0"));
    assert!(summary.detail.contains("tracked_series=0"));
}

#[test]
fn health_summary_reports_active_scoring_and_capacity_pressure() {
    let mut scoring = ScoringHealth::default();
    scoring.record_frame(ScoringFrameUpdate {
        feed_id: 9,
        scored_samples: 3,
        emitted_verdicts: 1,
        last_scored_at_unix_nano: 123,
    });

    let active = scoring.health_summary(EngineHealthSnapshot {
        tracked_series: 2,
        tracked_counters: 1,
        max_series: 50_000,
        dropped_total: 0,
        drift_inactive_no_baseline_total: 7,
        clamped_samples_total: 3,
    });
    assert_eq!(active.status, HealthStatus::Healthy);
    assert!(active.detail.contains("state=scoring_active"));
    assert!(active.detail.contains("frames_seen=1"));
    assert!(active.detail.contains("scored_samples=3"));
    assert!(active.detail.contains("emitted_verdicts=1"));
    assert!(active.detail.contains("drift_inactive_no_baseline_total=7"));
    assert!(active.detail.contains("clamped_samples_total=3"));
    assert!(active.detail.contains("last_feed_id=9"));
    assert!(active.detail.contains("last_scored_at_unix_nano=123"));

    let recovered_after_shed = scoring.health_summary(EngineHealthSnapshot {
        tracked_series: 2,
        tracked_counters: 1,
        max_series: 50_000,
        dropped_total: 2,
        drift_inactive_no_baseline_total: 7,
        clamped_samples_total: 3,
    });
    assert_eq!(recovered_after_shed.status, HealthStatus::Healthy);
    assert!(recovered_after_shed.detail.contains("state=scoring_active"));
    assert!(recovered_after_shed.detail.contains("dropped_total=2"));

    let shed = scoring.health_summary(EngineHealthSnapshot {
        tracked_series: 50_000,
        tracked_counters: 1,
        max_series: 50_000,
        dropped_total: 2,
        drift_inactive_no_baseline_total: 7,
        clamped_samples_total: 3,
    });
    assert_eq!(shed.status, HealthStatus::Degraded);
    assert!(shed.detail.contains("state=capacity_shed"));
    assert!(shed.detail.contains("dropped_total=2"));
}

#[test]
fn health_summary_reports_stalled_scoring() {
    let mut scoring = ScoringHealth::default();
    scoring.record_frame(ScoringFrameUpdate {
        feed_id: 9,
        scored_samples: 3,
        emitted_verdicts: 1,
        last_scored_at_unix_nano: 123,
    });
    scoring.last_frame_at_unix_nano = 1_000;

    let stalled = scoring.health_summary_at(
        EngineHealthSnapshot {
            tracked_series: 2,
            tracked_counters: 1,
            max_series: 50_000,
            dropped_total: 0,
            drift_inactive_no_baseline_total: 0,
            clamped_samples_total: 0,
        },
        1_000 + DEFAULT_SCORING_STALE_AFTER_NS + 1,
    );

    assert_eq!(stalled.status, HealthStatus::Degraded);
    assert!(stalled.detail.contains("state=scoring_stalled"));
    assert!(stalled.detail.contains(&format!(
        "last_frame_age_ns={}",
        DEFAULT_SCORING_STALE_AFTER_NS + 1
    )));
}

#[test]
fn health_summary_uses_configured_stale_threshold() {
    let mut scoring = ScoringHealth::default();
    scoring.set_stale_after_ns(10_000_000_000);
    scoring.record_frame(ScoringFrameUpdate {
        feed_id: 9,
        scored_samples: 3,
        emitted_verdicts: 1,
        last_scored_at_unix_nano: 123,
    });
    scoring.last_frame_at_unix_nano = 1_000;

    let engine = EngineHealthSnapshot {
        tracked_series: 2,
        tracked_counters: 1,
        max_series: 50_000,
        dropped_total: 0,
        drift_inactive_no_baseline_total: 0,
        clamped_samples_total: 0,
    };

    let active = scoring.health_summary_at(engine, 1_000 + 10_000_000_000);
    assert_eq!(active.status, HealthStatus::Healthy);
    assert!(active.detail.contains("stale_after_ns=10000000000"));

    let stalled = scoring.health_summary_at(engine, 1_000 + 10_000_000_001);
    assert_eq!(stalled.status, HealthStatus::Degraded);
    assert!(stalled.detail.contains("state=scoring_stalled"));
}

#[tokio::test]
async fn health_reports_native_telemetry_drop_counts_without_degrading() {
    let addon = AnomalyAddon::new();
    lock_scoring_health(&addon.scoring_health).record_frame(ScoringFrameUpdate {
        feed_id: 1,
        scored_samples: 1,
        emitted_verdicts: 0,
        last_scored_at_unix_nano: 1,
    });
    addon.telemetry_drops.record_no_subscriber_batch();
    addon.telemetry_drops.record_lagged_batches(2);
    addon.telemetry_drops.record_outbound_full_batch();

    let health = addon.health().await.expect("health");

    assert_eq!(health.status, HealthStatus::Healthy);
    assert_eq!(health.version, ADDON_VERSION);
    assert!(health.degradation_reason.contains("state=scoring_active"));
    assert!(health.degradation_reason.contains("total=4"));
    assert!(
        health
            .degradation_reason
            .contains("no_subscriber_batches=1")
    );
    assert!(
        health
            .degradation_reason
            .contains("lagged_receiver_batches=2")
    );
    assert!(
        health
            .degradation_reason
            .contains("outbound_full_batches=1")
    );
}

#[tokio::test]
async fn health_reports_counter_rate_drop_reason_counts() {
    let addon = AnomalyAddon::new();
    lock_scoring_health(&addon.scoring_health).record_frame(ScoringFrameUpdate {
        feed_id: 1,
        scored_samples: 1,
        emitted_verdicts: 0,
        last_scored_at_unix_nano: 1,
    });

    {
        let mut engine = lock_engine(&addon.engine);
        engine.normalize_counter("c", 1_000.0, 1_000_000_000, "a", 64);
        engine.normalize_counter("c", 10.0, 2_000_000_000, "b", 64);
    }

    let health = addon.health().await.expect("health");

    assert_eq!(health.status, HealthStatus::Healthy);
    assert!(health.degradation_reason.contains("state=scoring_active"));
    assert!(
        health
            .degradation_reason
            .contains("counter_rate_drops_total=2")
    );
    assert!(
        health
            .degradation_reason
            .contains("counter_rate_drop_warmup_total=1")
    );
    assert!(
        health
            .degradation_reason
            .contains("counter_rate_drop_reset_lineage_total=1")
    );
}
