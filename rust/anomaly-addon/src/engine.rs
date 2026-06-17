// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Per-series detector state, driven by the shared `serviceradar-anomaly-core`
//! stateless reason path. This keeps scoring in Rust/DeepCausality at the edge.

use std::collections::HashMap;

use serviceradar_anomaly_core::{
    DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    ReasonContext, ReasonSample, ReasonVerdict, reason_impl,
};

/// Detector thresholds + the per-host series cap (the edge-resource bound).
#[derive(Clone, Debug)]
pub struct EngineConfig {
    pub window_size: usize,
    pub min_samples: usize,
    pub n_sigma: f64,
    pub confirm_slots: usize,
    /// Hard cap on tracked series so a busy host cannot grow detector memory
    /// without bound. New series past the cap are dropped and counted.
    pub max_series: usize,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            window_size: DEFAULT_WINDOW_SIZE,
            min_samples: DEFAULT_MIN_SAMPLES,
            n_sigma: DEFAULT_N_SIGMA,
            confirm_slots: DEFAULT_CONFIRM_SLOTS,
            max_series: 50_000,
        }
    }
}

/// A gap longer than this between two counter readings is treated as a
/// discontinuity (agent restart, missed polls) rather than a rate. 2 hours,
/// matching central `CounterNormalizer`'s `@default_max_gap_ns`.
const COUNTER_MAX_GAP_NS: u64 = 2 * 60 * 60 * 1_000_000_000;

/// 2^32 — the 32-bit counter modulus and the default max plausible per-second
/// rate used to sanity-check a wrap (central `@counter32_modulus`).
const COUNTER32_MODULUS: f64 = 4_294_967_296.0;

/// The retained baseline for one series. The rolling accumulator is recomputed
/// from `window_tail` each evaluation (the stateless path), so only the bounded
/// window tail and the confirm-slot counter need to persist between samples.
struct SeriesState {
    window_tail: Vec<f64>,
    consecutive_anomalous: usize,
    /// Observed time of the most recent sample, for the restart staleness bound:
    /// a baseline whose last reading is too old is not reseeded (it would
    /// mis-score current traffic).
    last_observed_at_unix_nano: u64,
}

/// Per-series cumulative-counter reading retained for rate normalization. The
/// detector cannot z-score a raw cumulative counter (SNMP interface octets,
/// etc.); central derives a per-second rate from consecutive readings on one
/// reset lineage and the edge mirrors that math so verdicts match.
#[derive(Clone, Debug)]
struct CounterState {
    value: f64,
    timestamp: u64,
    reset_anchor: String,
}

/// Bounded map of per-series detector state.
pub struct DetectorEngine {
    config: EngineConfig,
    series: HashMap<String, SeriesState>,
    /// Last cumulative-counter reading per series, for rate normalization.
    counters: HashMap<String, CounterState>,
    /// Number of new series dropped because the `max_series` cap was reached.
    pub dropped_at_capacity: u64,
}

impl DetectorEngine {
    pub fn new(config: EngineConfig) -> Self {
        Self {
            config,
            series: HashMap::new(),
            counters: HashMap::new(),
            dropped_at_capacity: 0,
        }
    }

    pub fn set_config(&mut self, config: EngineConfig) {
        self.config = config;
    }

    pub fn series_count(&self) -> usize {
        self.series.len()
    }

    pub fn max_series(&self) -> usize {
        self.config.max_series
    }

    /// Rate-normalize one cumulative-monotonic counter reading against this
    /// series' previous reading, mirroring central `CounterNormalizer`: returns
    /// `Some(rate_per_second)` when a safe rate is computable, or `None` on the
    /// first reading (warmup), a reset-lineage change, non-monotonic time, an
    /// over-long gap, or an implausible decrease. Per-series state advances
    /// exactly as central advances it (no advance on non-monotonic time).
    ///
    /// `counter_width` is the PDU width (32/64); a decrease is only salvaged as a
    /// plausible 32-bit wrap. The returned rate is what should be fed to
    /// [`Self::evaluate`] in place of the raw counter value.
    pub fn normalize_counter(
        &mut self,
        series_key: &str,
        raw_value: f64,
        observed_at_unix_nano: u64,
        reset_anchor: &str,
        counter_width: u32,
    ) -> Option<f64> {
        if !raw_value.is_finite() || raw_value < 0.0 {
            return None;
        }

        let current = CounterState {
            value: raw_value,
            timestamp: observed_at_unix_nano,
            reset_anchor: reset_anchor.to_owned(),
        };

        let previous = match self.counters.get(series_key) {
            // Warmup: store the first reading, emit nothing (a rate needs two).
            None => {
                self.counters.insert(series_key.to_owned(), current);
                return None;
            }
            Some(prev) => prev.clone(),
        };

        // Reset lineage changed (counter restart): store, drop — a rate across a
        // reset is meaningless.
        if reset_anchor_changed(&previous.reset_anchor, &current.reset_anchor) {
            self.counters.insert(series_key.to_owned(), current);
            return None;
        }

        // Non-monotonic time: drop WITHOUT advancing, keeping the older valid
        // reading as the baseline (matches central).
        if current.timestamp <= previous.timestamp {
            return None;
        }

        // Over-long gap: store, drop — treat as a discontinuity, not a rate.
        if current.timestamp - previous.timestamp > COUNTER_MAX_GAP_NS {
            self.counters.insert(series_key.to_owned(), current);
            return None;
        }

        let elapsed_seconds = (current.timestamp - previous.timestamp) as f64 / 1_000_000_000.0;
        let delta = counter_delta(
            previous.value,
            current.value,
            counter_width,
            elapsed_seconds,
        );

        // Advance across the interval whether or not a delta was salvageable
        // (central stores `current` on both the ok and decrease-drop branches).
        self.counters.insert(series_key.to_owned(), current);

        match delta {
            Some(d) if elapsed_seconds > 0.0 => Some(d / elapsed_seconds),
            _ => None,
        }
    }

    /// Evaluate one sample for `series_key`, advancing the stored baseline.
    /// Returns the verdict, or `None` if the value is non-finite, the detector
    /// errored, or the series was dropped at the capacity cap.
    pub fn evaluate(
        &mut self,
        series_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
    ) -> Option<ReasonVerdict> {
        if !value.is_finite() {
            return None;
        }

        if !self.series.contains_key(series_key) && self.series.len() >= self.config.max_series {
            self.dropped_at_capacity = self.dropped_at_capacity.saturating_add(1);
            return None;
        }

        let state = self
            .series
            .entry(series_key.to_owned())
            .or_insert_with(|| SeriesState {
                window_tail: Vec::new(),
                consecutive_anomalous: 0,
                last_observed_at_unix_nano: observed_at_unix_nano,
            });

        let context = ReasonContext {
            baseline: Vec::new(),
            rolling_acc: None,
            window_tail: Some(state.window_tail.clone()),
            seasonal_baseline: None,
            trend_baseline: None,
            rolling_enabled: Some(true),
            seasonal_enabled: None,
            trend_enabled: None,
            min_samples: Some(self.config.min_samples),
            seasonal_min_samples: None,
            trend_min_samples: None,
            window_size: Some(self.config.window_size),
            n_sigma: Some(self.config.n_sigma),
            seasonal_n_sigma: None,
            trend_n_sigma: None,
            confirm_slots: Some(self.config.confirm_slots),
            consecutive_anomalous: Some(state.consecutive_anomalous),
        };
        let sample = ReasonSample {
            value,
            observed_at_unix_nano: Some(observed_at_unix_nano),
        };

        match reason_impl(context, sample) {
            Ok(verdict) => {
                state.window_tail = verdict.next_window_tail.clone();
                state.consecutive_anomalous = verdict.next_consecutive_anomalous;
                state.last_observed_at_unix_nano = observed_at_unix_nano;
                Some(verdict)
            }
            Err(_) => None,
        }
    }
}

/// One series' retained detector baseline, serialized for the restart checkpoint.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct SeriesCheckpoint {
    pub series_key: String,
    pub window_tail: Vec<f64>,
    pub consecutive_anomalous: usize,
    pub last_observed_at_unix_nano: u64,
}

/// One series' last cumulative-counter reading, serialized for the checkpoint.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct CounterCheckpoint {
    pub series_key: String,
    pub value: f64,
    pub timestamp: u64,
    pub reset_anchor: String,
}

/// A point-in-time snapshot of all per-series detector + counter state, written
/// to the add-on's local checkpoint so a restart re-warms baselines instead of
/// rebuilding them from scratch (which would storm false positives while the
/// windows refill). Heavy seasonal/contextual state stays central, so this
/// snapshot is intentionally small.
#[derive(Clone, Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct EngineCheckpoint {
    pub series: Vec<SeriesCheckpoint>,
    pub counters: Vec<CounterCheckpoint>,
}

impl DetectorEngine {
    /// Snapshot the current per-series detector + counter state for persistence.
    pub fn export_checkpoint(&self) -> EngineCheckpoint {
        EngineCheckpoint {
            series: self
                .series
                .iter()
                .map(|(key, state)| SeriesCheckpoint {
                    series_key: key.clone(),
                    window_tail: state.window_tail.clone(),
                    consecutive_anomalous: state.consecutive_anomalous,
                    last_observed_at_unix_nano: state.last_observed_at_unix_nano,
                })
                .collect(),
            counters: self
                .counters
                .iter()
                .map(|(key, counter)| CounterCheckpoint {
                    series_key: key.clone(),
                    value: counter.value,
                    timestamp: counter.timestamp,
                    reset_anchor: counter.reset_anchor.clone(),
                })
                .collect(),
        }
    }

    /// Reseed detector + counter state from a checkpoint, skipping any series
    /// whose last reading is older than `max_age_ns` before `now_unix_nano` (a
    /// stale baseline would mis-score current traffic), honoring the `max_series`
    /// cap, and truncating a restored window to the current `window_size` in case
    /// the configured window shrank. Returns the number of detector series
    /// reseeded. Existing in-memory state for a key is overwritten.
    pub fn restore_checkpoint(
        &mut self,
        checkpoint: EngineCheckpoint,
        now_unix_nano: u64,
        max_age_ns: u64,
    ) -> usize {
        let fresh = |ts: u64| now_unix_nano.saturating_sub(ts) <= max_age_ns;
        let mut restored = 0;

        for series in checkpoint.series {
            if !fresh(series.last_observed_at_unix_nano) {
                continue;
            }
            if !self.series.contains_key(&series.series_key)
                && self.series.len() >= self.config.max_series
            {
                continue;
            }

            let mut window_tail = series.window_tail;
            if window_tail.len() > self.config.window_size {
                let drop = window_tail.len() - self.config.window_size;
                window_tail.drain(0..drop);
            }

            self.series.insert(
                series.series_key,
                SeriesState {
                    window_tail,
                    consecutive_anomalous: series.consecutive_anomalous,
                    last_observed_at_unix_nano: series.last_observed_at_unix_nano,
                },
            );
            restored += 1;
        }

        for counter in checkpoint.counters {
            if !fresh(counter.timestamp) {
                continue;
            }
            self.counters.insert(
                counter.series_key,
                CounterState {
                    value: counter.value,
                    timestamp: counter.timestamp,
                    reset_anchor: counter.reset_anchor,
                },
            );
        }

        restored
    }
}

/// A reset is only declared when both anchors are known AND differ; an empty
/// anchor on either side is "unknown" and never forces a reset (matches central's
/// nil-tolerant `reset_anchor_changed?`).
fn reset_anchor_changed(previous: &str, current: &str) -> bool {
    !previous.is_empty() && !current.is_empty() && previous != current
}

/// The counter increment over one interval: a normal increase is `current -
/// previous`; a decrease is salvaged only as a plausible 32-bit wrap (the wrapped
/// delta must imply a per-second rate within the modulus). A 64-bit decrease, or
/// an implausible 32-bit decrease, yields `None` (drop the interval).
fn counter_delta(
    previous: f64,
    current: f64,
    counter_width: u32,
    elapsed_seconds: f64,
) -> Option<f64> {
    if current >= previous {
        return Some(current - previous);
    }

    if counter_width == 32 {
        let wrapped = COUNTER32_MODULUS - previous + current;
        if elapsed_seconds > 0.0 && wrapped / elapsed_seconds <= COUNTER32_MODULUS {
            return Some(wrapped);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_baseline_then_spike_breaches() {
        let mut engine = DetectorEngine::new(EngineConfig {
            window_size: 50,
            min_samples: 5,
            n_sigma: 3.0,
            confirm_slots: 1,
            max_series: 10,
        });

        // Warm a steady baseline with slight noise so stddev > 0.
        for i in 0..30 {
            let v = 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 };
            let verdict = engine.evaluate("s1", v, i as u64).expect("verdict");
            assert!(
                !verdict.anomalous,
                "steady samples must not confirm anomaly"
            );
        }

        // A large spike must breach.
        let verdict = engine.evaluate("s1", 10_000.0, 999).expect("verdict");
        assert!(verdict.breached, "a 100x spike must breach the baseline");
    }

    #[test]
    fn engine_score_matches_anomaly_core_zscore() {
        // Parity: the edge engine's verdict score must equal anomaly-core's
        // z-score over the same window — i.e. edge math == central math, since
        // both call the one shared detector crate.
        use serviceradar_anomaly_core::{sample_stats, z_score};

        let mut engine = DetectorEngine::new(EngineConfig {
            window_size: 100,
            min_samples: 5,
            n_sigma: 3.0,
            confirm_slots: 1,
            max_series: 10,
        });
        let baseline: Vec<f64> = (0..40).map(|i| 50.0 + (i % 5) as f64).collect();
        for (i, &v) in baseline.iter().enumerate() {
            engine.evaluate("s", v, i as u64);
        }

        let probe = 80.0;
        let verdict = engine.evaluate("s", probe, 999).expect("verdict");

        // The window at probe time is the 40 clean baseline samples; the rolling
        // signal (the only enabled one) scores via anomaly-core's z_score.
        let expected = z_score(probe, sample_stats(&baseline), 3.0);
        assert!(
            (verdict.score - expected).abs() < 1e-6,
            "edge score {} must equal anomaly-core z_score {expected}",
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
        };
        let mut engine = DetectorEngine::new(cfg.clone());
        for i in 0..30 {
            let v = 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 };
            engine.evaluate("s1", v, i as u64);
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
        let verdict = restored.evaluate("s1", 10_000.0, 999).expect("verdict");
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
        engine.evaluate("old", 5.0, 0);
        engine.evaluate("old", 6.0, 1);
        let checkpoint = engine.export_checkpoint();

        // `now` far ahead with a small max_age: the series is stale and skipped.
        let mut restored = DetectorEngine::new(EngineConfig::default());
        let n = restored.restore_checkpoint(checkpoint, 1_000_000_000_000, 1_000);
        assert_eq!(n, 0);
        assert_eq!(restored.series_count(), 0);
    }

    #[test]
    fn capacity_cap_drops_new_series() {
        let mut engine = DetectorEngine::new(EngineConfig {
            max_series: 2,
            ..EngineConfig::default()
        });
        assert!(engine.evaluate("a", 1.0, 1).is_some());
        assert!(engine.evaluate("b", 1.0, 1).is_some());
        // Third distinct series is dropped at the cap.
        assert!(engine.evaluate("c", 1.0, 1).is_none());
        assert_eq!(engine.dropped_at_capacity, 1);
        // Existing series still evaluate.
        assert!(engine.evaluate("a", 2.0, 2).is_some());
    }
}
