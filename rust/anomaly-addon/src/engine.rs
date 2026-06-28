// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Per-series detector state, driven by the shared `serviceradar-anomaly-core`
//! stateless reason path. This keeps the rolling robust z-score scoring in Rust at
//! the edge. (The `CausalFlow` pipeline combinator hosts the statistics; it is not
//! causal inference.)

use std::collections::HashMap;

use serviceradar_anomaly_core::{
    DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    ReasonContext, ReasonSample, ReasonVerdict, SaturationGate, reason_impl,
};

/// Lifecycle transition produced by edge state after scoring one sample.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AnomalyTransition {
    /// No externally visible lifecycle change.
    None,
    /// A series moved from clean/inactive into confirmed anomalous.
    Open,
    /// A previously active anomaly returned clean.
    Clear,
}

/// A scored verdict plus the edge lifecycle transition it caused.
#[derive(Debug, PartialEq)]
pub struct TransitionVerdict {
    pub verdict: ReasonVerdict,
    pub transition: AnomalyTransition,
    pub episode: Option<AnomalyEpisode>,
}

/// The edge-observed anomaly episode that led to an externally visible
/// transition. This is lifecycle metadata, not an additional detector: the
/// shared anomaly-core verdict still owns the statistical decision.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnomalyEpisode {
    pub started_at_unix_nano: u64,
    pub ended_at_unix_nano: u64,
    pub peak_value: f64,
    pub peak_at_unix_nano: u64,
}

/// Per-series fidelity tuning the detector applies on top of the global
/// [`EngineConfig`]. The add-on computes this from the metric class (it knows
/// `metric_type` + whether the series is a rate-normalized counter), so the
/// class-agnostic core never needs to know what a "gauge" is. The default (zero
/// floors, no saturation gate) reproduces the prior pure-symmetric-z behavior
/// exactly, so any series the add-on does not specially classify is unchanged.
#[derive(Clone, Copy, Debug, Default)]
pub struct SeriesProfile {
    /// Absolute dispersion floor in the metric's own units (fix #2).
    pub min_std_floor: f64,
    /// Relative (coefficient-of-variation) dispersion floor (fix #2).
    pub min_cv: f64,
    /// Absolute/directional saturation gate (fix #3); `None` = purely z-based
    /// (counters / interface rates — a real flood must still fire on z alone).
    pub saturation_gate: Option<SaturationGate>,
    /// Optional per-series evaluation interval. When set, raw points are collapsed
    /// into one spike-preserving max value per interval before the shared detector
    /// evaluates them. This makes `confirm_slots` count completed evaluation slots
    /// instead of high-frequency raw samples.
    pub evaluation_interval_ns: Option<u64>,
}

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
    /// Operator-set GLOBAL dispersion-floor overrides (fix #2). When `Some` and
    /// larger than a series' built-in per-class floor, this value wins, letting an
    /// operator raise the floor fleet-wide without per-class tuning. `None` leaves
    /// each series on its built-in default (0 for non-gauges, the gauge defaults
    /// for cpu/mem/disk). The override only ever *raises* a floor, never lowers a
    /// gauge's safe default.
    pub min_std_floor: Option<f64>,
    pub min_cv: Option<f64>,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            window_size: DEFAULT_WINDOW_SIZE,
            min_samples: DEFAULT_MIN_SAMPLES,
            n_sigma: DEFAULT_N_SIGMA,
            confirm_slots: DEFAULT_CONFIRM_SLOTS,
            max_series: 50_000,
            min_std_floor: None,
            min_cv: None,
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

/// A series/counter that has not been observed for this long is eligible for
/// eviction when a new key would otherwise hit the memory cap. This matches the
/// counter discontinuity gap: after two hours the old sample is no longer useful
/// for rate derivation or anomaly baseline continuity.
const STATE_EVICTION_MAX_AGE_NS: u64 = COUNTER_MAX_GAP_NS;

/// The retained baseline for one series. The rolling accumulator is recomputed
/// from `window_tail` each evaluation (the stateless path), so only the bounded
/// window tail and the confirm-slot counter need to persist between samples.
struct SeriesState {
    window_tail: Vec<f64>,
    consecutive_anomalous: usize,
    consecutive_clean: usize,
    /// Whether this series currently has an emitted-but-not-cleared anomaly.
    active_anomalous: bool,
    pending_episode_started_at_unix_nano: Option<u64>,
    pending_episode_peak_value: Option<f64>,
    pending_episode_peak_at_unix_nano: Option<u64>,
    active_episode_started_at_unix_nano: Option<u64>,
    active_episode_peak_value: Option<f64>,
    active_episode_peak_at_unix_nano: Option<u64>,
    aggregation_slot_start_unix_nano: Option<u64>,
    aggregation_slot_value: Option<f64>,
    aggregation_slot_peak_at_unix_nano: Option<u64>,
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
    /// Last sample timestamp that attempted stale-state eviction at capacity.
    /// Metric-feed frames commonly carry many new keys with the same observation
    /// time; scanning both maps once per timestamp bounds a fruitless full scan
    /// under cap-pressure churn.
    last_capacity_eviction_at_unix_nano: Option<u64>,
    /// Number of new series dropped because the `max_series` cap was reached.
    pub dropped_at_capacity: u64,
}

impl DetectorEngine {
    pub fn new(config: EngineConfig) -> Self {
        Self {
            config,
            series: HashMap::new(),
            counters: HashMap::new(),
            last_capacity_eviction_at_unix_nano: None,
            dropped_at_capacity: 0,
        }
    }

    pub fn set_config(&mut self, config: EngineConfig) {
        self.config = config;
    }

    pub fn config(&self) -> EngineConfig {
        self.config.clone()
    }

    pub fn series_count(&self) -> usize {
        self.series.len()
    }

    pub fn counter_count(&self) -> usize {
        self.counters.len()
    }

    pub fn max_series(&self) -> usize {
        self.config.max_series
    }

    fn evict_stale_state(&mut self, now_unix_nano: u64) {
        self.series.retain(|_, state| {
            now_unix_nano.saturating_sub(state.last_observed_at_unix_nano)
                <= STATE_EVICTION_MAX_AGE_NS
        });
        self.counters.retain(|_, counter| {
            now_unix_nano.saturating_sub(counter.timestamp) <= STATE_EVICTION_MAX_AGE_NS
        });
    }

    fn evict_stale_state_once_per_timestamp(&mut self, now_unix_nano: u64) {
        if self.last_capacity_eviction_at_unix_nano == Some(now_unix_nano) {
            return;
        }

        self.last_capacity_eviction_at_unix_nano = Some(now_unix_nano);
        self.evict_stale_state(now_unix_nano);
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
        self.normalize_counter_with_max_rate(
            series_key,
            raw_value,
            observed_at_unix_nano,
            reset_anchor,
            counter_width,
            None,
        )
    }

    /// Same as [`Self::normalize_counter`], but lets the caller pass a
    /// per-sample plausible maximum rate when the producer knows the physical
    /// counter bound (for example an interface speed).
    pub fn normalize_counter_with_max_rate(
        &mut self,
        series_key: &str,
        raw_value: f64,
        observed_at_unix_nano: u64,
        reset_anchor: &str,
        counter_width: u32,
        max_counter_rate_per_second: Option<f64>,
    ) -> Option<f64> {
        if !raw_value.is_finite() || raw_value < 0.0 {
            return None;
        }

        let Some(previous) = self.counters.get_mut(series_key) else {
            // Warmup: store the first reading, emit nothing (a rate needs two).
            if self.counters.len() >= self.config.max_series {
                self.evict_stale_state_once_per_timestamp(observed_at_unix_nano);
            }
            if self.counters.len() >= self.config.max_series {
                self.dropped_at_capacity = self.dropped_at_capacity.saturating_add(1);
                return None;
            }
            self.counters.insert(
                series_key.to_owned(),
                CounterState {
                    value: raw_value,
                    timestamp: observed_at_unix_nano,
                    reset_anchor: reset_anchor.to_owned(),
                },
            );
            return None;
        };

        // Reset lineage changed (counter restart): store, drop — a rate across a
        // reset is meaningless.
        if reset_anchor_changed(&previous.reset_anchor, reset_anchor) {
            previous.value = raw_value;
            previous.timestamp = observed_at_unix_nano;
            replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);
            return None;
        }

        // Non-monotonic time: drop WITHOUT advancing, keeping the older valid
        // reading as the baseline (matches central) — UNLESS the stored baseline is
        // implausibly far AHEAD of this reading (more than COUNTER_MAX_GAP_NS). A
        // single point carrying a bad future timestamp would otherwise become the
        // baseline and silently drop every subsequent real reading (each is "older")
        // until wall-clock catches up — and that poisoned future timestamp is immune
        // to age-based eviction and survives the checkpoint. When the backward jump
        // is that large the STORED timestamp is the suspect, so re-anchor to this
        // reading (symmetric with the over-long forward gap below) and recover on the
        // next real point. A small backward step (clock skew) still drops, as before.
        if observed_at_unix_nano <= previous.timestamp {
            if previous.timestamp - observed_at_unix_nano > COUNTER_MAX_GAP_NS {
                previous.value = raw_value;
                previous.timestamp = observed_at_unix_nano;
                replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);
            }
            return None;
        }

        // Over-long gap: store, drop — treat as a discontinuity, not a rate.
        if observed_at_unix_nano - previous.timestamp > COUNTER_MAX_GAP_NS {
            previous.value = raw_value;
            previous.timestamp = observed_at_unix_nano;
            replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);
            return None;
        }

        let elapsed_seconds = (observed_at_unix_nano - previous.timestamp) as f64 / 1_000_000_000.0;
        let delta = counter_delta(
            previous.value,
            raw_value,
            counter_width,
            elapsed_seconds,
            max_counter_rate_per_second,
        );

        // Advance across the interval whether or not a delta was salvageable
        // (central stores `current` on both the ok and decrease-drop branches).
        previous.value = raw_value;
        previous.timestamp = observed_at_unix_nano;
        replace_reset_anchor(&mut previous.reset_anchor, reset_anchor);

        match delta {
            Some(d) if elapsed_seconds > 0.0 => Some(d / elapsed_seconds),
            _ => None,
        }
    }

    /// Evaluate one sample for `series_key`, advancing the stored baseline.
    /// Returns the verdict, or `None` if the value is non-finite, the detector
    /// errored, or the series was dropped at the capacity cap.
    ///
    /// `profile` carries the per-series fidelity knobs (dispersion floors + the
    /// optional saturation gate) the add-on derived from the metric class. Pass
    /// [`SeriesProfile::default`] for a purely z-based series (no floors, no gate).
    pub fn evaluate(
        &mut self,
        series_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
        profile: SeriesProfile,
    ) -> Option<ReasonVerdict> {
        if !value.is_finite() {
            return None;
        }

        if !self.series.contains_key(series_key) {
            if self.series.len() >= self.config.max_series {
                self.evict_stale_state_once_per_timestamp(observed_at_unix_nano);
            }
            if self.series.len() >= self.config.max_series {
                self.dropped_at_capacity = self.dropped_at_capacity.saturating_add(1);
                return None;
            }
        }

        let state = self
            .series
            .entry(series_key.to_owned())
            .or_insert_with(|| SeriesState {
                window_tail: Vec::new(),
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
                last_observed_at_unix_nano: observed_at_unix_nano,
            });

        // A global operator floor override (fix #2) only ever RAISES the floor:
        // take the max of the series' built-in per-class floor and any configured
        // override, so an operator can tighten the fleet without lowering a
        // gauge's safe default.
        let min_std_floor = self
            .config
            .min_std_floor
            .map_or(profile.min_std_floor, |o| profile.min_std_floor.max(o));
        let min_cv = self
            .config
            .min_cv
            .map_or(profile.min_cv, |o| profile.min_cv.max(o));

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
            min_std_floor: Some(min_std_floor),
            min_cv: Some(min_cv),
            saturation_gate: profile.saturation_gate,
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

    /// Evaluate one sample and update per-series anomaly lifecycle state.
    ///
    /// The detector core still decides whether a sample is clean, pending, or
    /// confirmed anomalous. The edge add-on owns only delivery lifecycle: one
    /// open when a series first confirms, no duplicate opens while it remains
    /// active, and one clear when that active series stays clean for the same
    /// confirmation window used to open.
    pub fn evaluate_transition(
        &mut self,
        series_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
        profile: SeriesProfile,
    ) -> Option<TransitionVerdict> {
        let (value, observed_at_unix_nano) =
            self.next_evaluation_sample(series_key, value, observed_at_unix_nano, profile)?;
        let verdict = self.evaluate(series_key, value, observed_at_unix_nano, profile)?;
        let state = self.series.get_mut(series_key)?;
        let clear_slots = self.config.confirm_slots.max(1);
        let mut episode = None;

        if verdict.breached {
            if state.active_anomalous {
                observe_active_breach(state, value, observed_at_unix_nano);
            } else {
                observe_pending_breach(state, value, observed_at_unix_nano);
            }
        } else if !state.active_anomalous {
            reset_pending_episode(state);
        }

        let transition = if verdict.anomalous && !state.active_anomalous {
            promote_pending_episode(state, value, observed_at_unix_nano);
            episode = active_episode(state, observed_at_unix_nano);
            state.active_anomalous = true;
            state.consecutive_clean = 0;
            AnomalyTransition::Open
        } else if state.active_anomalous {
            if is_clean_verdict(&verdict) {
                state.consecutive_clean = state.consecutive_clean.saturating_add(1);

                if state.consecutive_clean >= clear_slots {
                    episode = active_episode(state, observed_at_unix_nano);
                    state.active_anomalous = false;
                    state.consecutive_clean = 0;
                    reset_active_episode(state);
                    AnomalyTransition::Clear
                } else {
                    AnomalyTransition::None
                }
            } else {
                state.consecutive_clean = 0;
                AnomalyTransition::None
            }
        } else {
            state.consecutive_clean = 0;
            AnomalyTransition::None
        };

        Some(TransitionVerdict {
            verdict,
            transition,
            episode,
        })
    }

    fn next_evaluation_sample(
        &mut self,
        series_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
        profile: SeriesProfile,
    ) -> Option<(f64, u64)> {
        let Some(interval_ns) = profile
            .evaluation_interval_ns
            .filter(|interval| *interval > 0)
        else {
            return Some((value, observed_at_unix_nano));
        };

        if !value.is_finite() {
            return None;
        }

        if !self.series.contains_key(series_key) {
            if self.series.len() >= self.config.max_series {
                self.evict_stale_state_once_per_timestamp(observed_at_unix_nano);
            }
            if self.series.len() >= self.config.max_series {
                self.dropped_at_capacity = self.dropped_at_capacity.saturating_add(1);
                return None;
            }
        }

        let state = self
            .series
            .entry(series_key.to_owned())
            .or_insert_with(|| SeriesState {
                window_tail: Vec::new(),
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
                last_observed_at_unix_nano: observed_at_unix_nano,
            });

        let slot_start = observed_at_unix_nano - (observed_at_unix_nano % interval_ns);

        match state.aggregation_slot_start_unix_nano {
            None => {
                store_aggregation_slot(state, slot_start, value, observed_at_unix_nano);
                state.last_observed_at_unix_nano = observed_at_unix_nano;
                None
            }
            Some(current_slot) if current_slot == slot_start => {
                update_aggregation_slot(state, value, observed_at_unix_nano);
                state.last_observed_at_unix_nano = observed_at_unix_nano;
                None
            }
            Some(current_slot) if slot_start > current_slot => {
                let ready = match (
                    state.aggregation_slot_value,
                    state.aggregation_slot_peak_at_unix_nano,
                ) {
                    (Some(slot_value), Some(slot_peak_at)) => Some((slot_value, slot_peak_at)),
                    _ => None,
                };
                store_aggregation_slot(state, slot_start, value, observed_at_unix_nano);
                state.last_observed_at_unix_nano = observed_at_unix_nano;
                ready
            }
            Some(_) => {
                // Out-of-order sample for an already-closed slot. Drop it rather
                // than mutate historical detector state.
                None
            }
        }
    }
}

fn store_aggregation_slot(
    state: &mut SeriesState,
    slot_start_unix_nano: u64,
    value: f64,
    peak_at_unix_nano: u64,
) {
    state.aggregation_slot_start_unix_nano = Some(slot_start_unix_nano);
    state.aggregation_slot_value = Some(value);
    state.aggregation_slot_peak_at_unix_nano = Some(peak_at_unix_nano);
}

fn update_aggregation_slot(state: &mut SeriesState, value: f64, observed_at_unix_nano: u64) {
    if state
        .aggregation_slot_value
        .is_none_or(|current| value > current)
    {
        state.aggregation_slot_value = Some(value);
        state.aggregation_slot_peak_at_unix_nano = Some(observed_at_unix_nano);
    }
}

fn observe_pending_breach(state: &mut SeriesState, value: f64, observed_at_unix_nano: u64) {
    if state.pending_episode_started_at_unix_nano.is_none() {
        state.pending_episode_started_at_unix_nano = Some(observed_at_unix_nano);
    }

    update_peak(
        &mut state.pending_episode_peak_value,
        &mut state.pending_episode_peak_at_unix_nano,
        value,
        observed_at_unix_nano,
    );
}

fn observe_active_breach(state: &mut SeriesState, value: f64, observed_at_unix_nano: u64) {
    update_peak(
        &mut state.active_episode_peak_value,
        &mut state.active_episode_peak_at_unix_nano,
        value,
        observed_at_unix_nano,
    );
}

fn promote_pending_episode(state: &mut SeriesState, value: f64, observed_at_unix_nano: u64) {
    state.active_episode_started_at_unix_nano = Some(
        state
            .pending_episode_started_at_unix_nano
            .unwrap_or(observed_at_unix_nano),
    );
    state.active_episode_peak_value = Some(state.pending_episode_peak_value.unwrap_or(value));
    state.active_episode_peak_at_unix_nano = Some(
        state
            .pending_episode_peak_at_unix_nano
            .unwrap_or(observed_at_unix_nano),
    );
    reset_pending_episode(state);
}

fn active_episode(state: &SeriesState, ended_at_unix_nano: u64) -> Option<AnomalyEpisode> {
    Some(AnomalyEpisode {
        started_at_unix_nano: state.active_episode_started_at_unix_nano?,
        ended_at_unix_nano,
        peak_value: state.active_episode_peak_value?,
        peak_at_unix_nano: state.active_episode_peak_at_unix_nano?,
    })
}

fn update_peak(
    peak_value: &mut Option<f64>,
    peak_at: &mut Option<u64>,
    value: f64,
    observed_at_unix_nano: u64,
) {
    if peak_value.is_none_or(|current| value > current) {
        *peak_value = Some(value);
        *peak_at = Some(observed_at_unix_nano);
    }
}

fn reset_pending_episode(state: &mut SeriesState) {
    state.pending_episode_started_at_unix_nano = None;
    state.pending_episode_peak_value = None;
    state.pending_episode_peak_at_unix_nano = None;
}

fn reset_active_episode(state: &mut SeriesState) {
    state.active_episode_started_at_unix_nano = None;
    state.active_episode_peak_value = None;
    state.active_episode_peak_at_unix_nano = None;
}

fn is_clean_verdict(verdict: &ReasonVerdict) -> bool {
    !verdict.anomalous && verdict.next_consecutive_anomalous == 0
}

/// One series' retained detector baseline, serialized for the restart checkpoint.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
pub struct SeriesCheckpoint {
    pub series_key: String,
    pub window_tail: Vec<f64>,
    pub consecutive_anomalous: usize,
    #[serde(default)]
    pub consecutive_clean: usize,
    #[serde(default)]
    pub active_anomalous: bool,
    #[serde(default)]
    pub pending_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub pending_episode_peak_value: Option<f64>,
    #[serde(default)]
    pub pending_episode_peak_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub active_episode_started_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub active_episode_peak_value: Option<f64>,
    #[serde(default)]
    pub active_episode_peak_at_unix_nano: Option<u64>,
    #[serde(default)]
    pub aggregation_slot_start_unix_nano: Option<u64>,
    #[serde(default)]
    pub aggregation_slot_value: Option<f64>,
    #[serde(default)]
    pub aggregation_slot_peak_at_unix_nano: Option<u64>,
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
                    consecutive_clean: state.consecutive_clean,
                    active_anomalous: state.active_anomalous,
                    pending_episode_started_at_unix_nano: state
                        .pending_episode_started_at_unix_nano,
                    pending_episode_peak_value: state.pending_episode_peak_value,
                    pending_episode_peak_at_unix_nano: state.pending_episode_peak_at_unix_nano,
                    active_episode_started_at_unix_nano: state.active_episode_started_at_unix_nano,
                    active_episode_peak_value: state.active_episode_peak_value,
                    active_episode_peak_at_unix_nano: state.active_episode_peak_at_unix_nano,
                    aggregation_slot_start_unix_nano: state.aggregation_slot_start_unix_nano,
                    aggregation_slot_value: state.aggregation_slot_value,
                    aggregation_slot_peak_at_unix_nano: state.aggregation_slot_peak_at_unix_nano,
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

        let mut series_entries = checkpoint.series;
        series_entries.sort_by(|left, right| {
            right
                .last_observed_at_unix_nano
                .cmp(&left.last_observed_at_unix_nano)
        });

        for series in series_entries {
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
                    consecutive_clean: series.consecutive_clean,
                    active_anomalous: series.active_anomalous,
                    pending_episode_started_at_unix_nano: series
                        .pending_episode_started_at_unix_nano,
                    pending_episode_peak_value: series.pending_episode_peak_value,
                    pending_episode_peak_at_unix_nano: series.pending_episode_peak_at_unix_nano,
                    active_episode_started_at_unix_nano: series.active_episode_started_at_unix_nano,
                    active_episode_peak_value: series.active_episode_peak_value,
                    active_episode_peak_at_unix_nano: series.active_episode_peak_at_unix_nano,
                    aggregation_slot_start_unix_nano: series.aggregation_slot_start_unix_nano,
                    aggregation_slot_value: series.aggregation_slot_value,
                    aggregation_slot_peak_at_unix_nano: series.aggregation_slot_peak_at_unix_nano,
                    last_observed_at_unix_nano: series.last_observed_at_unix_nano,
                },
            );
            restored += 1;
        }

        let mut counter_entries = checkpoint.counters;
        counter_entries.sort_by(|left, right| right.timestamp.cmp(&left.timestamp));

        for counter in counter_entries {
            if !fresh(counter.timestamp) {
                continue;
            }
            if !self.counters.contains_key(&counter.series_key)
                && self.counters.len() >= self.config.max_series
            {
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

fn replace_reset_anchor(target: &mut String, current: &str) {
    // An empty (unknown) anchor must NOT clobber a known one. `reset_anchor_changed`
    // treats empty on either side as "unknown, never a reset", so if we let an empty
    // anchor overwrite a stored "boot-1", a later genuine "boot-2" would compare
    // against "" and the real reset would be missed. Preserve the last known anchor
    // instead. (Also preserves the in-place no-realloc fast path on no change.)
    if current.is_empty() || target == current {
        return;
    }

    target.clear();
    target.push_str(current);
}

/// The counter increment over one interval: a normal increase is `current -
/// previous`; a decrease is salvaged only as a plausible 32-bit wrap (the wrapped
/// delta must imply a per-second rate within the supplied per-sample max, falling
/// back to the 32-bit modulus). A 64-bit/unknown-width decrease, or an implausible
/// 32-bit decrease, yields `None` (drop the interval).
fn counter_delta(
    previous: f64,
    current: f64,
    counter_width: u32,
    elapsed_seconds: f64,
    max_counter_rate_per_second: Option<f64>,
) -> Option<f64> {
    if elapsed_seconds <= 0.0 {
        return None;
    }

    if current >= previous {
        return plausible_counter_delta(
            current - previous,
            elapsed_seconds,
            valid_counter_max_rate(max_counter_rate_per_second),
        );
    }

    if counter_width == 32 {
        let wrapped = COUNTER32_MODULUS - previous + current;
        let max_rate =
            valid_counter_max_rate(max_counter_rate_per_second).unwrap_or(COUNTER32_MODULUS);

        return plausible_counter_delta(wrapped, elapsed_seconds, Some(max_rate));
    }

    None
}

fn valid_counter_max_rate(max_counter_rate_per_second: Option<f64>) -> Option<f64> {
    max_counter_rate_per_second.filter(|rate| rate.is_finite() && *rate > 0.0)
}

fn plausible_counter_delta(delta: f64, elapsed_seconds: f64, max_rate: Option<f64>) -> Option<f64> {
    if elapsed_seconds <= 0.0 {
        return None;
    }

    if max_rate.is_some_and(|rate| delta / elapsed_seconds > rate) {
        return None;
    }

    Some(delta)
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
        // signal (the only enabled one) scores via anomaly-core's z_score. The
        // default profile applies no floors (0.0/0.0), so the edge engine and the
        // bare 5-arg z_score must produce the identical score.
        let expected = z_score(probe, sample_stats(&baseline), 3.0, 0.0, 0.0);
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
            engine.normalize_counter_with_max_rate(
                "c",
                10_000.0,
                1_000_000_000,
                "b",
                64,
                Some(100.0),
            ),
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
}
