// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! End-to-end proof that the central hour-of-week baseline keyspace
//! (`series:uid` -> `device_id`) reconciles with the edge at scoring time: the
//! key the add-on DERIVES from a live sample resolves the baseline the core
//! producer DELIVERS, so a delivered profile actually deseasonalizes the edge.

use std::collections::HashMap;

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};
use serviceradar_anomaly_core::{HOURS_PER_WEEK, SeasonalBucket};

use crate::engine::{DetectorEngine, EngineConfig, SeasonalProfile, SeriesProfile};
use crate::identity::{metric_class, seasonal_series_key, series_key_for};

/// A memory `used_percent` sample for one device, exactly as the agent's local
/// metric feed presents it to the add-on (canonical `device_id` on the resource,
/// `<class>.used_percent` metric name).
fn memory_sample() -> (MetricResource, Metric, MetricPoint) {
    let resource = MetricResource {
        agent_id: "agent-a".to_string(),
        host_id: "host-a".to_string(),
        // Canonical device-uid (DIRE) — the SAME id central stores in
        // timeseries_metrics_hourly.device_id and keys the `series:uid` profile by.
        device_id: "default:192.168.1.50".to_string(),
        partition: "default".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "memory.used_percent".to_string(),
        metric_type: "sysmon.memory".to_string(),
        unit: "%".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        value: 0.0,
        observed_at_unix_nano: 0,
        ..Default::default()
    };
    (resource, metric, point)
}

#[test]
fn edge_derives_the_central_uid_metric_seasonal_key() {
    // The crux of the alignment: the seasonal lookup key the add-on derives from a
    // sample is the canonical `<device_uid>|<metric_name>` — central's `series:uid`
    // profile keyspace — NOT the finer per-series detector key. The core producer
    // keys the delivered baseline by exactly this string.
    let (resource, metric, point) = memory_sample();
    let class = metric_class(&metric);

    let seasonal_key = seasonal_series_key(&resource, class, &metric, &point);
    assert_eq!(
        seasonal_key, "default:192.168.1.50|memory.used_percent",
        "edge must derive the central device-uid|metric key the producer delivers"
    );

    // It is deliberately distinct from the rolling-detector key, which is the very
    // reason a baseline keyed by the central keyspace would never resolve if the
    // engine looked it up by the detector key.
    let detector_key = series_key_for(&resource, &metric, &point);
    assert_ne!(
        seasonal_key, detector_key,
        "the detector key is finer than the central seasonal keyspace"
    );
}

fn flat_profile(center: f64, scale: f64, sample_count: usize) -> SeasonalProfile {
    let bucket = SeasonalBucket {
        center,
        scale,
        sample_count,
    };
    // Fill every hour-of-week bucket so any sample timestamp resolves.
    SeasonalProfile::from_buckets((0..HOURS_PER_WEEK).map(|i| (i, bucket)))
}

#[test]
fn delivered_uid_keyed_baseline_resolves_and_deseasonalizes_a_real_sample() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    };

    let (resource, metric, point) = memory_sample();
    let class = metric_class(&metric);
    let seasonal_key = seasonal_series_key(&resource, class, &metric, &point);
    let detector_key = series_key_for(&resource, &metric, &point);

    // The core producer delivered a high peak-hour baseline (center 70%, robust
    // dispersion 3) keyed by the canonical device-uid|metric — what
    // `EdgeBaseline.build` + the edge-baseline producer emit.
    let mut engine = DetectorEngine::new(cfg.clone());
    engine.set_seasonal_baselines(HashMap::from([(
        seasonal_key.clone(),
        flat_profile(70.0, 3.0, 8),
    )]));

    // A sample HIGH in absolute terms (72%) but NORMAL for its hour-of-week bucket
    // must NOT be flagged. The series is fresh, so the only ready signal is the
    // delivered seasonal one — proving the delivered baseline resolved via the key
    // the add-on derived from the sample itself.
    let normal = engine
        .evaluate_with_seasonal_key(
            &detector_key,
            &seasonal_key,
            72.0,
            point.observed_at_unix_nano,
            SeriesProfile::default(),
        )
        .expect("verdict");
    let seasonal = normal
        .signals
        .iter()
        .find(|signal| signal.name == "seasonal")
        .expect("the uid-keyed baseline must produce a seasonal signal");
    assert!(
        seasonal.ready,
        "the delivered baseline must be resolved + ready"
    );
    assert!(
        !seasonal.breached,
        "72 is normal for a center-70 hour (score {})",
        seasonal.score
    );
    assert!(
        !normal.anomalous,
        "a high-but-seasonally-normal sample must not be flagged"
    );

    // A sample that BREACHES its hour-of-week bucket (200% vs center 70) IS flagged
    // — the delivered, uid-keyed baseline drives the verdict.
    let breach = engine
        .evaluate_with_seasonal_key(
            &detector_key,
            &seasonal_key,
            200.0,
            point.observed_at_unix_nano,
            SeriesProfile::default(),
        )
        .expect("verdict");
    let seasonal = breach
        .signals
        .iter()
        .find(|signal| signal.name == "seasonal")
        .expect("seasonal signal");
    assert!(
        seasonal.breached,
        "200 breaches a center-70 bucket (score {})",
        seasonal.score
    );
    assert!(
        breach.anomalous,
        "a sample breaching its seasonal bucket must be flagged"
    );
}

#[test]
fn interface_seasonal_key_uses_exact_key_then_two_segment_fallback() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile::default();

    let mut fallback_engine = DetectorEngine::new(cfg.clone());
    fallback_engine.set_seasonal_baselines(HashMap::from([(
        "sr:router-1|ifInOctets".to_string(),
        flat_profile(100.0, 5.0, 8),
    )]));

    let fallback = fallback_engine
        .evaluate_with_seasonal_key(
            "detector-key",
            "sr:router-1|ifInOctets|7",
            102.0,
            0,
            profile,
        )
        .expect("verdict");
    assert!(
        fallback
            .signals
            .iter()
            .any(|signal| signal.name == "seasonal" && signal.ready && !signal.breached),
        "a legacy two-segment baseline must resolve as fallback for a three-segment interface key"
    );

    let mut exact_engine = DetectorEngine::new(cfg);
    exact_engine.set_seasonal_baselines(HashMap::from([
        (
            "sr:router-1|ifInOctets".to_string(),
            flat_profile(100.0, 5.0, 8),
        ),
        (
            "sr:router-1|ifInOctets|7".to_string(),
            flat_profile(200.0, 5.0, 8),
        ),
    ]));

    let exact = exact_engine
        .evaluate_with_seasonal_key(
            "detector-key",
            "sr:router-1|ifInOctets|7",
            102.0,
            0,
            profile,
        )
        .expect("verdict");
    assert!(
        exact
            .signals
            .iter()
            .any(|signal| signal.name == "seasonal" && signal.ready && signal.breached),
        "the exact three-segment interface baseline must win over the two-segment fallback"
    );
}

#[test]
fn baseline_keyed_by_the_detector_key_does_not_resolve() {
    // Negative control demonstrating the bug this alignment fixes: if the delivered
    // baseline is keyed by the finer DETECTOR series key (the old assumption), the
    // canonical seasonal key the add-on derives at scoring never matches it, so the
    // baseline is inert and the series falls back to the rolling-only path.
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    };

    let (resource, metric, point) = memory_sample();
    let class = metric_class(&metric);
    let seasonal_key = seasonal_series_key(&resource, class, &metric, &point);
    let detector_key = series_key_for(&resource, &metric, &point);
    assert_ne!(seasonal_key, detector_key);

    let mut engine = DetectorEngine::new(cfg);
    // Mis-keyed by the detector key.
    engine.set_seasonal_baselines(HashMap::from([(
        detector_key.clone(),
        flat_profile(70.0, 3.0, 8),
    )]));

    let verdict = engine
        .evaluate_with_seasonal_key(
            &detector_key,
            &seasonal_key,
            200.0,
            point.observed_at_unix_nano,
            SeriesProfile::default(),
        )
        .expect("verdict");
    assert_eq!(
        verdict.state, "insufficient_baseline",
        "a baseline keyed by the detector key never resolves the canonical lookup"
    );
    assert!(!verdict.anomalous);
}
