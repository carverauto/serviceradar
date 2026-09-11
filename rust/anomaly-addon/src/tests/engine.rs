// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Crate-internal tests for the edge detector engine: rolling/seasonal scoring,
//! counter rate normalization, episode lifecycle transitions, the saturation
//! profiles, the CUSUM drift detector, and checkpoint round-trips.

use std::collections::HashMap;

use addon_sdk::metric_pb::{Metric, MetricPoint, MetricResource};
use serviceradar_anomaly_core::{HOURS_PER_WEEK, SaturationGate, SeasonalBucket};

use crate::engine::*;
use crate::identity::{metric_class, seasonal_series_key, series_key_for};
use crate::metrics_classify::counter_series_profile;
use crate::verdict::{cusum_drift_record, verdict_record};

#[test]
fn flat_baseline_then_spike_breaches() {
    let mut engine = DetectorEngine::new(EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    });

    // Warm a steady baseline with slight noise so stddev > 0.
    for i in 0..30 {
        let v = 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 };
        let verdict = engine
            .evaluate("s1", v, i as u64, SeriesProfile::default())
            .expect("verdict");
        assert!(
            !verdict.anomalous,
            "steady samples must not confirm anomaly"
        );
    }

    // A large spike must breach.
    let verdict = engine
        .evaluate("s1", 10_000.0, 999, SeriesProfile::default())
        .expect("verdict");
    assert!(verdict.breached, "a 100x spike must breach the baseline");
}

#[test]
fn engine_score_matches_anomaly_core_robust_score() {
    // Parity: the edge engine's verdict score must equal anomaly-core's robust
    // median/MAD score over the same window — i.e. edge math == central math,
    // since both call the one shared detector crate.
    use serviceradar_anomaly_core::{RobustStats, robust_score};

    let mut engine = DetectorEngine::new(EngineConfig {
        window_size: 100,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    });
    let baseline: Vec<f64> = (0..40).map(|i| 50.0 + (i % 5) as f64).collect();
    for (i, &v) in baseline.iter().enumerate() {
        engine.evaluate("s", v, i as u64, SeriesProfile::default());
    }

    let probe = 80.0;
    let verdict = engine
        .evaluate("s", probe, 999, SeriesProfile::default())
        .expect("verdict");

    // The window at probe time is the 40 clean baseline samples; the rolling
    // signal (the only enabled one) scores via anomaly-core's robust_score. The
    // default profile applies no floors (0.0/0.0), so the edge engine and the
    // bare 5-arg robust_score must produce the identical score.
    let expected = robust_score(probe, RobustStats::from_values(&baseline), 3.0, 0.0, 0.0);
    assert!(
        (verdict.score - expected).abs() < 1e-6,
        "edge score {} must equal anomaly-core robust_score {expected}",
        verdict.score
    );
}

#[test]
fn counter_normalize_warmup_then_rate() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    // First reading is warmup: stored, no rate yet.
    assert_eq!(
        engine.normalize_counter("c", 1_000.0, 0, "boot-1", 64),
        None
    );
    // +1000 over 1s -> 1000/s.
    let rate = engine
        .normalize_counter("c", 2_000.0, 1_000_000_000, "boot-1", 64)
        .expect("rate");
    assert!((rate - 1_000.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn counter_reset_lineage_change_drops_then_resumes() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 5_000.0, 0, "boot-1", 64);
    // Different reset anchor = counter restarted; no rate across the reset.
    assert_eq!(
        engine.normalize_counter("c", 10.0, 1_000_000_000, "boot-2", 64),
        None
    );
    // Normal rate resumes on the new lineage.
    let rate = engine
        .normalize_counter("c", 110.0, 2_000_000_000, "boot-2", 64)
        .expect("rate");
    assert!((rate - 100.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn empty_anchor_does_not_clobber_known_reset_lineage() {
    // An empty (unknown) anchor must not wipe the stored anchor, else a later
    // genuine anchor change is missed and a rate is wrongly computed across a
    // reset (the "a" -> "" -> "b" flip).
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 1_000.0, 1_000_000_000, "a", 64); // warmup, anchor "a"
    // An empty-anchor reading rates normally but must PRESERVE the stored "a".
    let rate = engine
        .normalize_counter("c", 2_000.0, 2_000_000_000, "", 64)
        .expect("rate");
    assert!((rate - 1_000.0).abs() < 1e-9, "rate was {rate}");
    // A genuine new lineage "b" is now detected as a reset (drop, re-baseline),
    // because the stored anchor is still "a", not the wiped "".
    assert_eq!(
        engine.normalize_counter("c", 3_000.0, 3_000_000_000, "b", 64),
        None
    );
}

#[test]
fn counter_non_monotonic_time_keeps_baseline() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 1_000.0, 2_000_000_000, "b", 64);
    // Out-of-order (earlier) reading is dropped WITHOUT advancing state...
    assert_eq!(
        engine.normalize_counter("c", 5_000.0, 1_000_000_000, "b", 64),
        None
    );
    // ...so a later reading rates against the original t=2s / 1000 baseline.
    let rate = engine
        .normalize_counter("c", 4_000.0, 3_000_000_000, "b", 64)
        .expect("rate");
    assert!((rate - 3_000.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn counter_future_timestamp_does_not_brick_series() {
    // A single point carrying a bad far-future timestamp must not permanently
    // stall the series. Before the fix, the future ts became the baseline and
    // every later real reading was dropped as "non-monotonic" forever (and the
    // future ts was immune to eviction + survived the checkpoint).
    let mut engine = DetectorEngine::new(EngineConfig::default());
    // Warmup at t = 1s.
    engine.normalize_counter("c", 1_000.0, 1_000_000_000, "b", 64);
    // A point dated ~100h in the future stores as the baseline (over-long gap).
    let far_future = 360_000_000_000_000; // 100h in ns
    assert_eq!(
        engine.normalize_counter("c", 2_000.0, far_future, "b", 64),
        None
    );
    // A real reading at t = 2s is more than COUNTER_MAX_GAP_NS behind the poisoned
    // future baseline, so it re-anchors instead of being dropped forever.
    assert_eq!(
        engine.normalize_counter("c", 3_000.0, 2_000_000_000, "b", 64),
        None
    );
    // Recovery: the next real reading rates against the re-anchored t=2s / 3000
    // baseline. (Without the fix this is still "older" than 100h → None forever.)
    let rate = engine
        .normalize_counter("c", 4_000.0, 3_000_000_000, "b", 64)
        .expect("series should recover, not stay bricked behind the future ts");
    assert!((rate - 1_000.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn counter64_decrease_drops_but_advances_state() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 5_000.0, 0, "b", 64);
    // A 64-bit decrease is not a wrap -> drop the interval...
    assert_eq!(
        engine.normalize_counter("c", 1_000.0, 1_000_000_000, "b", 64),
        None
    );
    // ...but state advanced to 1000, so the next increase rates from there.
    let rate = engine
        .normalize_counter("c", 2_000.0, 2_000_000_000, "b", 64)
        .expect("rate");
    assert!((rate - 1_000.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn counter32_wrap_is_salvaged() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    let near_max = COUNTER32_MODULUS - 100.0;
    engine.normalize_counter("c", near_max, 0, "b", 32);
    // Wraps to 50 one second later: delta = 2^32 - near_max + 50 = 150.
    let rate = engine
        .normalize_counter("c", 50.0, 1_000_000_000, "b", 32)
        .expect("rate");
    assert!((rate - 150.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn counter32_wrap_drops_when_max_rate_rules_it_out() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    let near_max = COUNTER32_MODULUS - 100.0;
    engine.normalize_counter("c", near_max, 0, "b", 32);
    // The wrapped delta would be 150/s, above the per-sample physical max.
    assert_eq!(
        engine.normalize_counter_with_max_rate("c", 50.0, 1_000_000_000, "b", 32, Some(100.0),),
        None
    );
    // State still advances to the dropped point, so the next increase rates
    // from 50 rather than repeatedly re-evaluating the same wrap.
    let rate = engine
        .normalize_counter("c", 75.0, 2_000_000_000, "b", 32)
        .expect("rate");
    assert!((rate - 25.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn counter_increase_drops_when_max_rate_rules_it_out() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 1_000.0, 0, "b", 64);

    assert_eq!(
        engine.normalize_counter_with_max_rate("c", 10_000.0, 1_000_000_000, "b", 64, Some(100.0),),
        None
    );

    // State still advances to the dropped point, so the next plausible
    // increase rates from 10000 rather than repeatedly scoring the jump.
    let rate = engine
        .normalize_counter_with_max_rate("c", 10_100.0, 2_000_000_000, "b", 64, Some(100.0))
        .expect("rate");
    assert!((rate - 100.0).abs() < 1e-9, "rate was {rate}");
}

#[test]
fn plausible_counter_delta_rejects_non_positive_elapsed() {
    assert_eq!(plausible_counter_delta(100.0, 0.0, None), None);
    assert_eq!(plausible_counter_delta(100.0, -1.0, None), None);
    assert_eq!(plausible_counter_delta(100.0, 0.0, Some(1_000.0)), None);
    assert_eq!(plausible_counter_delta(100.0, -1.0, Some(1_000.0)), None);
}

#[test]
fn unknown_width_decrease_drops() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 5_000.0, 0, "b", 0);
    assert_eq!(
        engine.normalize_counter_with_max_rate(
            "c",
            1_000.0,
            1_000_000_000,
            "b",
            0,
            Some(COUNTER32_MODULUS),
        ),
        None
    );
}

#[test]
fn counter_drop_counts_track_reason_totals() {
    let mut engine = DetectorEngine::new(EngineConfig::default());

    assert_eq!(engine.normalize_counter("invalid", -1.0, 0, "a", 64), None);
    engine.normalize_counter("c", 1_000.0, 1_000_000_000, "a", 64);
    engine.normalize_counter("c", 10.0, 2_000_000_000, "b", 64);
    engine.normalize_counter("c", 20.0, 1_500_000_000, "b", 64);
    engine.normalize_counter("c", 30.0, 7_203_000_000_000, "b", 64);
    engine.normalize_counter("c", 1.0, 7_204_000_000_000, "b", 64);

    let counts = engine.counter_drop_counts;
    assert_eq!(counts.invalid_sample, 1);
    assert_eq!(counts.warmup, 1);
    assert_eq!(counts.reset_lineage, 1);
    assert_eq!(counts.non_monotonic_time, 1);
    assert_eq!(counts.gap, 1);
    assert_eq!(counts.implausible_delta, 1);
    assert_eq!(counts.total(), 6);
}

#[test]
fn counter_gap_too_large_drops() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.normalize_counter("c", 1_000.0, 0, "b", 64);
    let three_hours = 3 * 60 * 60 * 1_000_000_000_u64;
    assert_eq!(
        engine.normalize_counter("c", 9_999.0, three_hours, "b", 64),
        None
    );
}

#[test]
fn checkpoint_round_trip_rewarms_baseline_and_counter() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 100,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg.clone());
    for i in 0..30 {
        let v = 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 };
        engine.evaluate("s1", v, i as u64, SeriesProfile::default());
    }
    // Prime a counter series too.
    engine.normalize_counter("c1", 1_000.0, 10, "boot", 64);

    let checkpoint = engine.export_checkpoint();

    // A fresh engine reseeded from the checkpoint (nothing stale: huge max_age).
    let mut restored = DetectorEngine::new(cfg);
    let n = restored.restore_checkpoint(checkpoint, 100, u64::MAX);
    assert_eq!(n, 1);
    assert_eq!(restored.series_count(), 1);

    // The reseeded baseline scores a spike immediately — no re-warm storm.
    let verdict = restored
        .evaluate("s1", 10_000.0, 999, SeriesProfile::default())
        .expect("verdict");
    assert!(verdict.breached, "reseeded baseline must score a spike");

    // The counter state survived: the next reading rates (it is not warmup).
    let rate = restored.normalize_counter("c1", 2_000.0, 1_000_000_010, "boot", 64);
    assert!(
        rate.is_some(),
        "counter state should re-warm, not re-warmup"
    );
}

#[test]
fn checkpoint_skips_stale_series() {
    let mut engine = DetectorEngine::new(EngineConfig::default());
    engine.evaluate("old", 5.0, 0, SeriesProfile::default());
    engine.evaluate("old", 6.0, 1, SeriesProfile::default());
    let checkpoint = engine.export_checkpoint();

    // `now` far ahead with a small max_age: the series is stale and skipped.
    let mut restored = DetectorEngine::new(EngineConfig::default());
    let n = restored.restore_checkpoint(checkpoint, 1_000_000_000_000, 1_000);
    assert_eq!(n, 0);
    assert_eq!(restored.series_count(), 0);
}

#[test]
fn transition_state_round_trips_through_checkpoint() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 10,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg.clone());

    for i in 0..20 {
        let verdict = engine
            .evaluate_transition("series-a", 100.0, i, SeriesProfile::default())
            .expect("verdict");
        assert_eq!(verdict.transition, AnomalyTransition::None);
    }

    let pending = engine
        .evaluate_transition("series-a", 1_000.0, 21, SeriesProfile::default())
        .expect("pending verdict");
    assert_eq!(pending.verdict.state, "pending_anomaly");
    assert_eq!(pending.transition, AnomalyTransition::None);

    let opened = engine
        .evaluate_transition("series-a", 1_000.0, 22, SeriesProfile::default())
        .expect("open verdict");
    assert_eq!(opened.verdict.state, "anomalous");
    assert_eq!(opened.transition, AnomalyTransition::Open);

    let checkpoint = engine.export_checkpoint();
    let snapshot = checkpoint.series.first().expect("series checkpoint");
    assert!(
        !snapshot.raw_tail.is_empty(),
        "raw adoption ring is checkpointed"
    );
    let mut restored = DetectorEngine::new(cfg);
    assert_eq!(restored.restore_checkpoint(checkpoint, 23, u64::MAX), 1);

    let clean_pending_clear = restored
        .evaluate_transition("series-a", 100.0, 23, SeriesProfile::default())
        .expect("first clean verdict");
    assert_eq!(clean_pending_clear.verdict.state, "clean");
    assert_eq!(
        clean_pending_clear.transition,
        AnomalyTransition::None,
        "a single clean slot should not clear an active anomaly"
    );

    let cleared = restored
        .evaluate_transition("series-a", 100.0, 24, SeriesProfile::default())
        .expect("clear verdict");
    assert_eq!(cleared.verdict.state, "clean");
    assert_eq!(cleared.transition, AnomalyTransition::Clear);
}

#[test]
fn rolling_spike_adopts_a_stable_regime_and_rebuilds_the_baseline() {
    let cfg = EngineConfig {
        window_size: 10,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        spike_adopt_after_samples: 6,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        spike_adopt_after_samples: Some(6),
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for sample in 0..10 {
        engine
            .evaluate_transition("regime", 100.0, sample, profile)
            .expect("warm-up verdict");
    }

    let opened = engine
        .evaluate_transition("regime", 1_000.0, 10, profile)
        .expect("open verdict");
    assert_eq!(opened.transition, AnomalyTransition::Open);

    let mut adopted = None;
    for sample in 11..20 {
        let verdict = engine
            .evaluate_transition("regime", 1_000.0, sample, profile)
            .expect("sustained verdict");
        if verdict.transition == AnomalyTransition::Clear {
            adopted = Some(verdict);
            break;
        }
    }

    let adopted = adopted.expect("stable regime must be adopted");
    assert_eq!(adopted.clear_reason, Some(SpikeClearReason::Adopted));
    assert_eq!(adopted.verdict.next_consecutive_anomalous, 0);
    assert!(
        engine
            .series
            .get("regime")
            .expect("series state")
            .window_tail
            .iter()
            .filter(|value| **value >= 1_000.0)
            .count()
            >= 6,
        "adoption replaces the winsorized tail with recent raw observations"
    );

    let new_breach = engine
        .evaluate_transition("regime", 3_000.0, 21, profile)
        .expect("post-adoption verdict");
    assert_eq!(
        new_breach.transition,
        AnomalyTransition::Open,
        "a new breach after adoption must not reuse the prior flap episode"
    );
}

#[test]
fn rolling_spike_does_not_adopt_across_alternating_rebreaches() {
    let cfg = EngineConfig {
        window_size: 10,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 2,
        max_series: 10,
        spike_adopt_after_samples: 4,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        spike_adopt_after_samples: Some(4),
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for sample in 0..10 {
        engine
            .evaluate_transition("oscillating", 100.0, sample, profile)
            .expect("warm-up verdict");
    }

    assert_eq!(
        engine
            .evaluate_transition("oscillating", 10_000.0, 10, profile)
            .expect("pending verdict")
            .transition,
        AnomalyTransition::None
    );
    assert_eq!(
        engine
            .evaluate_transition("oscillating", 10_000.0, 11, profile)
            .expect("open verdict")
            .transition,
        AnomalyTransition::Open
    );

    let mut adopted = false;
    for (sample, value) in [
        (12, 100.0),
        (13, 10_000.0),
        (14, 100.0),
        (15, 10_000.0),
        (16, 100.0),
        (17, 10_000.0),
    ] {
        let verdict = engine
            .evaluate_transition("oscillating", value, sample, profile)
            .expect("oscillating verdict");

        if verdict.transition == AnomalyTransition::Clear {
            adopted = verdict.clear_reason == Some(SpikeClearReason::Adopted);
            break;
        }
    }

    assert!(
        !adopted,
        "alternating breach/clean samples must not accumulate into a false baseline adoption"
    );
}

#[test]
fn saturated_utilization_does_not_self_clear_after_winsorization() {
    let cfg = EngineConfig {
        window_size: 6,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        spike_adopt_after_samples: 100,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        min_std_floor: 1.0,
        min_cv: 0.01,
        saturation_gate: Some(SaturationGate {
            min_value: 85.0,
            directional: true,
        }),
        spike_adopt_after_samples: Some(100),
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for sample in 0..10 {
        engine
            .evaluate_transition("cpu", 50.0, sample, profile)
            .expect("warm-up verdict");
    }

    assert_eq!(
        engine
            .evaluate_transition("cpu", 100.0, 10, profile)
            .expect("open verdict")
            .transition,
        AnomalyTransition::Open
    );

    for sample in 11..40 {
        let verdict = engine
            .evaluate_transition("cpu", 100.0, sample, profile)
            .expect("saturated verdict");
        assert_ne!(
            verdict.transition,
            AnomalyTransition::Clear,
            "a sustained 100% utilization episode must not self-clear at sample {sample}"
        );
    }
}

#[test]
fn high_normal_utilization_recovers_when_it_returns_to_its_rolling_center() {
    let cfg = EngineConfig {
        window_size: 6,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        spike_adopt_after_samples: 100,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        min_std_floor: 1.0,
        min_cv: 0.01,
        saturation_gate: Some(SaturationGate {
            min_value: 80.0,
            directional: true,
        }),
        spike_adopt_after_samples: Some(100),
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for sample in 0..10 {
        engine
            .evaluate_transition("high-normal", 85.0, sample, profile)
            .expect("warm-up verdict");
    }

    assert_eq!(
        engine
            .evaluate_transition("high-normal", 98.0, 10, profile)
            .expect("open verdict")
            .transition,
        AnomalyTransition::Open
    );

    let recovered = engine
        .evaluate_transition("high-normal", 85.0, 11, profile)
        .expect("recovery verdict");
    assert_eq!(recovered.transition, AnomalyTransition::Clear);
    assert_eq!(recovered.clear_reason, Some(SpikeClearReason::Recovered));
}

#[test]
fn saturated_spike_episode_emits_heartbeat_updates() {
    const SEC: u64 = 1_000_000_000;
    let cfg = EngineConfig {
        window_size: 6,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        spike_adopt_after_samples: 100,
        episode_update_interval_secs: 1,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        min_std_floor: 1.0,
        min_cv: 0.01,
        saturation_gate: Some(SaturationGate {
            min_value: 85.0,
            directional: true,
        }),
        spike_adopt_after_samples: Some(100),
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for sample in 0..10 {
        engine
            .evaluate_transition("heartbeat", 50.0, sample * SEC, profile)
            .expect("warm-up verdict");
    }

    assert_eq!(
        engine
            .evaluate_transition("heartbeat", 100.0, 10 * SEC, profile)
            .expect("open verdict")
            .transition,
        AnomalyTransition::Open
    );

    let heartbeat = engine
        .evaluate_transition("heartbeat", 100.0, 12 * SEC, profile)
        .expect("heartbeat verdict");
    assert_eq!(heartbeat.transition, AnomalyTransition::Update);
    assert_eq!(heartbeat.update_reason, Some(SpikeUpdateReason::Heartbeat));
    assert!(heartbeat.episode.is_some());
}

#[test]
fn medium_only_severity_band_keeps_high_threshold_above_medium() {
    assert_eq!(
        SeverityPolicy {
            medium_at: Some(10.0),
            high_at: None,
            ..SeverityPolicy::default()
        }
        .bands(),
        (10.0, 14.0)
    );
}

#[test]
fn rolling_spike_reopen_reuses_episode_and_merges_clear_churn() {
    const SEC: u64 = 1_000_000_000;
    let cfg = EngineConfig {
        window_size: 10,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        reopen_cooldown_secs: 10,
        spike_adopt_after_samples: 100,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        spike_adopt_after_samples: Some(100),
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for sample in 0..10 {
        engine
            .evaluate_transition("flap", 100.0, sample * SEC, profile)
            .expect("warm-up verdict");
    }

    let opened = engine
        .evaluate_transition("flap", 1_000.0, 10 * SEC, profile)
        .expect("open verdict");
    let started_at = opened.episode.expect("open episode").started_at_unix_nano;
    assert_eq!(opened.transition, AnomalyTransition::Open);

    let cleared = engine
        .evaluate_transition("flap", 100.0, 11 * SEC, profile)
        .expect("clear verdict");
    assert_eq!(cleared.transition, AnomalyTransition::Clear);

    let reopened = engine
        .evaluate_transition("flap", 1_000.0, 12 * SEC, profile)
        .expect("reopen verdict");
    assert_eq!(reopened.transition, AnomalyTransition::Update);
    assert_eq!(reopened.update_reason, Some(SpikeUpdateReason::Flapping));
    assert_eq!(reopened.reopen_count, 1);
    assert_eq!(
        reopened
            .episode
            .expect("reopen episode")
            .started_at_unix_nano,
        started_at
    );

    let swallowed = engine
        .evaluate_transition("flap", 100.0, 13 * SEC, profile)
        .expect("inside-window clear verdict");
    assert_eq!(swallowed.transition, AnomalyTransition::None);

    let flap_merged = engine
        .evaluate_transition("flap", 100.0, 23 * SEC, profile)
        .expect("post-window clear verdict");
    assert_eq!(flap_merged.transition, AnomalyTransition::Clear);
    assert_eq!(flap_merged.clear_reason, Some(SpikeClearReason::FlapMerged));
    assert_eq!(
        flap_merged
            .episode
            .expect("merged episode")
            .started_at_unix_nano,
        started_at
    );
}

#[test]
fn capacity_cap_drops_new_series() {
    let mut engine = DetectorEngine::new(EngineConfig {
        max_series: 2,
        ..EngineConfig::default()
    });
    assert!(
        engine
            .evaluate("a", 1.0, 1, SeriesProfile::default())
            .is_some()
    );
    assert!(
        engine
            .evaluate("b", 1.0, 1, SeriesProfile::default())
            .is_some()
    );
    // Third distinct series is dropped at the cap.
    assert!(
        engine
            .evaluate("c", 1.0, 1, SeriesProfile::default())
            .is_none()
    );
    assert_eq!(engine.dropped_at_capacity, 1);
    // Existing series still evaluate.
    assert!(
        engine
            .evaluate("a", 2.0, 2, SeriesProfile::default())
            .is_some()
    );
}

#[test]
fn counter_cap_drops_new_counter_series() {
    let mut engine = DetectorEngine::new(EngineConfig {
        max_series: 1,
        ..EngineConfig::default()
    });

    assert_eq!(engine.normalize_counter("c1", 1_000.0, 1, "boot", 64), None);
    assert_eq!(engine.counter_count(), 1);

    assert_eq!(engine.normalize_counter("c2", 2_000.0, 2, "boot", 64), None);
    assert_eq!(engine.counter_count(), 1);
    assert_eq!(engine.dropped_at_capacity, 1);

    let checkpoint = engine.export_checkpoint();
    assert_eq!(checkpoint.counters.len(), 1);
    assert_eq!(checkpoint.counters[0].series_key, "c1");
}

#[test]
fn restore_checkpoint_caps_counter_state() {
    let checkpoint = EngineCheckpoint {
        series: Vec::new(),
        counters: vec![
            CounterCheckpoint {
                series_key: "c1".to_string(),
                value: 1_000.0,
                timestamp: 1,
                reset_anchor: "boot".to_string(),
            },
            CounterCheckpoint {
                series_key: "c2".to_string(),
                value: 2_000.0,
                timestamp: 2,
                reset_anchor: "boot".to_string(),
            },
            CounterCheckpoint {
                series_key: "c3".to_string(),
                value: 3_000.0,
                timestamp: 3,
                reset_anchor: "boot".to_string(),
            },
        ],
    };
    let mut restored = DetectorEngine::new(EngineConfig {
        max_series: 2,
        ..EngineConfig::default()
    });

    assert_eq!(restored.restore_checkpoint(checkpoint, 4, u64::MAX), 0);
    assert_eq!(restored.counter_count(), 2);
    assert!(!restored.counters.contains_key("c1"));
    assert!(restored.counters.contains_key("c2"));
    assert!(restored.counters.contains_key("c3"));
}

#[test]
fn restore_checkpoint_caps_series_state_by_freshness() {
    let checkpoint = EngineCheckpoint {
        series: vec![
            SeriesCheckpoint {
                series_key: "oldest".to_string(),
                window_tail: vec![1.0],
                consecutive_anomalous: 0,
                consecutive_clean: 0,
                active_anomalous: false,
                pending_episode_started_at_unix_nano: None,
                pending_episode_peak_value: None,
                pending_episode_peak_at_unix_nano: None,
                active_episode_started_at_unix_nano: None,
                active_episode_peak_value: None,
                active_episode_peak_at_unix_nano: None,
                raw_tail: Vec::new(),
                spike_active_samples: 0,
                spike_last_emitted_at_unix_nano: None,
                spike_last_cleared_at_unix_nano: None,
                spike_last_episode_started_at_unix_nano: None,
                spike_reopen_count: 0,
                aggregation_slot_start_unix_nano: None,
                aggregation_slot_value: None,
                aggregation_slot_peak_at_unix_nano: None,
                cusum_anchor_mean: None,
                cusum_anchor_scale: None,
                cusum_anchor_captured_at_unix_nano: None,
                cusum_pos: None,
                cusum_neg: None,
                cusum_run_samples: 0,
                cusum_pending_direction: None,
                cusum_pending_samples: 0,
                drift_active: false,
                drift_active_direction: None,
                drift_episode_started_at_unix_nano: None,
                drift_episode_peak_value: None,
                drift_episode_peak_at_unix_nano: None,
                drift_episode_peak_shift: 0.0,
                drift_peak_severity_band: 0,
                drift_active_samples: 0,
                drift_clear_samples: 0,
                drift_last_emitted_at_unix_nano: None,
                drift_last_cleared_at_unix_nano: None,
                drift_last_episode_started_at_unix_nano: None,
                drift_reopen_count: 0,
                last_non_clear_emitted_at_unix_nano: None,
                last_observed_at_unix_nano: 1,
            },
            SeriesCheckpoint {
                series_key: "freshest".to_string(),
                window_tail: vec![3.0],
                consecutive_anomalous: 0,
                consecutive_clean: 0,
                active_anomalous: false,
                pending_episode_started_at_unix_nano: None,
                pending_episode_peak_value: None,
                pending_episode_peak_at_unix_nano: None,
                active_episode_started_at_unix_nano: None,
                active_episode_peak_value: None,
                active_episode_peak_at_unix_nano: None,
                raw_tail: Vec::new(),
                spike_active_samples: 0,
                spike_last_emitted_at_unix_nano: None,
                spike_last_cleared_at_unix_nano: None,
                spike_last_episode_started_at_unix_nano: None,
                spike_reopen_count: 0,
                aggregation_slot_start_unix_nano: None,
                aggregation_slot_value: None,
                aggregation_slot_peak_at_unix_nano: None,
                cusum_anchor_mean: None,
                cusum_anchor_scale: None,
                cusum_anchor_captured_at_unix_nano: None,
                cusum_pos: None,
                cusum_neg: None,
                cusum_run_samples: 0,
                cusum_pending_direction: None,
                cusum_pending_samples: 0,
                drift_active: false,
                drift_active_direction: None,
                drift_episode_started_at_unix_nano: None,
                drift_episode_peak_value: None,
                drift_episode_peak_at_unix_nano: None,
                drift_episode_peak_shift: 0.0,
                drift_peak_severity_band: 0,
                drift_active_samples: 0,
                drift_clear_samples: 0,
                drift_last_emitted_at_unix_nano: None,
                drift_last_cleared_at_unix_nano: None,
                drift_last_episode_started_at_unix_nano: None,
                drift_reopen_count: 0,
                last_non_clear_emitted_at_unix_nano: None,
                last_observed_at_unix_nano: 3,
            },
            SeriesCheckpoint {
                series_key: "middle".to_string(),
                window_tail: vec![2.0],
                consecutive_anomalous: 0,
                consecutive_clean: 0,
                active_anomalous: false,
                pending_episode_started_at_unix_nano: None,
                pending_episode_peak_value: None,
                pending_episode_peak_at_unix_nano: None,
                active_episode_started_at_unix_nano: None,
                active_episode_peak_value: None,
                active_episode_peak_at_unix_nano: None,
                raw_tail: Vec::new(),
                spike_active_samples: 0,
                spike_last_emitted_at_unix_nano: None,
                spike_last_cleared_at_unix_nano: None,
                spike_last_episode_started_at_unix_nano: None,
                spike_reopen_count: 0,
                aggregation_slot_start_unix_nano: None,
                aggregation_slot_value: None,
                aggregation_slot_peak_at_unix_nano: None,
                cusum_anchor_mean: None,
                cusum_anchor_scale: None,
                cusum_anchor_captured_at_unix_nano: None,
                cusum_pos: None,
                cusum_neg: None,
                cusum_run_samples: 0,
                cusum_pending_direction: None,
                cusum_pending_samples: 0,
                drift_active: false,
                drift_active_direction: None,
                drift_episode_started_at_unix_nano: None,
                drift_episode_peak_value: None,
                drift_episode_peak_at_unix_nano: None,
                drift_episode_peak_shift: 0.0,
                drift_peak_severity_band: 0,
                drift_active_samples: 0,
                drift_clear_samples: 0,
                drift_last_emitted_at_unix_nano: None,
                drift_last_cleared_at_unix_nano: None,
                drift_last_episode_started_at_unix_nano: None,
                drift_reopen_count: 0,
                last_non_clear_emitted_at_unix_nano: None,
                last_observed_at_unix_nano: 2,
            },
        ],
        counters: Vec::new(),
    };
    let mut restored = DetectorEngine::new(EngineConfig {
        max_series: 2,
        ..EngineConfig::default()
    });

    assert_eq!(restored.restore_checkpoint(checkpoint, 4, u64::MAX), 2);
    assert_eq!(restored.series_count(), 2);
    assert!(!restored.series.contains_key("oldest"));
    assert!(restored.series.contains_key("middle"));
    assert!(restored.series.contains_key("freshest"));
}

#[test]
fn stale_state_eviction_reclaims_capacity_for_fresh_series_and_counter() {
    let mut engine = DetectorEngine::new(EngineConfig {
        max_series: 1,
        ..EngineConfig::default()
    });
    assert!(
        engine
            .evaluate("old-series", 1.0, 0, SeriesProfile::default())
            .is_some()
    );
    assert_eq!(
        engine.normalize_counter("old-counter", 1_000.0, 0, "boot", 64),
        None
    );
    assert_eq!(engine.series_count(), 1);
    assert_eq!(engine.counter_count(), 1);

    let fresh_ts = STATE_EVICTION_MAX_AGE_NS + 1;
    assert!(
        engine
            .evaluate("fresh-series", 2.0, fresh_ts, SeriesProfile::default())
            .is_some(),
        "stale detector state should be evicted before dropping a fresh series"
    );
    assert_eq!(engine.series_count(), 1);
    assert_eq!(engine.counter_count(), 0);

    assert_eq!(
        engine.normalize_counter("fresh-counter", 2_000.0, fresh_ts, "boot", 64),
        None,
        "first fresh counter reading should be admitted as warmup"
    );
    assert_eq!(engine.counter_count(), 1);
    assert_eq!(engine.dropped_at_capacity, 0);
}

/// The disk saturation profile the add-on assigns to a `sysmon.disk` series:
/// 1-point std floor, 5% CV floor, directional gate above 80%. Kept in the
/// test so the fidelity behavior is pinned even if the add-on defaults move.
fn disk_profile() -> SeriesProfile {
    SeriesProfile {
        min_std_floor: 1.0,
        min_cv: 0.05,
        saturation_gate: Some(SaturationGate {
            directional: true,
            min_value: 80.0,
        }),
        evaluation_interval_ns: None,
        ..SeriesProfile::default()
    }
}

fn cpu_profile() -> SeriesProfile {
    SeriesProfile {
        min_std_floor: 5.0,
        min_cv: 0.10,
        saturation_gate: Some(SaturationGate {
            directional: true,
            min_value: 85.0,
        }),
        evaluation_interval_ns: Some(30 * 1_000_000_000),
        ..SeriesProfile::default()
    }
}

fn always_drift_profile() -> SeriesProfile {
    SeriesProfile {
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    }
}

fn seasonal_only_drift_profile() -> SeriesProfile {
    SeriesProfile {
        drift_mode: DriftMode::DeseasonalizedOnly,
        ..SeriesProfile::default()
    }
}

fn flat_cfg() -> EngineConfig {
    EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        ..EngineConfig::default()
    }
}

#[test]
fn benign_disk_jitter_never_breaches() {
    // Live false-fire: disk used_percent hovering at ~1.36% with ~0.01 jitter.
    // The std floor tames the denominator AND the saturation gate's 80% floor
    // suppresses any breach at this benign level. No sample may breach.
    let mut engine = DetectorEngine::new(flat_cfg());
    for i in 0..40 {
        let v = 1.36 + if i % 2 == 0 { 0.01 } else { -0.01 };
        let verdict = engine
            .evaluate("disk", v, i as u64, disk_profile())
            .expect("verdict");
        assert!(
            !verdict.breached,
            "benign disk jitter at sample {i} must never breach (got score {})",
            verdict.score
        );
    }
    // Even a sharp *relative* jump that is still absolutely benign (1.36% ->
    // 5%) is suppressed by the 80% absolute floor.
    let verdict = engine
        .evaluate("disk", 5.0, 100, disk_profile())
        .expect("verdict");
    assert!(
        !verdict.breached,
        "a still-benign 5% disk must not breach (absolute floor), score {}",
        verdict.score
    );
}

#[test]
fn benign_memory_and_percore_cpu_never_breach() {
    // Memory ~6.4% and a CPU core briefly at 18%: both benign, both below
    // their absolute floors. Neither may breach.
    let mut mem_engine = DetectorEngine::new(flat_cfg());
    let mem_profile = disk_profile(); // same shape (80% floor) as memory
    for i in 0..40 {
        let v = 6.4 + if i % 2 == 0 { 0.05 } else { -0.05 };
        assert!(
            !mem_engine
                .evaluate("mem", v, i as u64, mem_profile)
                .expect("verdict")
                .breached,
            "benign memory must not breach"
        );
    }

    let mut cpu_engine = DetectorEngine::new(flat_cfg());
    // Warm a low core, then a brief jump to 18% — well under the 85% floor.
    for i in 0..40 {
        let v = 4.0 + if i % 2 == 0 { 1.0 } else { -1.0 };
        cpu_engine.evaluate("core0", v, i as u64, cpu_profile());
    }
    let verdict = cpu_engine
        .evaluate("core0", 18.0, 100, cpu_profile())
        .expect("verdict");
    assert!(
        !verdict.breached,
        "a core briefly at 18% must not page (absolute floor), score {}",
        verdict.score
    );
}

#[test]
fn disk_rising_to_saturation_still_breaches() {
    // No false negative: a disk genuinely climbing toward full clears both the
    // std floor and the 80% absolute floor, and the move is upward, so the
    // directional gate lets it breach.
    let mut engine = DetectorEngine::new(flat_cfg());
    for i in 0..40 {
        let v = 40.0 + if i % 2 == 0 { 0.5 } else { -0.5 };
        engine.evaluate("disk", v, i as u64, disk_profile());
    }
    let verdict = engine
        .evaluate("disk", 95.0, 100, disk_profile())
        .expect("verdict");
    assert!(
        verdict.breached,
        "a disk climbing to 95% must still breach, score {}",
        verdict.score
    );
}

#[test]
fn gauge_downward_excursion_is_suppressed_but_upward_fires() {
    // Directional gate: from a steady high level, a large *drop* never breaches
    // (utilization easing is not an incident), while a large *rise* toward the
    // ceiling does. Both excursions are large-z; only direction differs.
    let mut down = DetectorEngine::new(flat_cfg());
    for i in 0..40 {
        let v = 92.0 + if i % 2 == 0 { 0.5 } else { -0.5 };
        down.evaluate("disk", v, i as u64, disk_profile());
    }
    // Drop to 75% then back is suppressed; even 82% (above the 80% floor, so
    // the *direction* gate is what blocks it) downward => suppressed.
    let drop = down.evaluate("disk", 82.0, 100, disk_profile()).expect("v");
    assert!(
        !drop.breached,
        "a downward disk move must not breach (directional), score {}",
        drop.score
    );

    // Upward from a lower, tight baseline to the ceiling clears the floored
    // denominator and the direction gate.
    let mut up = DetectorEngine::new(flat_cfg());
    for i in 0..40 {
        let v = 85.0 + if i % 2 == 0 { 0.2 } else { -0.2 };
        up.evaluate("disk", v, i as u64, disk_profile());
    }
    let rise = up.evaluate("disk", 100.0, 100, disk_profile()).expect("v");
    assert!(
        rise.breached,
        "an upward disk move toward full must breach, score {}",
        rise.score
    );
}

#[test]
fn counter_series_stays_purely_z_based() {
    // A rate-normalized counter / interface series uses the DEFAULT profile
    // (no gate, no floors). A real z-spike — in EITHER direction and at ANY
    // magnitude — must still breach: the saturation gate must not touch it.
    let mut engine = DetectorEngine::new(flat_cfg());
    for i in 0..40 {
        let v = 100.0 + if i % 2 == 0 { 1.0 } else { -1.0 };
        engine.evaluate("rate", v, i as u64, SeriesProfile::default());
    }
    // A flood (10x) on a low-magnitude rate (no absolute ceiling) breaches.
    let verdict = engine
        .evaluate("rate", 1_000.0, 100, SeriesProfile::default())
        .expect("verdict");
    assert!(
        verdict.breached,
        "a real rate flood must still breach a counter series, score {}",
        verdict.score
    );
}

#[test]
fn std_floor_suppresses_wiggle_but_not_a_real_spike() {
    // A near-constant non-gauge series (default profile carries no floor) would
    // over-fire, so this exercises the floor via a global override: a tiny
    // wiggle is tamed, but a genuinely large spike on the SAME series still
    // breaches (the floor lifts the denominator, it does not cap the score).
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        min_std_floor: Some(1.0),
        min_cv: Some(0.05),
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    // Near-constant ~50.0 with sub-0.05 jitter -> tiny nonzero stddev.
    for i in 0..40 {
        let v = 50.0 + if i % 2 == 0 { 0.02 } else { -0.02 };
        let verdict = engine
            .evaluate("flat", v, i as u64, SeriesProfile::default())
            .expect("verdict");
        assert!(
            !verdict.breached,
            "a sub-floor wiggle must not breach (sample {i}), score {}",
            verdict.score
        );
    }
    // A genuine 50 -> 200 spike still clears the floored denominator.
    let verdict = engine
        .evaluate("flat", 200.0, 100, SeriesProfile::default())
        .expect("verdict");
    assert!(
        verdict.breached,
        "a real spike must still breach despite the floor, score {}",
        verdict.score
    );
}

#[test]
fn delivered_seasonal_baseline_deseasonalizes_against_hour_of_week() {
    // The whole point of pushing the central hour-of-week baseline core->edge:
    // a sample that is HIGH in absolute terms but NORMAL for its hour-of-week
    // bucket must NOT be flagged, while a sample that breaches its bucket IS —
    // i.e. the delivered `seasonal_baseline` actually feeds the verdict.
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    };

    // This series' peak-hour center is HIGH (70%) with a robust dispersion of
    // 3 in metric units, backed by 8 weeks of history. Fill every hour-of-week
    // bucket so any sample timestamp resolves to a usable baseline.
    let bucket = SeasonalBucket {
        center: 70.0,
        scale: 3.0,
        sample_count: 8,
    };
    let profile = SeasonalProfile::from_buckets((0..HOURS_PER_WEEK).map(|i| (i, bucket)));

    // 1) Back-compat / contrast: with NO baseline delivered, a fresh series has
    //    no ready signal, so even a large value is not confirmed anomalous. The
    //    delivered baseline is what enables the seasonal detection below.
    let mut bare = DetectorEngine::new(cfg.clone());
    let bare_verdict = bare
        .evaluate("s", 200.0, 0, SeriesProfile::default())
        .expect("verdict");
    assert_eq!(bare_verdict.state, "insufficient_baseline");
    assert!(!bare_verdict.anomalous, "no baseline -> nothing to breach");

    let mut engine = DetectorEngine::new(cfg);
    engine.set_seasonal_baselines(HashMap::from([
        ("s".to_string(), profile.clone()),
        ("s2".to_string(), profile),
    ]));
    assert_eq!(engine.seasonal_series_count(), 2);

    // 2) A sample HIGH in absolute terms (72%) but NORMAL for its hour-of-week
    //    bucket (center 70) must NOT be flagged. The series is fresh, so the
    //    only ready signal is the delivered seasonal one.
    let normal = engine
        .evaluate("s", 72.0, 0, SeriesProfile::default())
        .expect("verdict");
    let seasonal = normal
        .signals
        .iter()
        .find(|signal| signal.name == "seasonal")
        .expect("delivered baseline must produce a seasonal signal");
    assert!(
        seasonal.ready,
        "the delivered baseline must make the seasonal signal ready"
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

    // 3) A sample that BREACHES its hour-of-week bucket (200% vs center 70) IS
    //    flagged — the delivered seasonal_baseline drives the verdict.
    let breach = engine
        .evaluate("s2", 200.0, 0, SeriesProfile::default())
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
fn seasonal_baseline_ignored_when_bucket_history_too_thin() {
    // A bucket backed by too little history (below min_bucket_samples) is not
    // trusted: the series stays on the rolling-only path (back-compat), so a
    // fresh series with no rolling window yields no ready signal.
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    };
    let thin = SeasonalBucket {
        center: 70.0,
        scale: 3.0,
        sample_count: 1, // below DEFAULT_SEASONAL_MIN_BUCKET_SAMPLES (4)
    };
    let profile = SeasonalProfile::from_buckets((0..HOURS_PER_WEEK).map(|i| (i, thin)));

    let mut engine = DetectorEngine::new(cfg);
    engine.set_seasonal_baselines(HashMap::from([("s".to_string(), profile)]));

    let verdict = engine
        .evaluate("s", 200.0, 0, SeriesProfile::default())
        .expect("verdict");
    assert_eq!(
        verdict.state, "insufficient_baseline",
        "a thin-history bucket must not feed the seasonal signal"
    );
    assert!(!verdict.anomalous);
}

#[test]
fn global_floor_override_only_raises_never_lowers_gauge_default() {
    // The global override takes a max with the per-class floor: a tiny override
    // cannot weaken the disk gauge's 1.0 built-in floor.
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 5,
        n_sigma: 3.0,
        confirm_slots: 1,
        min_std_floor: Some(0.001),
        min_cv: Some(0.0001),
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    for i in 0..40 {
        let v = 1.36 + if i % 2 == 0 { 0.01 } else { -0.01 };
        assert!(
            !engine
                .evaluate("disk", v, i as u64, disk_profile())
                .expect("verdict")
                .breached,
            "a weak global override must not weaken the disk floor"
        );
    }
}

/// A detector with CUSUM enabled but otherwise default thresholds. `min_samples`
/// is 30 so the rolling baseline (and the frozen CUSUM anchor) warm on a tight
/// stationary window before any drift ramp begins.
fn cusum_cfg() -> EngineConfig {
    EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 3.0,
        confirm_slots: 1,
        max_series: 10,
        drift_min_effect: 0.5,
        ..EngineConfig::default()
    }
}

/// Warm a tight, stationary baseline (std ~1) so the CUSUM anchor freezes at
/// roughly (100, 1). Asserts the stationary warmup never drifts.
fn warm_stationary(engine: &mut DetectorEngine) {
    for ts in 0..30u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        let tv = engine
            .evaluate_transition("s", v, ts, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "a stationary warmup must not raise a drift"
        );
        assert_eq!(tv.transition, AnomalyTransition::None);
    }
}

fn diurnal_10x_value(observed_at_unix_nano: u64) -> f64 {
    let seconds_of_day = (observed_at_unix_nano / 1_000_000_000) % 86_400;
    let phase = 2.0 * std::f64::consts::PI * (seconds_of_day as f64 / 86_400.0);
    10.0 + 90.0 * ((1.0 - phase.cos()) / 2.0)
}

fn diurnal_hour_of_week_profile(scale: f64) -> SeasonalProfile {
    SeasonalProfile::from_buckets((0..HOURS_PER_WEEK).map(|how| {
        let hod = how % 24;
        let midpoint_ns = ((hod as u64 * 3_600) + 1_800) * 1_000_000_000;
        (
            how,
            SeasonalBucket {
                center: diurnal_10x_value(midpoint_ns),
                scale,
                sample_count: 8,
            },
        )
    }))
}

#[test]
fn harness_diurnal_sinusoid_requires_deseasonalized_drift() {
    const SLOT_NS: u64 = 30 * 1_000_000_000;
    const SLOTS_PER_DAY: u64 = 24 * 60 * 2;
    const DAYS: u64 = 14;
    const TOTAL_SLOTS: u64 = SLOTS_PER_DAY * DAYS;

    let cfg = EngineConfig {
        window_size: 240,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 8.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 300,
        drift_min_effect: 1.0,
        drift_clear_slots: 30,
        drift_adopt_after_samples: 600,
        episode_update_interval_secs: 1_000_000,
        reopen_cooldown_secs: 7_200,
        anchor_max_age_secs: 1_000_000,
        ..EngineConfig::default()
    };

    let mut deseasonalized = DetectorEngine::new(cfg.clone());
    deseasonalized.set_seasonal_baselines(HashMap::from([(
        "diurnal".to_string(),
        diurnal_hour_of_week_profile(12.0),
    )]));
    let seasonal_profile = SeriesProfile {
        drift_mode: DriftMode::DeseasonalizedOnly,
        ..SeriesProfile::default()
    };

    for slot in 0..TOTAL_SLOTS {
        let ts = slot * SLOT_NS;
        let value = diurnal_10x_value(ts);
        let tv = deseasonalized
            .evaluate_transition_with_seasonal_key(
                "diurnal",
                "diurnal",
                value,
                ts,
                seasonal_profile,
            )
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "delivered hour-of-week baseline must silence clean diurnal drift at slot {slot}"
        );
    }

    let mut always = DetectorEngine::new(cfg);
    let always_profile = SeriesProfile {
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    };
    let mut always_open_count = 0_u64;
    let mut always_adopted_clears = 0_u64;

    for slot in 0..TOTAL_SLOTS {
        let ts = slot * SLOT_NS;
        let value = diurnal_10x_value(ts);
        let tv = always
            .evaluate_transition("diurnal", value, ts, always_profile)
            .expect("verdict");

        if let Some(drift) = tv.cusum_drift {
            if drift.transition == AnomalyTransition::Open {
                always_open_count = always_open_count.saturating_add(1);
            }
            if drift.clear_reason == Some(DriftClearReason::Adopted) {
                always_adopted_clears = always_adopted_clears.saturating_add(1);
            }
        }
    }

    assert!(
        always_open_count <= 2 * DAYS,
        "always-on raw mode should be bounded by adoption to <=2 opens/day, saw {always_open_count}"
    );
    assert!(
        always_adopted_clears > 0,
        "always-on raw mode must use adoption instead of paying an infinite annuity"
    );

    let legacy_anchor = diurnal_10x_value(0);
    let legacy_scale = 10.0;
    let legacy_h = 5.0;
    let legacy_false_positive_ratio = (0..TOTAL_SLOTS)
        .filter(|slot| {
            let residual =
                (diurnal_10x_value(*slot * SLOT_NS) - legacy_anchor).abs() / legacy_scale;
            residual > legacy_h
        })
        .count() as f64
        / TOTAL_SLOTS as f64;

    assert!(
        (0.42..=0.74).contains(&legacy_false_positive_ratio),
        "legacy frozen-anchor raw CUSUM sentinel should document the 42-74% FP band, got {legacy_false_positive_ratio:.3}"
    );
}

#[test]
fn harness_seasonal_interface_shift_opens_exactly_one_drift_episode() {
    const SLOT_NS: u64 = 30 * 1_000_000_000;
    const SLOTS_PER_DAY: u64 = 24 * 60 * 2;
    const MIDDAY_SLOT: u64 = 12 * 60 * 2;
    const CLEAN_UNTIL_SLOT: u64 = SLOTS_PER_DAY + MIDDAY_SLOT;
    const SHIFT_SLOTS: u64 = 120;

    let cfg = EngineConfig {
        window_size: 240,
        min_samples: 30,
        n_sigma: 1.0e12,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 8.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 300,
        drift_min_effect: 1.0,
        drift_clear_slots: 10_000,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 1_000_000,
        drift_escalate_after_secs: 1_000_000,
        reopen_cooldown_secs: 600,
        anchor_max_age_secs: 1_000_000,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    let profile = SeriesProfile {
        drift_mode: DriftMode::DeseasonalizedOnly,
        drift_min_cv: 0.05,
        ..SeriesProfile::default()
    };
    let resource = MetricResource {
        agent_id: "agent-snmp".to_string(),
        host_id: "snmp-poller".to_string(),
        device_id: "sr:router-1".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifOutUcastPkts".to_string(),
        metric_type: "snmp.interface".to_string(),
        unit: "packets/s".to_string(),
        ..Default::default()
    };
    let point = MetricPoint {
        if_index: 4,
        interface_uid: "ifindex:4".to_string(),
        ..Default::default()
    };
    let class = metric_class(&metric);
    let seasonal_key = seasonal_series_key(&resource, class, &metric, &point);
    let detector_key = series_key_for(&resource, &metric, &point);
    assert_eq!(seasonal_key, "sr:router-1|ifOutUcastPkts|4");
    assert_ne!(
        seasonal_key, detector_key,
        "interface seasonal baselines are delivered by device|metric|if_index, not detector key"
    );

    engine.set_seasonal_baselines(HashMap::from([(
        seasonal_key.clone(),
        diurnal_hour_of_week_profile(12.0),
    )]));

    for slot in 0..CLEAN_UNTIL_SLOT {
        let ts = slot * SLOT_NS;
        let tv = engine
            .evaluate_transition_with_seasonal_key(
                &detector_key,
                &seasonal_key,
                diurnal_10x_value(ts),
                ts,
                profile,
            )
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "clean interface diurnal data must not drift at slot {slot}"
        );
    }

    let mut drift_rows = Vec::new();
    for slot in CLEAN_UNTIL_SLOT..(CLEAN_UNTIL_SLOT + SHIFT_SLOTS) {
        let ts = slot * SLOT_NS;
        let tv = engine
            .evaluate_transition_with_seasonal_key(
                &detector_key,
                &seasonal_key,
                diurnal_10x_value(ts) * 2.0,
                ts,
                profile,
            )
            .expect("verdict");

        if let Some(drift) = tv.cusum_drift {
            drift_rows.push(drift);
        }
    }

    assert_eq!(
        drift_rows.len(),
        1,
        "sustained 2x interface shift should emit one lifecycle row, got {drift_rows:?}"
    );
    let opened = drift_rows[0];
    assert_eq!(opened.transition, AnomalyTransition::Open);
    assert_eq!(opened.direction, CusumDirection::Up);
    assert!(
        opened.episode.is_some(),
        "the open transition must carry episode metadata"
    );
}

#[test]
fn cusum_catches_slow_drift_the_point_zscore_misses() {
    // The crux: a gentle upward ramp where the rolling z-score's mean tracks the
    // drift (so each sample is sub-threshold and never confirms an anomaly), yet
    // the CUSUM anchored to the frozen warm-up baseline accumulates the
    // standardized residual until it crosses h and alarms — a DRIFT the point
    // z-score structurally misses.
    let mut engine = DetectorEngine::new(cusum_cfg());
    warm_stationary(&mut engine);

    let mut drift_seen = false;
    let mut any_open = false;
    for i in 1..=30u64 {
        let v = 100.0 + 0.4 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, always_drift_profile())
            .expect("verdict");
        if tv.transition == AnomalyTransition::Open {
            any_open = true;
        }
        if let Some(drift) = tv.cusum_drift {
            drift_seen = true;
            assert_eq!(
                drift.direction,
                CusumDirection::Up,
                "an upward ramp drifts up"
            );
            assert!(
                drift.pos.max(drift.neg) > engine.config().cusum_h,
                "the raw accumulator crossed h"
            );
            assert!(
                drift.magnitude() >= engine.config().drift_min_effect,
                "the bounded shift estimate passes the effect gate"
            );
            // The gated drift only fires where the z-score itself did NOT breach —
            // i.e. exactly the case the point detector misses.
            assert!(
                !tv.verdict.breached,
                "the drift must report what the z-score missed, not a breach"
            );
        }
    }

    assert!(
        drift_seen,
        "the anchored CUSUM must alarm on a slow drift the point z-score misses"
    );
    assert!(
        !any_open,
        "the point z-score must NOT have confirmed the gradual ramp"
    );
}

#[test]
fn cusum_default_effect_gate_suppresses_tiny_persistent_shift() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    for i in 1..=300u64 {
        let tv = engine
            .evaluate_transition("s", 103.0, 30 + i, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "a ~0.6-sigma sustained shift must stay below default drift_min_effect"
        );
    }
}

#[test]
fn cusum_latches_at_h_and_confirms_at_h_confirm() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.5,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    let latched = engine
        .evaluate_transition("s", 115.0, 31, always_drift_profile())
        .expect("verdict");
    assert!(
        latched.cusum_drift.is_none(),
        "crossing h only latches pending drift"
    );

    let confirmed = engine
        .evaluate_transition("s", 115.0, 32, always_drift_profile())
        .expect("verdict");
    let drift = confirmed
        .cusum_drift
        .expect("a second push past h_confirm confirms drift");
    assert_eq!(drift.direction, CusumDirection::Up);
    assert!(drift.pos > engine.config().cusum_h * engine.config().h_confirm_mult);
}

#[test]
fn cusum_pending_drift_expires_without_emission() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 10.0,
        drift_confirm_window: 2,
        drift_min_effect: 0.5,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    for ts in 31..=34 {
        let tv = engine
            .evaluate_transition("s", 115.0, ts, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "pending drift must expire silently when h_confirm is not reached"
        );
    }
}

#[test]
fn cusum_drift_episode_opens_once_and_clears_after_recovery() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        drift_clear_slots: 3,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 10_000,
        reopen_cooldown_secs: 1,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    let latched = engine
        .evaluate_transition("s", 115.0, 31, always_drift_profile())
        .expect("verdict");
    assert!(latched.cusum_drift.is_none());

    let opened = engine
        .evaluate_transition("s", 115.0, 32, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("confirmed drift opens");
    assert_eq!(opened.transition, AnomalyTransition::Open);
    let episode_started_at = opened
        .episode
        .expect("open carries episode metadata")
        .started_at_unix_nano;

    for ts in 33..38 {
        let tv = engine
            .evaluate_transition("s", 115.0, ts, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "open drift must not re-open every sample"
        );
    }

    for ts in 38..40 {
        let tv = engine
            .evaluate_transition("s", 100.0, ts, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "recovery must clear only after drift_clear_slots"
        );
    }

    let cleared = engine
        .evaluate_transition("s", 100.0, 40, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("third recovered sample clears drift");
    assert_eq!(cleared.transition, AnomalyTransition::Clear);
    assert_eq!(cleared.clear_reason, Some(DriftClearReason::Recovered));
    assert_eq!(
        cleared
            .episode
            .expect("clear carries episode metadata")
            .started_at_unix_nano,
        episode_started_at
    );

    engine.evaluate_transition("s", 115.0, 41, always_drift_profile());
    let reopened = engine
        .evaluate_transition("s", 115.0, 42, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("re-open inside cooldown emits a flapping update");
    assert_eq!(reopened.transition, AnomalyTransition::Update);
    assert_eq!(reopened.update_reason, Some(DriftUpdateReason::Flapping));
    assert_eq!(reopened.reopen_count, 1);
    assert_eq!(
        reopened
            .episode
            .expect("reopen carries episode metadata")
            .started_at_unix_nano,
        episode_started_at,
        "reopen inside cooldown reuses the episode identity"
    );

    for ts in 43..45 {
        let tv = engine
            .evaluate_transition("s", 100.0, ts, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "flapping episode must not immediately re-clear inside cooldown"
        );
    }

    let flap_merged = engine
        .evaluate_transition("s", 100.0, 1_000_000_043, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("clean signal past cooldown clears flapping episode");
    assert_eq!(flap_merged.transition, AnomalyTransition::Clear);
    assert_eq!(flap_merged.clear_reason, Some(DriftClearReason::FlapMerged));
}

#[test]
fn cusum_drift_episode_adopts_new_level_and_reanchors() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        drift_clear_slots: 10_000,
        drift_adopt_after_samples: 55,
        episode_update_interval_secs: 10_000,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    assert!(
        engine
            .evaluate_transition("s", 115.0, 31, always_drift_profile())
            .expect("verdict")
            .cusum_drift
            .is_none()
    );
    let opened = engine
        .evaluate_transition("s", 115.0, 32, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("confirmed drift opens");
    assert_eq!(opened.transition, AnomalyTransition::Open);

    let mut adopted = None;
    for i in 1..=60u64 {
        let tv = engine
            .evaluate_transition("s", 115.0, 32 + i, always_drift_profile())
            .expect("verdict");
        if let Some(drift) = tv.cusum_drift
            && drift.clear_reason == Some(DriftClearReason::Adopted)
        {
            adopted = Some(drift);
            break;
        }
    }

    let adopted = adopted.expect("persistent new level should be adopted and cleared");
    assert_eq!(adopted.transition, AnomalyTransition::Clear);

    for i in 1..=20u64 {
        let tv = engine
            .evaluate_transition("s", 115.0, 100 + i, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "adopted level must not immediately reopen drift"
        );
    }
}

#[test]
fn cusum_anchor_scale_refreshes_from_current_window_without_moving_center() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 10,
        n_sigma: 1_000.0,
        cusum_h: 1_000.0,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for ts in 0..12u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        engine
            .evaluate_transition("s", v, ts, always_drift_profile())
            .expect("verdict");
    }
    let (initial_center, initial_scale) = engine
        .series
        .get("s")
        .and_then(|state| state.cusum_anchor)
        .expect("cusum anchor warmed");

    for i in 0..20u64 {
        let v = 100.0 + if i % 2 == 0 { 20.0 } else { -20.0 };
        engine
            .evaluate_transition("s", v, 12 + i, always_drift_profile())
            .expect("verdict");
    }

    let (refreshed_center, refreshed_scale) = engine
        .series
        .get("s")
        .and_then(|state| state.cusum_anchor)
        .expect("cusum anchor remains present");
    assert_eq!(
        refreshed_center, initial_center,
        "scale refresh must not move the frozen drift center"
    );
    assert!(
        refreshed_scale > initial_scale * 5.0,
        "scale should track the wider current rolling window"
    );
}

#[test]
fn cusum_always_mode_refreshes_idle_anchor_after_max_age() {
    const SEC: u64 = 1_000_000_000;

    let cfg = EngineConfig {
        window_size: 30,
        min_samples: 6,
        n_sigma: 1_000.0,
        cusum_h: 1_000_000.0,
        anchor_max_age_secs: 5,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for i in 0..8u64 {
        let v = 100.0 + if i % 2 == 0 { 1.0 } else { -1.0 };
        engine
            .evaluate_transition("s", v, i * SEC, always_drift_profile())
            .expect("verdict");
    }
    let (initial_center, initial_captured_at) = {
        let state = engine.series.get("s").expect("series state");
        (
            state.cusum_anchor.expect("anchor warmed").0,
            state
                .cusum_anchor_captured_at_unix_nano
                .expect("anchor capture timestamp"),
        )
    };

    for i in 8..28u64 {
        let v = 200.0 + if i % 2 == 0 { 1.0 } else { -1.0 };
        let tv = engine
            .evaluate_transition("s", v, i * SEC, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "high thresholds isolate idle anchor refresh from drift emission"
        );
    }

    let state = engine.series.get("s").expect("series state");
    let (refreshed_center, _scale) = state.cusum_anchor.expect("anchor still present");
    assert!(
        refreshed_center > initial_center + 50.0,
        "idle anchor should refresh to the new rolling level"
    );
    assert!(
        state
            .cusum_anchor_captured_at_unix_nano
            .expect("capture timestamp")
            > initial_captured_at,
        "anchor capture timestamp should advance on idle refresh"
    );
}

#[test]
fn cusum_drift_episode_emits_bounded_heartbeat_update() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        drift_clear_slots: 10_000,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 1,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    engine.evaluate_transition("s", 115.0, 31, always_drift_profile());
    let opened = engine
        .evaluate_transition("s", 115.0, 32, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("confirmed drift opens");
    assert_eq!(opened.transition, AnomalyTransition::Open);

    let heartbeat = engine
        .evaluate_transition("s", 115.0, 1_000_000_033, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("still-open heartbeat emits after interval");
    assert_eq!(heartbeat.transition, AnomalyTransition::Update);
    assert_eq!(heartbeat.update_reason, Some(DriftUpdateReason::Heartbeat));
    assert_eq!(
        heartbeat
            .episode
            .expect("heartbeat carries episode metadata")
            .started_at_unix_nano,
        opened
            .episode
            .expect("open carries episode metadata")
            .started_at_unix_nano
    );
}

#[test]
fn cusum_drift_adoption_is_blocked_while_saturation_gate_is_active() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        drift_clear_slots: 10_000,
        drift_adopt_after_samples: 3,
        episode_update_interval_secs: 10_000,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        min_std_floor: 5.0,
        min_cv: 0.10,
        saturation_gate: Some(SaturationGate {
            directional: true,
            min_value: 85.0,
        }),
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for ts in 0..30u64 {
        let v = 20.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        engine.evaluate_transition("cpu", v, ts, profile);
    }

    engine.evaluate_transition("cpu", 92.0, 31, profile);
    let opened = engine
        .evaluate_transition("cpu", 92.0, 32, profile)
        .expect("verdict")
        .cusum_drift
        .expect("confirmed saturated drift opens");
    assert_eq!(opened.transition, AnomalyTransition::Open);

    for ts in 33..40 {
        let tv = engine
            .evaluate_transition("cpu", 92.0, ts, profile)
            .expect("verdict");
        assert!(
            !matches!(
                tv.cusum_drift,
                Some(CusumDrift {
                    clear_reason: Some(DriftClearReason::Adopted),
                    ..
                })
            ),
            "saturated CPU level must not be adopted as normal"
        );
    }
}

#[test]
fn cusum_drift_respects_saturation_gate_for_bounded_gauges() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        drift_min_effect: 0.5,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        min_std_floor: 5.0,
        min_cv: 0.10,
        saturation_gate: Some(SaturationGate {
            directional: true,
            min_value: 85.0,
        }),
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for ts in 0..30u64 {
        let v = 20.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        let tv = engine
            .evaluate_transition("cpu", v, ts, profile)
            .expect("verdict");
        assert!(tv.cusum_drift.is_none());
    }

    for i in 1..=20u64 {
        let tv = engine
            .evaluate_transition("cpu", 40.0, 30 + i, profile)
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "statistical CPU drift below the saturation gate must stay silent"
        );
    }

    let mut saturated_drift = None;
    for i in 1..=5u64 {
        let tv = engine
            .evaluate_transition("cpu", 92.0, 60 + i, profile)
            .expect("verdict");
        if tv.cusum_drift.is_some() {
            saturated_drift = tv.cusum_drift;
            break;
        }
    }

    let drift = saturated_drift.expect("saturated CPU drift should emit");
    assert_eq!(drift.direction, CusumDirection::Up);
    assert!(drift.magnitude() >= engine.config().drift_min_effect);
}

#[test]
fn cusum_catches_a_slow_leak() {
    // A leak: a slow, sustained upward growth (slower than the drift above). The
    // rolling z-score never trips, but the leak eventually accumulates past h.
    let mut engine = DetectorEngine::new(cusum_cfg());
    warm_stationary(&mut engine);

    let mut leaked = false;
    for i in 1..=120u64 {
        let v = 100.0 + 0.15 * i as f64; // gentle, leak-like growth
        let tv = engine
            .evaluate_transition("s", v, 30 + i, always_drift_profile())
            .expect("verdict");
        assert_ne!(
            tv.transition,
            AnomalyTransition::Open,
            "a slow leak must not trip the point z-score (sample {i})"
        );
        if let Some(drift) = tv.cusum_drift {
            assert_eq!(drift.direction, CusumDirection::Up);
            leaked = true;
        }
    }
    assert!(leaked, "the CUSUM must eventually flag a slow upward leak");
}

#[test]
fn harness_slow_leak_opens_escalates_and_stays_bounded() {
    const HOUR_NS: u64 = 60 * 60 * 1_000_000_000;

    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        drift_confirm_window: 300,
        drift_clear_slots: 10_000,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 1_000_000,
        anchor_max_age_secs: 1_000_000,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        min_std_floor: 1.0,
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);

    for ts in 0..30u64 {
        let tv = engine
            .evaluate_transition("leak", 100.0, ts * HOUR_NS, profile)
            .expect("verdict");
        assert!(tv.cusum_drift.is_none());
    }

    let mut drift_rows = Vec::new();
    let mut open_hour = None;
    let mut high_escalation_hour = None;
    // The effective scale floor for a 100-valued quiet series is ~5 units, so
    // 0.25 units/hour is the requested 0.05 sigma/hour ramp.
    let ramp_per_hour = 0.25;
    for hour in 1..=220u64 {
        let value = 100.0 + ramp_per_hour * hour as f64;
        let tv = engine
            .evaluate_transition("leak", value, (30 + hour) * HOUR_NS, profile)
            .expect("verdict");
        assert_ne!(
            tv.transition,
            AnomalyTransition::Open,
            "the rolling z-score must not own this slow-leak scenario"
        );

        if let Some(drift) = tv.cusum_drift {
            if drift.transition == AnomalyTransition::Open {
                open_hour = Some(hour);
            }
            if drift.update_reason == Some(DriftUpdateReason::SeverityEscalated) {
                high_escalation_hour = Some(hour);
            }
            drift_rows.push(drift);
        }
    }

    assert!(
        open_hour.is_some_and(|hour| hour <= 140),
        "0.05 sigma/hour leak should open within the ARL bound; got {open_hour:?}"
    );
    assert!(
        high_escalation_hour.is_some(),
        "slow leak should eventually emit one Medium-to-High escalation update"
    );
    assert!(
        drift_rows.len() <= 4,
        "slow leak should stay bounded to <=4 drift rows, saw {}",
        drift_rows.len()
    );
    assert_eq!(
        drift_rows
            .iter()
            .filter(|drift| drift.transition == AnomalyTransition::Open)
            .count(),
        1
    );
}

#[test]
fn harness_adversarial_flapper_merges_reopens_and_stays_bounded() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        drift_clear_slots: 3,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 10_000,
        reopen_cooldown_secs: 1,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    warm_stationary(&mut engine);

    let mut drift_rows = Vec::new();
    for (ts, value) in [
        (31, 115.0),
        (32, 115.0),
        (33, 100.0),
        (34, 100.0),
        (35, 100.0),
        (36, 115.0),
        (37, 115.0),
        (38, 100.0),
        (39, 100.0),
        (40, 100.0),
        (41, 115.0),
        (42, 115.0),
        (43, 100.0),
        (44, 100.0),
        (45, 100.0),
        (1_000_000_045, 100.0),
    ] {
        let tv = engine
            .evaluate_transition("s", value, ts, always_drift_profile())
            .expect("verdict");
        if let Some(drift) = tv.cusum_drift {
            drift_rows.push(drift);
        }
    }

    assert_eq!(
        drift_rows
            .iter()
            .filter(|drift| drift.transition == AnomalyTransition::Open)
            .count(),
        1,
        "threshold flapping must not mint a new open for every oscillation"
    );
    assert!(
        drift_rows
            .iter()
            .any(|drift| drift.transition == AnomalyTransition::Update
                && drift.update_reason == Some(DriftUpdateReason::Flapping)
                && drift.reopen_count > 0),
        "rapid reopen should be folded into the existing episode as flapping"
    );
    assert!(
        drift_rows.iter().any(|drift| {
            drift.transition == AnomalyTransition::Clear
                && drift.clear_reason == Some(DriftClearReason::FlapMerged)
        }),
        "stable recovery after flapping should clear with a flap-merged reason"
    );

    let episode_started_at = drift_rows
        .first()
        .and_then(|drift| drift.episode)
        .map(|episode| episode.started_at_unix_nano)
        .expect("first drift row carries episode");
    assert!(
        drift_rows
            .iter()
            .filter_map(|drift| drift.episode)
            .all(|episode| episode.started_at_unix_nano == episode_started_at),
        "flapping transitions should reuse one episode identity"
    );
    assert!(
        drift_rows.len() <= 4,
        "oscillating threshold flapper should stay bounded to <=4 drift rows, saw {}",
        drift_rows.len()
    );
}

#[test]
fn harness_quiet_interface_burst_bounds_score_severity_and_episode_count() {
    const SEC: u64 = 1_000_000_000;

    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 1.0e12,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 10,
        drift_min_effect: 0.5,
        drift_clear_slots: 3,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 1_000_000,
        ..EngineConfig::default()
    };
    let profile = SeriesProfile {
        drift_mode: DriftMode::Always,
        drift_min_cv: 0.05,
        ..SeriesProfile::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    let resource = MetricResource {
        agent_id: "agent-snmp".to_string(),
        host_id: "snmp-poller".to_string(),
        device_id: "switch-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifHCOutOctets".to_string(),
        metric_type: "snmp.interface".to_string(),
        ..Default::default()
    };
    let series_key = "quiet-interface-if4";

    for slot in 0..30u64 {
        let value = if slot % 2 == 0 { 0.0 } else { 0.01 };
        let tv = engine
            .evaluate_transition(series_key, value, slot * SEC, profile)
            .expect("verdict");
        assert!(tv.cusum_drift.is_none());
    }

    let mut records = Vec::new();
    for slot in 30..36u64 {
        let observed_at_unix_nano = slot * SEC;
        let tv = engine
            .evaluate_transition(series_key, 1_000_000.0, observed_at_unix_nano, profile)
            .expect("verdict");
        if let Some(drift) = tv.cusum_drift {
            let point = MetricPoint {
                value: tv.verdict.sample_value,
                observed_at_unix_nano,
                if_index: 4,
                ..Default::default()
            };
            let record =
                cusum_drift_record(&resource, &metric, &point, series_key, &tv.verdict, drift);
            records.push(serde_json::from_slice::<serde_json::Value>(&record.payload).unwrap());
        }
    }

    for slot in 36..39u64 {
        let observed_at_unix_nano = slot * SEC;
        let tv = engine
            .evaluate_transition(series_key, 0.0, observed_at_unix_nano, profile)
            .expect("verdict");
        if let Some(drift) = tv.cusum_drift {
            let point = MetricPoint {
                value: tv.verdict.sample_value,
                observed_at_unix_nano,
                if_index: 4,
                ..Default::default()
            };
            let record =
                cusum_drift_record(&resource, &metric, &point, series_key, &tv.verdict, drift);
            records.push(serde_json::from_slice::<serde_json::Value>(&record.payload).unwrap());
        }
    }

    assert!(
        !records.is_empty(),
        "the burst should still produce a bounded drift record"
    );
    assert_eq!(
        records
            .iter()
            .filter(|event| event["transition"] == "open")
            .count(),
        1,
        "quiet-interface burst should mint at most one open episode"
    );
    assert!(
        records.iter().all(|event| event["anomaly"]["score"]
            .as_f64()
            .is_some_and(|score| score <= 50.0)),
        "all persisted drift scores must be capped at 50: {records:?}"
    );
    assert!(
        records.iter().all(|event| event["severity_id"] != 5),
        "edge drift must never mint Critical by itself: {records:?}"
    );
}

/// A recurring bulk transfer on an interface (the shape that paged ~100 times a
/// day per device on demo): a 6-sample burst every 30 minutes over a quiet
/// baseline. With the recent-burst envelope the series opens at most once; the
/// same series WITHOUT the envelope reopens on every burst (the control that
/// proves the envelope is what changed). A burst three times the recent
/// magnitude still opens.
#[test]
fn harness_periodic_burst_interface_opens_once_then_stays_silent() {
    const MINUTE_NS: u64 = 60 * 1_000_000_000;
    const CYCLE: u64 = 30;
    const CYCLES: u64 = 12;

    fn periodic_value(slot: u64) -> f64 {
        let phase = slot % CYCLE;
        if (20..26).contains(&phase) {
            700_000.0
        } else {
            14_000.0 + ((slot % 7) as f64) * 500.0
        }
    }

    fn run(profile: SeriesProfile) -> (Vec<u64>, usize) {
        let cfg = EngineConfig {
            window_size: 300,
            min_samples: 30,
            n_sigma: 3.0,
            confirm_slots: 5,
            max_series: 10,
            episode_update_interval_secs: 1_000_000,
            ..EngineConfig::default()
        };
        let mut engine = DetectorEngine::new(cfg);
        let series = "periodic-burst-if4";
        let mut opens = Vec::new();

        for slot in 0..(CYCLE * CYCLES) {
            if let Some(tv) =
                engine.evaluate_transition(series, periodic_value(slot), slot * MINUTE_NS, profile)
                && tv.transition == AnomalyTransition::Open
            {
                opens.push(slot);
            }
        }

        // A burst three times the recent envelope must still confirm.
        let mut tall_opens = 0;
        for slot in (CYCLE * CYCLES)..(CYCLE * CYCLES + 6) {
            if let Some(tv) =
                engine.evaluate_transition(series, 2_100_000.0, slot * MINUTE_NS, profile)
                && tv.transition == AnomalyTransition::Open
            {
                tall_opens += 1;
            }
        }

        (opens, tall_opens)
    }

    let metric = Metric {
        name: "ifHCInOctets".to_string(),
        metric_type: "snmp.interface".to_string(),
        ..Default::default()
    };
    let enveloped = counter_series_profile(&metric);
    assert!(
        enveloped.burst_envelope.is_some(),
        "interface byte rates enable the burst envelope by default"
    );
    let control = SeriesProfile {
        burst_envelope: None,
        ..enveloped
    };

    let (control_opens, _) = run(control);
    assert!(
        control_opens.len() >= 3,
        "control: without the envelope the recurring burst must keep reopening (got {control_opens:?})"
    );

    let (opens, tall_opens) = run(enveloped);
    assert!(
        opens.len() <= 1,
        "recurring bursts within the recent envelope must not keep reopening (opens at {opens:?})"
    );
    assert_eq!(
        tall_opens, 1,
        "a burst 3x the recent envelope must still open"
    );
}

#[test]
fn harness_diurnal_interface_without_baseline_stays_bounded_and_adopts_a_shift() {
    const MINUTE_NS: u64 = 60 * 1_000_000_000;
    const SLOTS_PER_DAY: u64 = 24 * 60;
    const DIURNAL_DAYS: u64 = 3;

    let mut engine = DetectorEngine::new(EngineConfig::default());
    let profile = counter_series_profile(&Metric {
        name: "ifOutUcastPkts".to_string(),
        metric_type: "snmp.interface".to_string(),
        ..Default::default()
    });
    let series_key = "diurnal-interface-if49";
    let mut open_count = 0_u64;
    let mut adopted_clear_count = 0_u64;
    let mut max_stored_score = 0.0_f64;
    let resource = MetricResource {
        agent_id: "agent-snmp".to_string(),
        host_id: "snmp-poller".to_string(),
        device_id: "switch-a".to_string(),
        partition: "demo".to_string(),
        ..Default::default()
    };
    let metric = Metric {
        name: "ifOutUcastPkts".to_string(),
        metric_type: "snmp.interface".to_string(),
        ..Default::default()
    };

    // Production-like interface traffic: quiet nights around 15 pkt/s and a
    // daytime ramp/plateau between 40 and 75 pkt/s. No seasonal baseline is
    // installed, so only the rolling spike path may emit an episode.
    for slot in 0..(DIURNAL_DAYS * SLOTS_PER_DAY) {
        let minute = slot % SLOTS_PER_DAY;
        let value = match minute {
            0..=359 | 1_200..=1_439 => 15.0 + (slot % 3) as f64,
            360..=719 => 40.0 + (minute - 360) as f64 * (35.0 / 359.0),
            720..=959 => 75.0,
            _ => 75.0 - (minute - 960) as f64 * (35.0 / 239.0),
        };
        let tv = engine
            .evaluate_transition(series_key, value, slot * MINUTE_NS, profile)
            .expect("diurnal verdict");
        if tv.transition == AnomalyTransition::Open {
            open_count = open_count.saturating_add(1);
        }
    }

    assert!(
        open_count <= DIURNAL_DAYS,
        "ordinary diurnal traffic must stay bounded to <= one spike episode/day, saw {open_count}"
    );

    // A stable, non-saturated level shift must not remain anomalous forever.
    // The production interface profile adopts after 300 continuously anomalous
    // samples, then the rebuilt baseline must remain quiet at the new level.
    let shift_start = DIURNAL_DAYS * SLOTS_PER_DAY;
    for offset in 0..420u64 {
        let tv = engine
            .evaluate_transition(
                series_key,
                10_000.0,
                (shift_start + offset) * MINUTE_NS,
                profile,
            )
            .expect("sustained-shift verdict");
        if tv.transition == AnomalyTransition::Open {
            open_count = open_count.saturating_add(1);
        }
        if tv.transition == AnomalyTransition::Clear
            && tv.clear_reason == Some(SpikeClearReason::Adopted)
        {
            adopted_clear_count = adopted_clear_count.saturating_add(1);
        }
        if tv.transition != AnomalyTransition::None {
            let point = MetricPoint {
                value: tv.verdict.sample_value,
                observed_at_unix_nano: (shift_start + offset) * MINUTE_NS,
                if_index: 49,
                ..Default::default()
            };
            let record = verdict_record(
                &resource,
                &metric,
                &point,
                series_key,
                &tv.verdict,
                tv.transition,
                tv.episode,
            );
            let event: serde_json::Value =
                serde_json::from_slice(&record.payload).expect("spike OCSF payload");
            max_stored_score = max_stored_score.max(
                event["anomaly"]["score"]
                    .as_f64()
                    .expect("stored anomaly score"),
            );
        }
    }

    assert_eq!(
        adopted_clear_count, 1,
        "the sustained level shift must clear exactly once through spike adoption"
    );
    assert!(
        open_count <= DIURNAL_DAYS + 1,
        "the diurnal run plus one sustained shift must remain episode-bounded, saw {open_count} opens"
    );
    assert!(
        max_stored_score <= 50.0,
        "stored spike evidence must stay bounded at 50, saw {max_stored_score}"
    );
}

#[test]
fn harness_regime_change_adopts_once_then_stays_silent_for_seven_days() {
    const SLOT_NS: u64 = 30 * 1_000_000_000;
    const SLOTS_PER_DAY: u64 = 24 * 60 * 2;

    let cfg = EngineConfig {
        window_size: 240,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 8.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 300,
        drift_min_effect: 1.0,
        drift_clear_slots: 10_000,
        drift_adopt_after_samples: 600,
        episode_update_interval_secs: 1_000_000,
        reopen_cooldown_secs: 600,
        anchor_max_age_secs: 1_000_000,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg);
    let profile = SeriesProfile {
        min_std_floor: 1.0,
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    };

    for slot in 0..30u64 {
        let value = 100.0 + if slot % 2 == 0 { 1.0 } else { -1.0 };
        let tv = engine
            .evaluate_transition("regime", value, slot * SLOT_NS, profile)
            .expect("verdict");
        assert!(tv.cusum_drift.is_none());
    }

    let mut open_count = 0_u64;
    let mut adopted_clear_count = 0_u64;
    let mut adopted_at_slot = None;
    let end_slot = 30 + (SLOTS_PER_DAY * 8);

    for slot in 30..end_slot {
        let tv = engine
            .evaluate_transition("regime", 115.0, slot * SLOT_NS, profile)
            .expect("verdict");

        if let Some(drift) = tv.cusum_drift {
            if adopted_at_slot.is_some() {
                panic!("adopted regime level reopened after adoption at slot {slot}: {drift:?}");
            }

            if drift.transition == AnomalyTransition::Open {
                open_count = open_count.saturating_add(1);
            }
            if drift.clear_reason == Some(DriftClearReason::Adopted) {
                adopted_clear_count = adopted_clear_count.saturating_add(1);
                adopted_at_slot = Some(slot);
            }
        }

        if let Some(adopted_at) = adopted_at_slot
            && slot.saturating_sub(adopted_at) >= SLOTS_PER_DAY * 7
        {
            break;
        }
    }

    assert_eq!(open_count, 1, "a benign regime change should open once");
    assert_eq!(
        adopted_clear_count, 1,
        "a benign regime change should clear once via adoption"
    );
    assert!(
        adopted_at_slot.is_some(),
        "persistent +3 sigma regime change should be adopted"
    );
}

#[test]
fn harness_checkpointless_restart_storm_is_silent_with_baseline_and_bounded_without() {
    const SLOT_NS: u64 = 30 * 1_000_000_000;
    const SLOTS_PER_DAY: u64 = 24 * 60 * 2;
    const RESTARTS_PER_DAY: u64 = 4;
    const SEGMENT_SLOTS: u64 = SLOTS_PER_DAY / RESTARTS_PER_DAY;

    let cfg = EngineConfig {
        window_size: 240,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 8.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 300,
        drift_min_effect: 1.0,
        drift_clear_slots: 30,
        drift_adopt_after_samples: 600,
        episode_update_interval_secs: 1_000_000,
        reopen_cooldown_secs: 600,
        anchor_max_age_secs: 1_000_000,
        ..EngineConfig::default()
    };
    let seasonal_profile = SeriesProfile {
        drift_mode: DriftMode::DeseasonalizedOnly,
        ..SeriesProfile::default()
    };

    for restart in 0..RESTARTS_PER_DAY {
        let mut engine = DetectorEngine::new(cfg.clone());
        engine.set_seasonal_baselines(HashMap::from([(
            "diurnal".to_string(),
            diurnal_hour_of_week_profile(12.0),
        )]));

        for offset in 0..SEGMENT_SLOTS {
            let slot = restart * SEGMENT_SLOTS + offset;
            let ts = slot * SLOT_NS;
            let tv = engine
                .evaluate_transition_with_seasonal_key(
                    "diurnal",
                    "diurnal",
                    diurnal_10x_value(ts),
                    ts,
                    seasonal_profile,
                )
                .expect("verdict");
            assert!(
                tv.cusum_drift.is_none(),
                "baseline-covered restart segment {restart} must not drift at slot {slot}"
            );
        }
    }

    let raw_profile = SeriesProfile {
        drift_mode: DriftMode::Always,
        ..SeriesProfile::default()
    };
    let mut raw_open_count = 0_u64;

    for restart in 0..RESTARTS_PER_DAY {
        let mut engine = DetectorEngine::new(cfg.clone());
        for offset in 0..SEGMENT_SLOTS {
            let slot = restart * SEGMENT_SLOTS + offset;
            let ts = slot * SLOT_NS;
            let tv = engine
                .evaluate_transition("diurnal", diurnal_10x_value(ts), ts, raw_profile)
                .expect("verdict");
            if tv
                .cusum_drift
                .is_some_and(|drift| drift.transition == AnomalyTransition::Open)
            {
                raw_open_count = raw_open_count.saturating_add(1);
            }
        }
    }

    assert!(
        raw_open_count <= RESTARTS_PER_DAY,
        "checkpoint-less raw mode should stay bounded to <= one open per restart/day, saw {raw_open_count}"
    );
}

#[test]
fn cusum_reports_downward_drift_on_the_neg_side() {
    // The lower accumulator catches a sustained DOWNWARD drift.
    let mut engine = DetectorEngine::new(cusum_cfg());
    warm_stationary(&mut engine);

    let mut down_seen = false;
    for i in 1..=30u64 {
        let v = 100.0 - 0.4 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, always_drift_profile())
            .expect("verdict");
        if let Some(drift) = tv.cusum_drift {
            assert_eq!(drift.direction, CusumDirection::Down);
            assert!(drift.neg >= drift.pos, "the S- accumulator crossed");
            down_seen = true;
        }
    }
    assert!(down_seen, "a downward drift must alarm on the neg side");
}

#[test]
fn drift_mode_off_is_back_compat_rolling_only() {
    // With drift_mode=off the engine is the prior rolling-only detector: the same
    // ramp produces no drift verdicts and no z-score open (it is the missed case).
    let cfg = EngineConfig { ..cusum_cfg() };
    let mut engine = DetectorEngine::new(cfg);
    let profile = SeriesProfile {
        drift_mode: DriftMode::Off,
        ..SeriesProfile::default()
    };
    for ts in 0..30u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        engine.evaluate_transition("s", v, ts, profile);
    }
    for i in 1..=30u64 {
        let v = 100.0 + 0.4 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, profile)
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "drift_mode=off must never raise a drift (sample {i})"
        );
        assert_ne!(tv.transition, AnomalyTransition::Open);
    }
}

#[test]
fn cusum_deseasonalized_only_stays_silent_without_a_baseline() {
    let mut engine = DetectorEngine::new(cusum_cfg());
    for ts in 0..30u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        engine.evaluate_transition("s", v, ts, seasonal_only_drift_profile());
    }
    for i in 1..=120u64 {
        let v = 100.0 + 0.4 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, seasonal_only_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "deseasonalized-only drift must not fall back to a raw anchor (sample {i})"
        );
    }
}

#[test]
fn cusum_deseasonalizes_against_the_delivered_seasonal_center() {
    // A series whose elevated steady level matches its delivered hour-of-week
    // center is NORMAL for the hour and must NOT drift, even though the same level
    // measured against the (lower) rolling anchor WOULD accumulate a drift. The
    // warm-up is wide enough that the elevated level never breaches the z-score,
    // so the only thing that can speak is the CUSUM — and the seasonal target is
    // what silences it.
    let cfg = EngineConfig {
        n_sigma: 100.0,
        ..cusum_cfg()
    };
    let elevated = 135.0;

    // Wide warm-up (std ~30) so `elevated` is a sub-z move, then a steady run AT
    // the elevated level.
    let warm = |engine: &mut DetectorEngine, profile: SeriesProfile| {
        for ts in 0..30u64 {
            let v = if ts % 2 == 0 { 70.0 } else { 130.0 };
            engine.evaluate("s", v, ts, profile);
        }
    };

    // Rolling anchor only (no seasonal): the elevated steady level drifts UP.
    let mut rolling = DetectorEngine::new(cfg.clone());
    warm(&mut rolling, always_drift_profile());
    let mut rolling_drift = false;
    for i in 1..=120u64 {
        let tv = rolling
            .evaluate_transition("s", elevated, 30 + i, always_drift_profile())
            .expect("verdict");
        assert_ne!(tv.transition, AnomalyTransition::Open, "elevated is sub-z");
        rolling_drift |= tv.cusum_drift.is_some();
    }
    assert!(
        rolling_drift,
        "against the rolling anchor, a sustained elevated level reads as a drift"
    );

    // Same series, but the delivered hour-of-week center IS the elevated level:
    // deseasonalizing makes the residual ~0, so no drift.
    let mut seasonal = DetectorEngine::new(cfg);
    seasonal.set_seasonal_baselines(HashMap::from([(
        "s".to_string(),
        SeasonalProfile::from_buckets((0..HOURS_PER_WEEK).map(|i| {
            (
                i,
                SeasonalBucket {
                    center: elevated,
                    scale: 3.0,
                    sample_count: 8,
                },
            )
        })),
    )]));
    warm(&mut seasonal, seasonal_only_drift_profile());
    for i in 1..=40u64 {
        let tv = seasonal
            .evaluate_transition("s", elevated, 30 + i, seasonal_only_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "a level normal for its hour-of-week must not drift (sample {i})"
        );
    }
}

#[test]
fn cusum_drift_state_survives_checkpoint_restart() {
    let cfg = EngineConfig {
        n_sigma: 100.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        ..cusum_cfg()
    };
    let mut engine = DetectorEngine::new(cfg.clone());
    warm_stationary(&mut engine);

    // Ramp just short of the alarm so the CUSUM has a partial `S+` accumulation
    // (no alarm yet). The slope is set against the magnitude-aware CUSUM anchor
    // floor (5% of the ~100 center), so the partial accumulation lands just
    // under `h` over these five steps.
    for i in 1..=5u64 {
        let v = 100.0 + 3.3 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, always_drift_profile())
            .expect("verdict");
        assert!(tv.cusum_drift.is_none(), "must not alarm before crossing h");
    }

    let checkpoint = engine.export_checkpoint();
    let snap = checkpoint
        .series
        .iter()
        .find(|c| c.series_key == "s")
        .expect("series checkpoint");
    assert!(
        snap.cusum_anchor_mean.is_some(),
        "anchor mean is checkpointed"
    );
    assert!(
        snap.cusum_anchor_scale.is_some(),
        "anchor scale is checkpointed"
    );
    assert!(
        snap.cusum_anchor_captured_at_unix_nano.is_some(),
        "anchor capture timestamp is checkpointed"
    );
    assert!(
        snap.cusum_pos.unwrap_or(0.0) > 0.0,
        "the partial S+ accumulation is checkpointed"
    );
    assert!(
        snap.cusum_run_samples > 0,
        "the CUSUM run sample count is checkpointed"
    );

    // Reseed a fresh engine and continue the ramp: because the partial
    // accumulation survived, the next step crosses h and alarms. (A restart that
    // dropped the CUSUM state would re-accumulate from zero and not alarm here.)
    let mut restored = DetectorEngine::new(cfg);
    assert_eq!(restored.restore_checkpoint(checkpoint, 1_000, u64::MAX), 1);
    let latched = restored
        .evaluate_transition("s", 100.0 + 3.3 * 6.0, 36, always_drift_profile())
        .expect("verdict");
    assert!(
        latched.cusum_drift.is_none(),
        "the restored CUSUM first latches instead of emitting"
    );
    let confirmed = restored
        .evaluate_transition("s", 100.0 + 3.3 * 7.0, 37, always_drift_profile())
        .expect("verdict");
    let drift = confirmed
        .cusum_drift
        .expect("the restored CUSUM accumulation must confirm promptly");
    assert_eq!(drift.direction, CusumDirection::Up);
}

#[test]
fn cusum_pending_latch_survives_checkpoint_restart() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.5,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg.clone());
    warm_stationary(&mut engine);

    let latched = engine
        .evaluate_transition("s", 115.0, 31, always_drift_profile())
        .expect("verdict");
    assert!(
        latched.cusum_drift.is_none(),
        "crossing h only latches pending drift"
    );

    let checkpoint = engine.export_checkpoint();
    let snap = checkpoint
        .series
        .iter()
        .find(|c| c.series_key == "s")
        .expect("series checkpoint");
    assert_eq!(snap.cusum_pending_direction, Some(CusumDirection::Up));
    assert_eq!(snap.cusum_pending_samples, 0);

    let mut restored = DetectorEngine::new(cfg);
    assert_eq!(restored.restore_checkpoint(checkpoint, 1_000, u64::MAX), 1);

    let confirmed = restored
        .evaluate_transition("s", 115.0, 32, always_drift_profile())
        .expect("verdict");
    let drift = confirmed
        .cusum_drift
        .expect("restored pending latch should confirm instead of relatching");
    assert_eq!(drift.transition, AnomalyTransition::Open);
    assert_eq!(drift.direction, CusumDirection::Up);
}

#[test]
fn open_drift_episode_survives_checkpoint_restart() {
    let cfg = EngineConfig {
        window_size: 50,
        min_samples: 30,
        n_sigma: 100.0,
        confirm_slots: 1,
        max_series: 10,
        cusum_h: 2.0,
        h_confirm_mult: 1.0,
        drift_confirm_window: 5,
        drift_min_effect: 0.5,
        drift_clear_slots: 3,
        drift_adopt_after_samples: 10_000,
        episode_update_interval_secs: 10_000,
        ..EngineConfig::default()
    };
    let mut engine = DetectorEngine::new(cfg.clone());
    warm_stationary(&mut engine);

    engine.evaluate_transition("s", 115.0, 31, always_drift_profile());
    let opened = engine
        .evaluate_transition("s", 115.0, 32, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("confirmed drift opens");
    assert_eq!(opened.transition, AnomalyTransition::Open);
    let episode_started_at = opened
        .episode
        .expect("open carries episode metadata")
        .started_at_unix_nano;

    let checkpoint = engine.export_checkpoint();
    let snap = checkpoint
        .series
        .iter()
        .find(|c| c.series_key == "s")
        .expect("series checkpoint");
    assert!(snap.drift_active);
    assert_eq!(snap.drift_active_direction, Some(CusumDirection::Up));
    assert_eq!(
        snap.drift_episode_started_at_unix_nano,
        Some(episode_started_at)
    );

    let mut restored = DetectorEngine::new(cfg);
    assert_eq!(restored.restore_checkpoint(checkpoint, 1_000, u64::MAX), 1);

    for ts in 33..35 {
        let tv = restored
            .evaluate_transition("s", 100.0, ts, always_drift_profile())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "restored open drift must clear only after drift_clear_slots"
        );
    }

    let cleared = restored
        .evaluate_transition("s", 100.0, 35, always_drift_profile())
        .expect("verdict")
        .cusum_drift
        .expect("third recovered sample clears restored drift");
    assert_eq!(cleared.transition, AnomalyTransition::Clear);
    assert_eq!(cleared.clear_reason, Some(DriftClearReason::Recovered));
    assert_eq!(
        cleared
            .episode
            .expect("clear carries episode metadata")
            .started_at_unix_nano,
        episode_started_at,
        "restart must not fork a new drift episode"
    );
}
