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
    Cusum, DEFAULT_CONFIRM_SLOTS, DEFAULT_MIN_SAMPLES, DEFAULT_N_SIGMA, DEFAULT_WINDOW_SIZE,
    ReasonContext, ReasonSample, ReasonVerdict, RobustStats, SeasonalBucket, hour_of_week,
    reason_impl,
};

mod checkpoint;
mod counter;
mod episode;
mod seasonal_profile;
mod state;
mod types;

pub use checkpoint::{CounterCheckpoint, EngineCheckpoint, SeriesCheckpoint};
pub use seasonal_profile::{
    DEFAULT_SEASONAL_MIN_BUCKET_SAMPLES, DEFAULT_SEASONAL_SYNTHETIC_LEN, SeasonalProfile,
    SeasonalSettings,
};
pub use types::{
    AnomalyEpisode, AnomalyTransition, CusumDirection, CusumDrift, SeriesProfile, TransitionVerdict,
};

use episode::{
    active_episode, is_clean_verdict, observe_active_breach, observe_pending_breach,
    promote_pending_episode, reset_active_episode, reset_pending_episode, store_aggregation_slot,
    update_aggregation_slot,
};
use seasonal_profile::SeasonalContext;
pub(crate) use state::STATE_EVICTION_MAX_AGE_NS;
use state::{CounterState, SeriesState};

#[cfg(test)]
pub(crate) use counter::{COUNTER32_MODULUS, plausible_counter_delta};

/// Default CUSUM slack (reference value `k`) in sigma units. The standard tabular
/// CUSUM value: only a standardized deviation beyond `k` accumulates.
pub const DEFAULT_CUSUM_K: f64 = 0.5;
/// Default CUSUM decision interval (`h`, the alarm threshold). The standard
/// value: an accumulator past `h` is a sustained-drift alarm. With `k = 0.5` this
/// detects a persistent ~1-sigma shift in ≈ `h / (δ - k)` samples.
pub const DEFAULT_CUSUM_H: f64 = 5.0;

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
    /// Run the two-sided CUSUM drift detector alongside the rolling z-score. A
    /// CUSUM alarm is a SUSTAINED-DRIFT anomaly the point z-score structurally
    /// misses (its rolling mean tracks a slow ramp). Additive: it never changes
    /// the z-score verdict. Disabled reproduces the prior rolling-only behavior.
    pub cusum_enabled: bool,
    /// CUSUM slack (reference value `k`) in sigma units.
    pub cusum_k: f64,
    /// CUSUM decision interval (`h`, the alarm threshold).
    pub cusum_h: f64,
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
            // The Rust default keeps CUSUM OFF so the bare-default engine (used by
            // fixtures/tests) is byte-for-byte the prior rolling-only detector. The
            // operator-facing config default is ON (see `AddonConfig::into_engine_config`),
            // so production runs the drift detector unless explicitly disabled.
            cusum_enabled: false,
            cusum_k: DEFAULT_CUSUM_K,
            cusum_h: DEFAULT_CUSUM_H,
        }
    }
}

/// Bounded map of per-series detector state.
pub struct DetectorEngine {
    config: EngineConfig,
    pub(crate) series: HashMap<String, SeriesState>,
    /// Per-series hour-of-week seasonal baselines delivered from core. Empty (the
    /// default) keeps every series on the rolling-only path — back-compat.
    seasonal: HashMap<String, SeasonalProfile>,
    /// Thresholds governing the seasonal signal when a baseline is delivered.
    seasonal_settings: SeasonalSettings,
    /// Last cumulative-counter reading per series, for rate normalization.
    pub(crate) counters: HashMap<String, CounterState>,
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
            seasonal: HashMap::new(),
            seasonal_settings: SeasonalSettings::default(),
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

    /// Replace the per-series hour-of-week seasonal baselines delivered from core.
    /// An empty map clears all baselines (every series reverts to the rolling-only
    /// path); series without a delivered baseline are unaffected. Idempotent and
    /// fully back-compat: with no baselines this engine scores exactly as before.
    pub fn set_seasonal_baselines(&mut self, baselines: HashMap<String, SeasonalProfile>) {
        self.seasonal = baselines;
    }

    /// Override the thresholds applied to the seasonal signal (sigma, minimum
    /// bucket history, synthetic window length).
    pub fn set_seasonal_settings(&mut self, settings: SeasonalSettings) {
        self.seasonal_settings = settings;
    }

    /// Number of series with a delivered seasonal baseline.
    pub fn seasonal_series_count(&self) -> usize {
        self.seasonal.len()
    }

    /// Resolve the optional seasonal-signal context for one sample: the synthetic
    /// baseline window plus its enable/min-samples/threshold knobs, or all-`None`
    /// (the back-compat rolling-only path) when no usable bucket is delivered for
    /// this series at this sample's hour-of-week.
    /// The delivered hour-of-week seasonal bucket for this `seasonal_key` at this
    /// sample's time, when one is delivered AND trusted (enough history). Shared by
    /// the seasonal z-score signal and the CUSUM deseasonalize target. `None`
    /// (the back-compat rolling-only path) when no usable bucket resolves.
    fn seasonal_bucket(
        &self,
        seasonal_key: &str,
        observed_at_unix_nano: u64,
    ) -> Option<SeasonalBucket> {
        // No baselines delivered, or a window too small to ever hold a >=2-point
        // seasonal baseline: stay on the rolling-only path.
        if self.seasonal.is_empty() || self.config.window_size < 2 {
            return None;
        }

        let bucket = self
            .seasonal
            .get(seasonal_key)?
            .bucket(hour_of_week(observed_at_unix_nano))?;
        bucket
            .usable(self.seasonal_settings.min_bucket_samples)
            .then_some(bucket)
    }

    fn seasonal_context(
        &self,
        seasonal_key: &str,
        observed_at_unix_nano: u64,
    ) -> Option<SeasonalContext> {
        let bucket = self.seasonal_bucket(seasonal_key, observed_at_unix_nano)?;

        let len = self
            .seasonal_settings
            .synthetic_len
            .clamp(2, self.config.window_size);
        let n_sigma = self
            .seasonal_settings
            .n_sigma
            .filter(|value| value.is_finite() && *value > 0.0)
            .unwrap_or(self.config.n_sigma);

        Some(SeasonalContext {
            baseline: bucket.synthetic_window(len),
            min_samples: len,
            n_sigma,
        })
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
        // Default seasonal key == detector key, preserving the prior behavior for
        // every caller (tests, checkpoint round-trips) that does not separately
        // reconcile the central device-uid keyspace.
        self.evaluate_with_seasonal_key(
            series_key,
            series_key,
            value,
            observed_at_unix_nano,
            profile,
        )
    }

    /// [`Self::evaluate`], but the delivered hour-of-week seasonal baseline is
    /// looked up by `seasonal_key` (the canonical `<device_uid>|<metric_name>`
    /// the core producer keys by — see [`crate::identity::seasonal_series_key`])
    /// while the rolling detector state stays keyed by the finer `series_key`.
    /// This is what reconciles the edge detector keyspace with central's
    /// `series:uid` profile keyspace so a delivered baseline actually resolves.
    pub fn evaluate_with_seasonal_key(
        &mut self,
        series_key: &str,
        seasonal_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
        profile: SeriesProfile,
    ) -> Option<ReasonVerdict> {
        self.evaluate_inner(
            series_key,
            seasonal_key,
            value,
            observed_at_unix_nano,
            profile,
        )
        .map(|(verdict, _drift)| verdict)
    }

    /// The full scoring path shared by [`Self::evaluate_with_seasonal_key`] and
    /// [`Self::evaluate_transition_with_seasonal_key`]: the rolling/seasonal
    /// z-score verdict plus the optional CUSUM sustained-drift alarm. CUSUM is
    /// advanced here (not at the transition layer) so its per-series state stays
    /// consistent regardless of which public entry point scored the sample.
    fn evaluate_inner(
        &mut self,
        series_key: &str,
        seasonal_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
        profile: SeriesProfile,
    ) -> Option<(ReasonVerdict, Option<CusumDrift>)> {
        if !value.is_finite() {
            return None;
        }

        // Resolve the optional hour-of-week seasonal context up front, while only
        // `&self` is borrowed: looking it up after the `state` entry below would
        // conflict with that `&mut self.series` borrow. All-`None` when no usable
        // baseline is delivered (the back-compat rolling-only path).
        let (seasonal_baseline, seasonal_enabled, seasonal_min_samples, seasonal_n_sigma) =
            match self.seasonal_context(seasonal_key, observed_at_unix_nano) {
                Some(ctx) => (
                    Some(ctx.baseline),
                    Some(true),
                    Some(ctx.min_samples),
                    Some(ctx.n_sigma),
                ),
                None => (None, None, None, None),
            };
        // The CUSUM deseasonalize target: the delivered hour-of-week bucket center
        // when one resolves for this sample, else the frozen rolling anchor mean
        // (resolved below). Looked up here while only `&self` is borrowed.
        let cusum_target_center = if self.config.cusum_enabled {
            self.seasonal_bucket(seasonal_key, observed_at_unix_nano)
                .map(|bucket| bucket.center)
        } else {
            None
        };

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
                cusum: None,
                cusum_anchor: None,
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

        // --- CUSUM sustained-drift detector ---------------------------------
        // Runs on the PRE-sample window (the rolling baseline before this sample is
        // folded in). Anchors to the frozen (mean, floored-scale) the first time the
        // rolling baseline reaches `min_samples`, then standardizes each sample's
        // residual `(value - target) / scale` — `target` is the delivered seasonal
        // bucket center when present (deseasonalize), else the frozen anchor mean.
        // A rolling z-score's mean tracks a slow ramp and never trips; the anchored
        // CUSUM accumulates that drift until it crosses `h` and alarms. Captured
        // here, gated on the z-score verdict below.
        let mut cusum_alarm: Option<(f64, f64)> = None;
        if self.config.cusum_enabled {
            if state.cusum_anchor.is_none() && state.window_tail.len() >= self.config.min_samples {
                // Anchor to the ROBUST center/scale (median + MAD*1.4826), matching the
                // rolling detector's dispersion: the frozen reference and the fallback
                // deseasonalize target are the robust center now, so a first spike in
                // the warmup window cannot poison the CUSUM anchor.
                let stats = RobustStats::from_values(&state.window_tail);
                let scale = stats
                    .effective_scale(min_std_floor, min_cv)
                    .max(f64::EPSILON);
                state.cusum_anchor = Some((stats.center, scale));
                state.cusum = Some(Cusum::with_state(
                    self.config.cusum_k,
                    self.config.cusum_h,
                    0.0,
                    0.0,
                ));
            }
            if let (Some((anchor_mean, scale)), Some(cusum)) =
                (state.cusum_anchor, state.cusum.as_mut())
            {
                let target = cusum_target_center.unwrap_or(anchor_mean);
                let step = cusum.update((value - target) / scale);
                if step.alarm {
                    cusum_alarm = Some((step.pos, step.neg));
                }
            }
        }

        let context = ReasonContext {
            baseline: Vec::new(),
            rolling_acc: None,
            window_tail: Some(state.window_tail.clone()),
            seasonal_baseline,
            trend_baseline: None,
            rolling_enabled: Some(true),
            seasonal_enabled,
            trend_enabled: None,
            min_samples: Some(self.config.min_samples),
            seasonal_min_samples,
            trend_min_samples: None,
            window_size: Some(self.config.window_size),
            n_sigma: Some(self.config.n_sigma),
            seasonal_n_sigma,
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
            Ok(mut verdict) => {
                // Move the recomputed window tail into the retained state instead of
                // cloning it: `next_window_tail` is never read downstream of this
                // (the verdict record path reads score/state/reason only), so the
                // emptied field on the returned verdict is unobservable.
                state.window_tail = std::mem::take(&mut verdict.next_window_tail);
                state.consecutive_anomalous = verdict.next_consecutive_anomalous;
                state.last_observed_at_unix_nano = observed_at_unix_nano;

                // Additive but de-duplicated: a CUSUM drift finding reports exactly
                // the sustained drift the point z-score MISSES, so suppress it when
                // the z-score itself breached this sample (already an edge-spike).
                let cusum_drift =
                    cusum_alarm
                        .filter(|_| !verdict.breached)
                        .map(|(pos, neg)| CusumDrift {
                            pos,
                            neg,
                            direction: if pos >= neg {
                                CusumDirection::Up
                            } else {
                                CusumDirection::Down
                            },
                        });

                Some((verdict, cusum_drift))
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
        // Default seasonal key == detector key (back-compat for existing callers).
        self.evaluate_transition_with_seasonal_key(
            series_key,
            series_key,
            value,
            observed_at_unix_nano,
            profile,
        )
    }

    /// [`Self::evaluate_transition`], but the delivered seasonal baseline is
    /// resolved by `seasonal_key` (the canonical `<device_uid>|<metric_name>`)
    /// rather than the finer detector `series_key`. The edge feed path uses this
    /// so the central hour-of-week baseline keyed by `series:uid` resolves while
    /// per-core/per-dimension detector state stays separated by `series_key`.
    pub fn evaluate_transition_with_seasonal_key(
        &mut self,
        series_key: &str,
        seasonal_key: &str,
        value: f64,
        observed_at_unix_nano: u64,
        profile: SeriesProfile,
    ) -> Option<TransitionVerdict> {
        let (value, observed_at_unix_nano) =
            self.next_evaluation_sample(series_key, value, observed_at_unix_nano, profile)?;
        let (verdict, cusum_drift) = self.evaluate_inner(
            series_key,
            seasonal_key,
            value,
            observed_at_unix_nano,
            profile,
        )?;
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
            cusum_drift,
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
                cusum: None,
                cusum_anchor: None,
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
