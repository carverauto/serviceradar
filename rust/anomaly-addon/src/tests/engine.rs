// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Crate-internal tests for the edge detector engine: rolling/seasonal scoring,
//! counter rate normalization, episode lifecycle transitions, the saturation
//! profiles, the CUSUM drift detector, and checkpoint round-trips.

use std::collections::HashMap;

use serviceradar_anomaly_core::{HOURS_PER_WEEK, SaturationGate, SeasonalBucket};

use crate::engine::*;

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
                aggregation_slot_start_unix_nano: None,
                aggregation_slot_value: None,
                aggregation_slot_peak_at_unix_nano: None,
                cusum_anchor_mean: None,
                cusum_anchor_scale: None,
                cusum_pos: None,
                cusum_neg: None,
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
                aggregation_slot_start_unix_nano: None,
                aggregation_slot_value: None,
                aggregation_slot_peak_at_unix_nano: None,
                cusum_anchor_mean: None,
                cusum_anchor_scale: None,
                cusum_pos: None,
                cusum_neg: None,
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
                aggregation_slot_start_unix_nano: None,
                aggregation_slot_value: None,
                aggregation_slot_peak_at_unix_nano: None,
                cusum_anchor_mean: None,
                cusum_anchor_scale: None,
                cusum_pos: None,
                cusum_neg: None,
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
        cusum_enabled: true,
        ..EngineConfig::default()
    }
}

/// Warm a tight, stationary baseline (std ~1) so the CUSUM anchor freezes at
/// roughly (100, 1). Asserts the stationary warmup never drifts.
fn warm_stationary(engine: &mut DetectorEngine) {
    for ts in 0..30u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        let tv = engine
            .evaluate_transition("s", v, ts, SeriesProfile::default())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "a stationary warmup must not raise a drift"
        );
        assert_eq!(tv.transition, AnomalyTransition::None);
    }
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
            .evaluate_transition("s", v, 30 + i, SeriesProfile::default())
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
                drift.magnitude() > engine.config().cusum_h,
                "the alarm crossed h"
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
fn cusum_catches_a_slow_leak() {
    // A leak: a slow, sustained upward growth (slower than the drift above). The
    // rolling z-score never trips, but the leak eventually accumulates past h.
    let mut engine = DetectorEngine::new(cusum_cfg());
    warm_stationary(&mut engine);

    let mut leaked = false;
    for i in 1..=120u64 {
        let v = 100.0 + 0.15 * i as f64; // gentle, leak-like growth
        let tv = engine
            .evaluate_transition("s", v, 30 + i, SeriesProfile::default())
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
fn cusum_reports_downward_drift_on_the_neg_side() {
    // The lower accumulator catches a sustained DOWNWARD drift.
    let mut engine = DetectorEngine::new(cusum_cfg());
    warm_stationary(&mut engine);

    let mut down_seen = false;
    for i in 1..=30u64 {
        let v = 100.0 - 0.4 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, SeriesProfile::default())
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
fn cusum_disabled_is_back_compat_rolling_only() {
    // With CUSUM disabled the engine is the prior rolling-only detector: the same
    // ramp produces no drift verdicts and no z-score open (it is the missed case).
    let cfg = EngineConfig {
        cusum_enabled: false,
        ..cusum_cfg()
    };
    let mut engine = DetectorEngine::new(cfg);
    for ts in 0..30u64 {
        let v = 100.0 + if ts % 2 == 0 { 1.0 } else { -1.0 };
        engine.evaluate_transition("s", v, ts, SeriesProfile::default());
    }
    for i in 1..=30u64 {
        let v = 100.0 + 0.4 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, SeriesProfile::default())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "cusum disabled must never raise a drift (sample {i})"
        );
        assert_ne!(tv.transition, AnomalyTransition::Open);
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
    let cfg = cusum_cfg();
    let elevated = 135.0;

    // Wide warm-up (std ~30) so `elevated` is a sub-z move, then a steady run AT
    // the elevated level.
    let warm = |engine: &mut DetectorEngine| {
        for ts in 0..30u64 {
            let v = if ts % 2 == 0 { 70.0 } else { 130.0 };
            engine.evaluate("s", v, ts, SeriesProfile::default());
        }
    };

    // Rolling anchor only (no seasonal): the elevated steady level drifts UP.
    let mut rolling = DetectorEngine::new(cfg.clone());
    warm(&mut rolling);
    let mut rolling_drift = false;
    for i in 1..=20u64 {
        let tv = rolling
            .evaluate_transition("s", elevated, 30 + i, SeriesProfile::default())
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
    warm(&mut seasonal);
    for i in 1..=20u64 {
        let tv = seasonal
            .evaluate_transition("s", elevated, 30 + i, SeriesProfile::default())
            .expect("verdict");
        assert!(
            tv.cusum_drift.is_none(),
            "a level normal for its hour-of-week must not drift (sample {i})"
        );
    }
}

#[test]
fn cusum_drift_state_survives_checkpoint_restart() {
    let cfg = cusum_cfg();
    let mut engine = DetectorEngine::new(cfg.clone());
    warm_stationary(&mut engine);

    // Ramp just short of the alarm so the CUSUM has a partial `S+` accumulation
    // (no alarm yet). The slope is set against the ROBUST anchor scale (MAD *
    // 1.4826 ≈ 1.48 for the ±1 warm-up, larger than the old mean/std ~1.02), so
    // the partial accumulation lands just under `h` over these five steps.
    for i in 1..=5u64 {
        let v = 100.0 + 0.6 * i as f64;
        let tv = engine
            .evaluate_transition("s", v, 30 + i, SeriesProfile::default())
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
        snap.cusum_pos.unwrap_or(0.0) > 0.0,
        "the partial S+ accumulation is checkpointed"
    );

    // Reseed a fresh engine and continue the ramp: because the partial
    // accumulation survived, the next step crosses h and alarms. (A restart that
    // dropped the CUSUM state would re-accumulate from zero and not alarm here.)
    let mut restored = DetectorEngine::new(cfg);
    assert_eq!(restored.restore_checkpoint(checkpoint, 1_000, u64::MAX), 1);
    let tv = restored
        .evaluate_transition("s", 100.0 + 0.6 * 6.0, 36, SeriesProfile::default())
        .expect("verdict");
    let drift = tv
        .cusum_drift
        .expect("the restored CUSUM accumulation must re-alarm promptly");
    assert_eq!(drift.direction, CusumDirection::Up);
}
