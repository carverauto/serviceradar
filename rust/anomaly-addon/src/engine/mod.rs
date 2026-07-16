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
    ReasonContext, ReasonSample, ReasonVerdict, RobustStats, SeasonalBucket,
    effective_scoring_scale, hour_of_week, reason_impl,
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
    AnomalyEpisode, AnomalyTransition, CusumDirection, CusumDrift, DriftClearReason, DriftMode,
    DriftUpdateReason, MetricClassOverride, SeriesProfile, SeverityPolicy, SpikeClearReason,
    SpikeUpdateReason, TransitionVerdict,
};

use episode::{
    active_episode, is_clean_verdict, observe_active_breach, observe_pending_breach,
    promote_pending_episode_with_start, reset_active_episode, reset_pending_episode,
    store_aggregation_slot, update_aggregation_slot,
};
use seasonal_profile::SeasonalContext;
use state::{CounterState, HostCpuSlotState, SeriesState};
pub(crate) use state::{HostCpuAggregateSample, STATE_EVICTION_MAX_AGE_NS};

use counter::CounterDropCounts;

#[cfg(test)]
pub(crate) use counter::{COUNTER32_MODULUS, plausible_counter_delta};

/// Default CUSUM slack (reference value `k`) in sigma units. The standard tabular
/// CUSUM value: only a standardized deviation beyond `k` accumulates.
pub const DEFAULT_CUSUM_K: f64 = 0.5;
/// Default CUSUM decision interval (`h`, the alarm threshold). The standard
/// value: an accumulator past `h` is a sustained-drift alarm. With `k = 0.5` this
/// detects a persistent ~1-sigma shift in ≈ `h / (δ - k)` samples.
pub const DEFAULT_CUSUM_H: f64 = 8.0;
pub const DEFAULT_H_CONFIRM_MULT: f64 = 1.5;
pub const DEFAULT_DRIFT_CONFIRM_WINDOW: u64 = 30;
pub const DEFAULT_DRIFT_MIN_EFFECT: f64 = 2.0;
pub const DEFAULT_DRIFT_CLEAR_SLOTS: u64 = 30;
pub const DEFAULT_DRIFT_ADOPT_AFTER_SAMPLES: u64 = 600;
pub const DEFAULT_SPIKE_ADOPT_AFTER_SAMPLES: u64 = 600;
pub const DEFAULT_EPISODE_UPDATE_INTERVAL_SECS: u64 = 1_800;
pub const DEFAULT_REOPEN_COOLDOWN_SECS: u64 = 600;
pub const DEFAULT_ANCHOR_MAX_AGE_SECS: u64 = 86_400;
pub const DEFAULT_CRITICAL_MIN_DURATION_SECS: u64 = 600;
pub const DEFAULT_DRIFT_ESCALATE_AFTER_SECS: u64 = 3_600;
pub const DEFAULT_EMISSION_COOLDOWN_SECS: u64 = 300;
pub const DEFAULT_EMISSION_BUDGET_PER_TICK: usize = 100;
const EMISSION_STORM_EXIT_FRAMES: u8 = 10;
pub const DEFAULT_METRIC_DENYLIST: &[&str] = &["cpu.frequency_hz"];

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
    /// CUSUM slack (reference value `k`) in sigma units.
    pub cusum_k: f64,
    /// CUSUM decision interval (`h`, the alarm threshold).
    pub cusum_h: f64,
    /// Confirmation threshold multiplier: pending drift emits only when the
    /// latched accumulator reaches `cusum_h * h_confirm_mult`.
    pub h_confirm_mult: f64,
    /// Number of samples after a drift latch may reach the confirmation
    /// threshold before the pending state silently decays/reset.
    pub drift_confirm_window: u64,
    /// Minimum estimated sustained shift, in sigma units, before a CUSUM alarm
    /// becomes an emitted drift finding.
    pub drift_min_effect: f64,
    /// Consecutive recovered samples before an open drift episode clears.
    pub drift_clear_slots: u64,
    /// Samples after open before a persistent new level is adopted and cleared.
    pub drift_adopt_after_samples: u64,
    /// Samples after a continuously anomalous rolling-spike episode before a
    /// stable, non-saturated level is adopted into the rolling baseline.
    pub spike_adopt_after_samples: u64,
    /// Minimum seconds between still-open drift heartbeat updates.
    pub episode_update_interval_secs: u64,
    /// Seconds after a clear during which a re-open reuses the episode identity.
    pub reopen_cooldown_secs: u64,
    /// Maximum age for an idle always-on rolling CUSUM anchor before it refreshes
    /// to the current rolling window.
    pub anchor_max_age_secs: u64,
    /// Minimum episode duration before a High spike can become Critical.
    pub critical_min_duration_secs: u64,
    /// Minimum open drift duration before Medium drift can escalate to High.
    pub drift_escalate_after_secs: u64,
    /// Minimum seconds between non-clear emissions for one detector series.
    pub emission_cooldown_secs: u64,
    /// Maximum non-clear anomaly records emitted per frame/tick before rollup.
    pub emission_budget_per_tick: usize,
    /// Metric names that should not produce detector findings.
    pub metric_denylist: Vec<String>,
    /// Per-class operator overrides projected by the control plane.
    pub metric_class_overrides: HashMap<String, MetricClassOverride>,
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
            cusum_k: DEFAULT_CUSUM_K,
            cusum_h: DEFAULT_CUSUM_H,
            h_confirm_mult: DEFAULT_H_CONFIRM_MULT,
            drift_confirm_window: DEFAULT_DRIFT_CONFIRM_WINDOW,
            drift_min_effect: DEFAULT_DRIFT_MIN_EFFECT,
            drift_clear_slots: DEFAULT_DRIFT_CLEAR_SLOTS,
            drift_adopt_after_samples: DEFAULT_DRIFT_ADOPT_AFTER_SAMPLES,
            spike_adopt_after_samples: DEFAULT_SPIKE_ADOPT_AFTER_SAMPLES,
            episode_update_interval_secs: DEFAULT_EPISODE_UPDATE_INTERVAL_SECS,
            reopen_cooldown_secs: DEFAULT_REOPEN_COOLDOWN_SECS,
            anchor_max_age_secs: DEFAULT_ANCHOR_MAX_AGE_SECS,
            critical_min_duration_secs: DEFAULT_CRITICAL_MIN_DURATION_SECS,
            drift_escalate_after_secs: DEFAULT_DRIFT_ESCALATE_AFTER_SECS,
            emission_cooldown_secs: DEFAULT_EMISSION_COOLDOWN_SECS,
            emission_budget_per_tick: DEFAULT_EMISSION_BUDGET_PER_TICK,
            metric_denylist: DEFAULT_METRIC_DENYLIST
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
            metric_class_overrides: HashMap::new(),
        }
    }
}

fn drift_shift_estimate(k: f64, accumulator: f64, samples: u64) -> f64 {
    let samples = samples.max(1) as f64;
    k.max(0.0) + accumulator.max(0.0) / samples
}

fn drift_direction_for(pos: f64, neg: f64) -> CusumDirection {
    if pos >= neg {
        CusumDirection::Up
    } else {
        CusumDirection::Down
    }
}

fn drift_accumulator_for(direction: CusumDirection, pos: f64, neg: f64) -> f64 {
    match direction {
        CusumDirection::Up => pos,
        CusumDirection::Down => neg,
    }
}

#[derive(Clone, Copy, Debug)]
struct DriftSample {
    pos: f64,
    neg: f64,
    direction: CusumDirection,
    shift_estimate: f64,
    standardized_residual: f64,
    target: f64,
}

#[derive(Clone, Copy, Debug)]
struct DriftLifecycleContext {
    profile: SeriesProfile,
    value: f64,
    observed_at_unix_nano: u64,
    min_std_floor: f64,
    min_cv: f64,
}

fn drift_severity_band(score: f64) -> u8 {
    if score >= 8.0 {
        4
    } else if score >= 4.0 {
        3
    } else {
        2
    }
}

fn seconds_to_ns(seconds: u64) -> u64 {
    seconds.saturating_mul(1_000_000_000)
}

fn elapsed_ns(now: u64, then: Option<u64>) -> u64 {
    then.map_or(u64::MAX, |then| now.saturating_sub(then))
}

fn drift_episode(state: &SeriesState, ended_at_unix_nano: u64) -> Option<AnomalyEpisode> {
    Some(AnomalyEpisode {
        started_at_unix_nano: state.drift_episode_started_at_unix_nano?,
        ended_at_unix_nano,
        peak_value: state.drift_episode_peak_value?,
        peak_at_unix_nano: state.drift_episode_peak_at_unix_nano?,
    })
}

fn reset_drift_pending_and_cusum(state: &mut SeriesState) {
    if let Some(cusum) = state.cusum.as_mut() {
        cusum.reset();
    }
    state.cusum_run_samples = 0;
    state.cusum_pending_direction = None;
    state.cusum_pending_samples = 0;
}

fn clear_drift_episode_state(state: &mut SeriesState) {
    state.drift_active = false;
    state.drift_active_direction = None;
    state.drift_episode_started_at_unix_nano = None;
    state.drift_episode_peak_value = None;
    state.drift_episode_peak_at_unix_nano = None;
    state.drift_episode_peak_shift = 0.0;
    state.drift_peak_severity_band = 0;
    state.drift_active_samples = 0;
    state.drift_clear_samples = 0;
    state.drift_last_emitted_at_unix_nano = None;
}

fn update_drift_peak(
    state: &mut SeriesState,
    value: f64,
    observed_at_unix_nano: u64,
    shift_estimate: f64,
) {
    if shift_estimate >= state.drift_episode_peak_shift {
        state.drift_episode_peak_shift = shift_estimate;
        state.drift_episode_peak_value = Some(value);
        state.drift_episode_peak_at_unix_nano = Some(observed_at_unix_nano);
    }
}

fn current_window_drift_anchor(
    state: &SeriesState,
    min_std_floor: f64,
    min_cv: f64,
    profile: SeriesProfile,
) -> Option<(f64, f64)> {
    if state.window_tail.is_empty() {
        return None;
    }

    let stats = RobustStats::from_values(&state.window_tail);
    let scale = effective_scoring_scale(stats, min_std_floor, min_cv.max(profile.drift_min_cv));
    Some((stats.center, scale))
}

fn reanchor_drift_to_current_window(
    state: &mut SeriesState,
    cusum_k: f64,
    cusum_h: f64,
    min_std_floor: f64,
    min_cv: f64,
    profile: SeriesProfile,
    observed_at_unix_nano: u64,
) {
    match current_window_drift_anchor(state, min_std_floor, min_cv, profile) {
        Some((center, scale)) => {
            state.cusum_anchor = Some((center, scale));
            state.cusum_anchor_captured_at_unix_nano = Some(observed_at_unix_nano);
            state.cusum = Some(Cusum::with_state(cusum_k, cusum_h, 0.0, 0.0));
        }
        None => {
            state.cusum_anchor = None;
            state.cusum_anchor_captured_at_unix_nano = None;
            state.cusum = None;
        }
    }
}

fn refresh_drift_anchor_scale(
    state: &mut SeriesState,
    min_std_floor: f64,
    min_cv: f64,
    profile: SeriesProfile,
) {
    let Some((center, _scale)) = state.cusum_anchor else {
        return;
    };
    let Some((_current_center, scale)) =
        current_window_drift_anchor(state, min_std_floor, min_cv, profile)
    else {
        return;
    };

    state.cusum_anchor = Some((center, scale));
}

fn seasonal_drift_scale(
    bucket: SeasonalBucket,
    min_std_floor: f64,
    min_cv: f64,
    profile: SeriesProfile,
) -> f64 {
    effective_scoring_scale(
        RobustStats {
            center: bucket.center,
            scale: bucket.scale,
        },
        min_std_floor,
        min_cv.max(profile.drift_min_cv),
    )
}

fn clear_open_drift_episode(
    config: &EngineConfig,
    state: &mut SeriesState,
    ctx: DriftLifecycleContext,
    sample: DriftSample,
    clear_reason: DriftClearReason,
) -> Option<CusumDrift> {
    let episode = drift_episode(state, ctx.observed_at_unix_nano);
    let reopen_count = state.drift_reopen_count;
    let clear_reason = if clear_reason == DriftClearReason::Recovered && reopen_count > 0 {
        DriftClearReason::FlapMerged
    } else {
        clear_reason
    };
    state.drift_last_cleared_at_unix_nano = Some(ctx.observed_at_unix_nano);
    state.drift_last_episode_started_at_unix_nano =
        episode.map(|episode| episode.started_at_unix_nano);
    clear_drift_episode_state(state);
    reset_drift_pending_and_cusum(state);
    reanchor_drift_to_current_window(
        state,
        config.cusum_k,
        config.cusum_h,
        ctx.min_std_floor,
        ctx.min_cv,
        ctx.profile,
        ctx.observed_at_unix_nano,
    );

    Some(CusumDrift {
        pos: sample.pos,
        neg: sample.neg,
        direction: sample.direction,
        shift_estimate: sample.shift_estimate,
        transition: AnomalyTransition::Clear,
        episode,
        clear_reason: Some(clear_reason),
        update_reason: None,
        reopen_count,
    })
}

fn apply_drift_lifecycle(
    config: &EngineConfig,
    state: &mut SeriesState,
    ctx: DriftLifecycleContext,
    drift_sample: Option<DriftSample>,
    allow_new_open: bool,
) -> Option<CusumDrift> {
    let sample = drift_sample?;

    if state.drift_active {
        state.drift_active_samples = state.drift_active_samples.saturating_add(1);
        update_drift_peak(
            state,
            ctx.value,
            ctx.observed_at_unix_nano,
            sample.shift_estimate,
        );

        let recovered = sample.standardized_residual.abs() < config.cusum_k
            || state.drift_active_direction != Some(sample.direction);
        if recovered {
            state.drift_clear_samples = state.drift_clear_samples.saturating_add(1);
        } else {
            state.drift_clear_samples = 0;
        }

        if state.drift_clear_samples >= config.drift_clear_slots.max(1) {
            let reopened_episode = state.drift_reopen_count > 0;
            let inside_flap_window = elapsed_ns(
                ctx.observed_at_unix_nano,
                state.drift_last_emitted_at_unix_nano,
            ) <= seconds_to_ns(config.reopen_cooldown_secs.max(1));
            if reopened_episode && inside_flap_window {
                return None;
            }

            return clear_open_drift_episode(
                config,
                state,
                ctx,
                sample,
                DriftClearReason::Recovered,
            );
        }

        let adoption_blocked = ctx
            .profile
            .saturation_gate
            .is_some_and(|gate| gate.allows_breach(ctx.value, sample.target));
        if state.drift_active_samples >= config.drift_adopt_after_samples.max(1)
            && !adoption_blocked
        {
            return clear_open_drift_episode(config, state, ctx, sample, DriftClearReason::Adopted);
        }

        let band = drift_severity_band(sample.shift_estimate);
        let update_reason = if band > state.drift_peak_severity_band {
            state.drift_peak_severity_band = band;
            Some(DriftUpdateReason::SeverityEscalated)
        } else {
            let heartbeat_interval_ns = seconds_to_ns(config.episode_update_interval_secs.max(1));
            (elapsed_ns(
                ctx.observed_at_unix_nano,
                state.drift_last_emitted_at_unix_nano,
            ) >= heartbeat_interval_ns)
                .then_some(DriftUpdateReason::Heartbeat)
        };

        return update_reason.map(|reason| {
            state.drift_last_emitted_at_unix_nano = Some(ctx.observed_at_unix_nano);
            CusumDrift {
                pos: sample.pos,
                neg: sample.neg,
                direction: sample.direction,
                shift_estimate: sample.shift_estimate,
                transition: AnomalyTransition::Update,
                episode: drift_episode(state, ctx.observed_at_unix_nano),
                clear_reason: None,
                update_reason: Some(reason),
                reopen_count: state.drift_reopen_count,
            }
        });
    }

    if !allow_new_open {
        reset_drift_pending_and_cusum(state);
        return None;
    }

    let reopen_window_ns = seconds_to_ns(config.reopen_cooldown_secs.max(1));
    let reuse_previous_episode = elapsed_ns(
        ctx.observed_at_unix_nano,
        state.drift_last_cleared_at_unix_nano,
    ) <= reopen_window_ns;
    let started_at = if reuse_previous_episode {
        state
            .drift_last_episode_started_at_unix_nano
            .unwrap_or(ctx.observed_at_unix_nano)
    } else {
        ctx.observed_at_unix_nano
    };

    if reuse_previous_episode {
        state.drift_reopen_count = state.drift_reopen_count.saturating_add(1);
    } else {
        state.drift_reopen_count = 0;
    }

    state.drift_active = true;
    state.drift_active_direction = Some(sample.direction);
    state.drift_episode_started_at_unix_nano = Some(started_at);
    state.drift_episode_peak_value = Some(ctx.value);
    state.drift_episode_peak_at_unix_nano = Some(ctx.observed_at_unix_nano);
    state.drift_episode_peak_shift = sample.shift_estimate;
    state.drift_peak_severity_band = drift_severity_band(sample.shift_estimate);
    state.drift_active_samples = 0;
    state.drift_clear_samples = 0;
    state.drift_last_emitted_at_unix_nano = Some(ctx.observed_at_unix_nano);
    reset_drift_pending_and_cusum(state);

    Some(CusumDrift {
        pos: sample.pos,
        neg: sample.neg,
        direction: sample.direction,
        shift_estimate: sample.shift_estimate,
        transition: if reuse_previous_episode {
            AnomalyTransition::Update
        } else {
            AnomalyTransition::Open
        },
        episode: drift_episode(state, ctx.observed_at_unix_nano),
        clear_reason: None,
        update_reason: reuse_previous_episode.then_some(DriftUpdateReason::Flapping),
        reopen_count: state.drift_reopen_count,
    })
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
    /// Counted reasons why counter readings did not produce a rate sample.
    pub(crate) counter_drop_counts: CounterDropCounts,
    /// Per-host CPU aggregate slot state, keyed by the host-level CPU series key.
    pub(crate) host_cpu_slots: HashMap<String, HostCpuSlotState>,
    /// Last sample timestamp that attempted stale-state eviction at capacity.
    /// Metric-feed frames commonly carry many new keys with the same observation
    /// time; scanning both maps once per timestamp bounds a fruitless full scan
    /// under cap-pressure churn.
    last_capacity_eviction_at_unix_nano: Option<u64>,
    /// Number of new series dropped because the `max_series` cap was reached.
    pub dropped_at_capacity: u64,
    /// Number of samples whose seasonal-only drift path stayed inactive because
    /// no usable hour-of-week baseline resolved.
    pub drift_inactive_no_baseline: u64,
    /// Samples that entered the rolling breach arm and were therefore admitted
    /// at the shared core's winsorized decision boundary instead of being
    /// withheld indefinitely. This is deliberately a counter, not an alert: it
    /// makes baseline-pressure visible without amplifying anomaly traffic.
    pub clamped_samples: u64,
    emission_storm_active: bool,
    emission_storm_below_exit_frames: u8,
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct EmissionStormUpdate {
    pub(crate) active: bool,
    pub(crate) entered: bool,
    pub(crate) exited: bool,
}

impl DetectorEngine {
    pub fn new(config: EngineConfig) -> Self {
        Self {
            config,
            series: HashMap::new(),
            seasonal: HashMap::new(),
            seasonal_settings: SeasonalSettings::default(),
            counters: HashMap::new(),
            counter_drop_counts: CounterDropCounts::default(),
            host_cpu_slots: HashMap::new(),
            last_capacity_eviction_at_unix_nano: None,
            dropped_at_capacity: 0,
            drift_inactive_no_baseline: 0,
            clamped_samples: 0,
            emission_storm_active: false,
            emission_storm_below_exit_frames: 0,
        }
    }

    pub fn set_config(&mut self, config: EngineConfig) {
        self.config = config;
    }

    pub fn config(&self) -> EngineConfig {
        self.config.clone()
    }

    pub(crate) fn anomaly_emission_allowed(
        &self,
        series_key: &str,
        transition: AnomalyTransition,
        observed_at_unix_nano: u64,
        cooldown_secs: u64,
    ) -> bool {
        // Re-open folds and bounded heartbeats carry episode identity/liveness
        // to core. Suppressing an update behind the generic open cooldown can
        // strand a cleared finding during a flap, so lifecycle updates share
        // the clear transition's priority path.
        if matches!(
            transition,
            AnomalyTransition::Clear | AnomalyTransition::Update
        ) {
            return true;
        }

        let cooldown_ns = seconds_to_ns(cooldown_secs.max(1));
        self.series
            .get(series_key)
            .and_then(|state| state.last_non_clear_emitted_at_unix_nano)
            .is_none_or(|last| observed_at_unix_nano.saturating_sub(last) >= cooldown_ns)
    }

    pub(crate) fn mark_anomaly_emitted(
        &mut self,
        series_key: &str,
        transition: AnomalyTransition,
        observed_at_unix_nano: u64,
    ) {
        if transition == AnomalyTransition::Clear {
            return;
        }

        if let Some(state) = self.series.get_mut(series_key) {
            state.last_non_clear_emitted_at_unix_nano = Some(observed_at_unix_nano);
        }
    }

    pub(crate) fn update_emission_storm(
        &mut self,
        governed_non_clear: usize,
        budget_per_tick: usize,
    ) -> EmissionStormUpdate {
        let budget = budget_per_tick.max(1);
        let exhausted = governed_non_clear > budget;
        let below_exit = governed_non_clear.saturating_mul(2) <= budget;
        let mut entered = false;
        let mut exited = false;

        if exhausted {
            if !self.emission_storm_active {
                entered = true;
            }
            self.emission_storm_active = true;
            self.emission_storm_below_exit_frames = 0;
        } else if self.emission_storm_active {
            if below_exit {
                self.emission_storm_below_exit_frames =
                    self.emission_storm_below_exit_frames.saturating_add(1);
                if self.emission_storm_below_exit_frames >= EMISSION_STORM_EXIT_FRAMES {
                    self.emission_storm_active = false;
                    self.emission_storm_below_exit_frames = 0;
                    exited = true;
                }
            } else {
                self.emission_storm_below_exit_frames = 0;
            }
        }

        EmissionStormUpdate {
            active: self.emission_storm_active,
            entered,
            exited,
        }
    }

    pub(crate) fn observe_host_cpu_core_sample(
        &mut self,
        aggregate_series_key: &str,
        core_id: &str,
        value: f64,
        observed_at_unix_nano: u64,
        interval_ns: u64,
        saturation_gate: f64,
    ) -> Option<HostCpuAggregateSample> {
        if !value.is_finite() || core_id.is_empty() || interval_ns == 0 {
            return None;
        }

        let slot_start = observed_at_unix_nano - (observed_at_unix_nano % interval_ns);
        let state = self
            .host_cpu_slots
            .entry(aggregate_series_key.to_string())
            .or_insert_with(|| HostCpuSlotState::new(slot_start));

        if slot_start < state.slot_start_unix_nano {
            return None;
        }

        if slot_start == state.slot_start_unix_nano {
            state.observe_core(core_id, value, observed_at_unix_nano);
            return None;
        }

        let ready = state.aggregate(saturation_gate);
        *state = HostCpuSlotState::new(slot_start);
        state.observe_core(core_id, value, observed_at_unix_nano);
        ready
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
            .seasonal_profile(seasonal_key)?
            .bucket(hour_of_week(observed_at_unix_nano))?;
        bucket
            .usable(self.seasonal_settings.min_bucket_samples)
            .then_some(bucket)
    }

    fn seasonal_profile(&self, seasonal_key: &str) -> Option<&SeasonalProfile> {
        self.seasonal
            .get(seasonal_key)
            .or_else(|| self.seasonal_fallback_key(seasonal_key))
    }

    /// Explain why the seasonal signal could not resolve. The detector remains
    /// rolling-only in all three cases, but collapsing them into "signal
    /// disabled" made a broken delivery path indistinguishable from an ordinary
    /// hour-of-week gap.
    fn seasonal_unavailable_reason(
        &self,
        seasonal_key: &str,
        observed_at_unix_nano: u64,
    ) -> Option<&'static str> {
        if self.seasonal.is_empty() || self.config.window_size < 2 {
            return Some("no baselines configured");
        }
        let Some(profile) = self.seasonal_profile(seasonal_key) else {
            return Some("no baselines configured");
        };
        let Some(bucket) = profile.bucket(hour_of_week(observed_at_unix_nano)) else {
            return Some("no bucket for this hour");
        };

        (!bucket.usable(self.seasonal_settings.min_bucket_samples))
            .then_some("bucket below trust threshold")
    }

    fn seasonal_fallback_key(&self, seasonal_key: &str) -> Option<&SeasonalProfile> {
        let (fallback, if_index) = seasonal_key.rsplit_once('|')?;
        if if_index.is_empty() || !if_index.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }

        self.seasonal.get(fallback)
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

    pub fn metric_denied(&self, metric_name: &str) -> bool {
        self.config
            .metric_denylist
            .iter()
            .any(|denied| denied == metric_name)
    }

    pub(crate) fn metric_class_enabled(&self, class: &str) -> bool {
        self.config
            .metric_class_overrides
            .get(class)
            .and_then(|class_override| class_override.enabled)
            .unwrap_or(true)
    }

    pub(crate) fn severity_policy_for(&self, class: &str) -> SeverityPolicy {
        self.config
            .metric_class_overrides
            .get(class)
            .map(|override_| override_.severity_policy)
            .unwrap_or_default()
    }

    pub(crate) fn apply_metric_class_override(
        &self,
        class: &str,
        mut profile: SeriesProfile,
    ) -> SeriesProfile {
        let Some(class_override) = self.config.metric_class_overrides.get(class) else {
            return profile;
        };

        if let Some(drift_mode) = class_override.drift_mode {
            profile.drift_mode = drift_mode;
        }
        if let Some(min_std_floor) = class_override
            .min_std_floor
            .filter(|value| value.is_finite() && *value > 0.0)
        {
            profile.min_std_floor = profile.min_std_floor.max(min_std_floor);
        }
        if let Some(min_cv) = class_override
            .min_cv
            .filter(|value| value.is_finite() && *value > 0.0)
        {
            profile.min_cv = profile.min_cv.max(min_cv);
        }
        if let Some(drift_min_cv) = class_override
            .drift_min_cv
            .filter(|value| value.is_finite() && *value > 0.0)
        {
            profile.drift_min_cv = profile.drift_min_cv.max(drift_min_cv);
        }
        if let Some(abs_effect_floor) = class_override
            .abs_effect_floor
            .filter(|value| value.is_finite() && *value > 0.0)
        {
            profile.abs_effect_floor = profile.abs_effect_floor.max(abs_effect_floor);
        }
        if let Some(spike_adopt_after_samples) = class_override.spike_adopt_after_samples {
            profile.spike_adopt_after_samples = Some(spike_adopt_after_samples.max(1));
        }

        profile
    }

    fn evict_stale_state(&mut self, now_unix_nano: u64) {
        self.series.retain(|_, state| {
            now_unix_nano.saturating_sub(state.last_observed_at_unix_nano)
                <= STATE_EVICTION_MAX_AGE_NS
        });
        self.counters.retain(|_, counter| {
            now_unix_nano.saturating_sub(counter.timestamp) <= STATE_EVICTION_MAX_AGE_NS
        });
        self.host_cpu_slots.retain(|_, slot| {
            now_unix_nano.saturating_sub(slot.last_observed_at_unix_nano)
                <= STATE_EVICTION_MAX_AGE_NS
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
        let seasonal_unavailable_reason =
            self.seasonal_unavailable_reason(seasonal_key, observed_at_unix_nano);
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
        // The CUSUM deseasonalize target: the delivered hour-of-week bucket when
        // one resolves for this sample. Deseasonalized-only profiles require this
        // context; always-on profiles may fall back to the rolling anchor below.
        let cusum_target_bucket = if profile.drift_mode == DriftMode::DeseasonalizedOnly {
            self.seasonal_bucket(seasonal_key, observed_at_unix_nano)
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
            .or_insert_with(|| SeriesState::new(observed_at_unix_nano));

        state.raw_tail.push(value);
        // Keep the raw adoption history in a small amortized ring. Removing
        // index zero on every sample is O(window_size); compact once it grows
        // past two windows, retaining the newest complete window for adoption.
        let raw_tail_limit = self.config.window_size.saturating_mul(2).max(1);
        if state.raw_tail.len() > raw_tail_limit {
            let keep_from = state.raw_tail.len().saturating_sub(self.config.window_size);
            state.raw_tail.drain(0..keep_from);
        }

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
        // folded in). Anchors to a robust `(mean, floored-scale)` once the rolling
        // baseline reaches `min_samples`. Deseasonalized-only profiles advance only
        // when a delivered seasonal target resolves; always-on profiles can use the
        // frozen anchor. Captured here, gated on the z-score verdict below.
        let mut drift_sample: Option<DriftSample> = None;
        if profile.drift_mode == DriftMode::DeseasonalizedOnly && cusum_target_bucket.is_none() {
            self.drift_inactive_no_baseline = self.drift_inactive_no_baseline.saturating_add(1);
        }

        if profile.drift_mode != DriftMode::Off {
            if state.cusum_anchor.is_none() && state.window_tail.len() >= self.config.min_samples {
                // Anchor to the ROBUST center/scale (median + MAD*1.4826), matching
                // the rolling detector's dispersion. The scale uses the same
                // magnitude-aware floor as robust scoring so a quiet series cannot
                // divide by EPSILON and manufacture astronomical drift evidence.
                reanchor_drift_to_current_window(
                    state,
                    self.config.cusum_k,
                    self.config.cusum_h,
                    min_std_floor,
                    min_cv,
                    profile,
                    observed_at_unix_nano,
                );
            } else if profile.drift_mode == DriftMode::Always
                && state.cusum_anchor.is_some()
                && !state.drift_active
                && state.cusum_pending_direction.is_none()
                && state.window_tail.len() >= self.config.min_samples
                && elapsed_ns(
                    observed_at_unix_nano,
                    state.cusum_anchor_captured_at_unix_nano,
                ) >= seconds_to_ns(self.config.anchor_max_age_secs.max(1))
            {
                reset_drift_pending_and_cusum(state);
                reanchor_drift_to_current_window(
                    state,
                    self.config.cusum_k,
                    self.config.cusum_h,
                    min_std_floor,
                    min_cv,
                    profile,
                    observed_at_unix_nano,
                );
            } else {
                refresh_drift_anchor_scale(state, min_std_floor, min_cv, profile);
            }
            let drift_target = match profile.drift_mode {
                DriftMode::Off => None,
                DriftMode::DeseasonalizedOnly => cusum_target_bucket.map(|bucket| {
                    (
                        bucket.center,
                        seasonal_drift_scale(bucket, min_std_floor, min_cv, profile),
                    )
                }),
                DriftMode::Always => state.cusum_anchor.map(|(anchor_mean, anchor_scale)| {
                    cusum_target_bucket.map_or((anchor_mean, anchor_scale), |bucket| {
                        (
                            bucket.center,
                            seasonal_drift_scale(bucket, min_std_floor, min_cv, profile),
                        )
                    })
                }),
            };

            if let (Some((target, scale)), Some(cusum)) = (drift_target, state.cusum.as_mut()) {
                let standardized_residual = (value - target) / scale;

                if state.drift_active {
                    let direction = if standardized_residual >= 0.0 {
                        CusumDirection::Up
                    } else {
                        CusumDirection::Down
                    };
                    let shift_estimate = standardized_residual.abs();
                    let (pos, neg) = match direction {
                        CusumDirection::Up => (shift_estimate, 0.0),
                        CusumDirection::Down => (0.0, shift_estimate),
                    };
                    drift_sample = Some(DriftSample {
                        pos,
                        neg,
                        direction,
                        shift_estimate,
                        standardized_residual,
                        target,
                    });
                } else {
                    let step = cusum.update_retaining(standardized_residual);
                    if step.pos <= 0.0 && step.neg <= 0.0 {
                        state.cusum_run_samples = 0;
                        state.cusum_pending_direction = None;
                        state.cusum_pending_samples = 0;
                    } else {
                        state.cusum_run_samples = state.cusum_run_samples.saturating_add(1);
                    }

                    if let Some(pending_direction) = state.cusum_pending_direction {
                        state.cusum_pending_samples = state.cusum_pending_samples.saturating_add(1);
                        let pending_accumulator =
                            drift_accumulator_for(pending_direction, step.pos, step.neg);
                        let h_confirm = self.config.cusum_h * self.config.h_confirm_mult;

                        if pending_accumulator > h_confirm {
                            let gate_allows = profile
                                .saturation_gate
                                .is_none_or(|gate| gate.allows_breach(value, target));
                            let shift_estimate = drift_shift_estimate(
                                self.config.cusum_k,
                                pending_accumulator,
                                state.cusum_run_samples,
                            );

                            if gate_allows && shift_estimate >= self.config.drift_min_effect {
                                drift_sample = Some(DriftSample {
                                    pos: step.pos,
                                    neg: step.neg,
                                    direction: pending_direction,
                                    shift_estimate,
                                    standardized_residual,
                                    target,
                                });
                            }
                        } else if state.cusum_pending_samples >= self.config.drift_confirm_window {
                            cusum.reset();
                            state.cusum_run_samples = 0;
                            state.cusum_pending_direction = None;
                            state.cusum_pending_samples = 0;
                        }
                    } else if step.alarm {
                        state.cusum_pending_direction =
                            Some(drift_direction_for(step.pos, step.neg));
                        state.cusum_pending_samples = 0;
                    }
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

                if let Some(reason) = seasonal_unavailable_reason
                    && let Some(signal) = verdict
                        .signals
                        .iter_mut()
                        .find(|signal| signal.name == "seasonal")
                {
                    signal.reason = reason.to_string();
                }

                // Additive but de-duplicated: a CUSUM drift finding reports exactly
                // the sustained drift the point z-score MISSES, so suppress it when
                // the z-score itself breached this sample (already an edge-spike).
                let cusum_drift = apply_drift_lifecycle(
                    &self.config,
                    state,
                    DriftLifecycleContext {
                        profile,
                        value,
                        observed_at_unix_nano,
                        min_std_floor,
                        min_cv,
                    },
                    drift_sample,
                    !verdict.breached,
                );

                if verdict.breached {
                    self.clamped_samples = self.clamped_samples.saturating_add(1);
                }

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
        let (mut verdict, cusum_drift) = self.evaluate_inner(
            series_key,
            seasonal_key,
            value,
            observed_at_unix_nano,
            profile,
        )?;
        let clear_slots = self.config.confirm_slots.max(1);
        let reopen_window_ns = seconds_to_ns(self.config.reopen_cooldown_secs.max(1));
        let spike_adopt_after_samples = profile
            .spike_adopt_after_samples
            .unwrap_or(self.config.spike_adopt_after_samples)
            .max(1);
        let rolling_center = verdict
            .signals
            .iter()
            .find(|signal| signal.name == "rolling")
            .and_then(|signal| signal.mean);
        let state = self.series.get_mut(series_key)?;
        let mut episode = None;
        let mut clear_reason = None;
        let mut update_reason = None;

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
            let reuse_previous_episode =
                elapsed_ns(observed_at_unix_nano, state.spike_last_cleared_at_unix_nano)
                    <= reopen_window_ns;
            let previous_started_at = reuse_previous_episode
                .then_some(state.spike_last_episode_started_at_unix_nano)
                .flatten();
            promote_pending_episode_with_start(
                state,
                value,
                observed_at_unix_nano,
                previous_started_at,
            );
            episode = active_episode(state, observed_at_unix_nano);
            state.active_anomalous = true;
            state.consecutive_clean = 0;
            state.spike_active_samples = 1;
            state.spike_last_emitted_at_unix_nano = Some(observed_at_unix_nano);
            if reuse_previous_episode {
                state.spike_reopen_count = state.spike_reopen_count.saturating_add(1);
                update_reason = Some(SpikeUpdateReason::Flapping);
                AnomalyTransition::Update
            } else {
                state.spike_reopen_count = 0;
                AnomalyTransition::Open
            }
        } else if state.active_anomalous {
            // A single continuing incident can re-breach intermittently as the
            // rolling window moves. Decay the adoption evidence on every clean
            // evaluation so alternating breaches cannot accumulate forever and
            // self-clear a live episode as a new baseline.
            if verdict.breached {
                state.spike_active_samples = state.spike_active_samples.saturating_add(1);
            } else {
                state.spike_active_samples = state.spike_active_samples.saturating_sub(1);
            }

            let adoption_blocked = profile.saturation_gate.is_some_and(|gate| {
                rolling_center.is_some_and(|center| gate.allows_breach(value, center))
            });
            if verdict.breached
                && state.spike_active_samples >= spike_adopt_after_samples
                && !adoption_blocked
            {
                episode = active_episode(state, observed_at_unix_nano);
                state.spike_last_cleared_at_unix_nano = Some(observed_at_unix_nano);
                state.spike_last_episode_started_at_unix_nano =
                    episode.map(|current| current.started_at_unix_nano);
                state.active_anomalous = false;
                state.consecutive_clean = 0;
                state.consecutive_anomalous = 0;
                let raw_tail_start = state.raw_tail.len().saturating_sub(self.config.window_size);
                state.window_tail = state.raw_tail[raw_tail_start..].to_vec();
                state.spike_active_samples = 0;
                // Adoption creates a new rolling regime. It must not retain
                // flap-reopen metadata from the completed regime: a later
                // genuine breach is a new episode, not an `anomaly_update`.
                state.spike_last_cleared_at_unix_nano = None;
                state.spike_last_episode_started_at_unix_nano = None;
                state.spike_reopen_count = 0;
                reset_active_episode(state);
                verdict.next_consecutive_anomalous = 0;
                verdict.reason = "rolling baseline adopted after sustained spike".to_string();
                clear_reason = Some(SpikeClearReason::Adopted);
                AnomalyTransition::Clear
            // A bounded utilization series can cease to z-breach after its
            // winsorized rolling window moves toward the ceiling. That is not
            // recovery: while it remains inside the saturation band, retain the
            // episode and keep its clean confirmation counter at zero.
            } else if is_clean_verdict(&verdict)
                && !profile.saturation_gate.is_some_and(|gate| {
                    // A high-normal host must be allowed to recover to its own
                    // center (85% -> 98% -> 85%), not held merely because 85
                    // exceeds the absolute floor. Conversely, the rolling
                    // window is winsorized while an episode is open and can
                    // eventually reach a sustained 100% plateau. Retain that
                    // still-at-peak saturation episode even after the scored
                    // center catches up, otherwise it self-clears without a
                    // real recovery.
                    rolling_center.is_some_and(|center| gate.allows_breach(value, center))
                        || (value > gate.min_value
                            && state
                                .active_episode_peak_value
                                .is_some_and(|peak| value >= peak))
                })
            {
                state.consecutive_clean = state.consecutive_clean.saturating_add(1);

                if state.consecutive_clean >= clear_slots {
                    let inside_flap_window = state.spike_reopen_count > 0
                        && elapsed_ns(observed_at_unix_nano, state.spike_last_emitted_at_unix_nano)
                            <= reopen_window_ns;
                    if inside_flap_window {
                        return Some(TransitionVerdict {
                            verdict,
                            transition: AnomalyTransition::None,
                            episode: None,
                            clear_reason: None,
                            update_reason: None,
                            reopen_count: state.spike_reopen_count,
                            cusum_drift,
                        });
                    }

                    episode = active_episode(state, observed_at_unix_nano);
                    state.spike_last_cleared_at_unix_nano = Some(observed_at_unix_nano);
                    state.spike_last_episode_started_at_unix_nano =
                        episode.map(|current| current.started_at_unix_nano);
                    state.active_anomalous = false;
                    state.consecutive_clean = 0;
                    state.spike_active_samples = 0;
                    reset_active_episode(state);
                    clear_reason = Some(if state.spike_reopen_count > 0 {
                        SpikeClearReason::FlapMerged
                    } else {
                        SpikeClearReason::Recovered
                    });
                    AnomalyTransition::Clear
                } else {
                    AnomalyTransition::None
                }
            } else {
                state.consecutive_clean = 0;
                let heartbeat_interval_ns =
                    seconds_to_ns(self.config.episode_update_interval_secs.max(1));
                if elapsed_ns(observed_at_unix_nano, state.spike_last_emitted_at_unix_nano)
                    >= heartbeat_interval_ns
                {
                    episode = active_episode(state, observed_at_unix_nano);
                    state.spike_last_emitted_at_unix_nano = Some(observed_at_unix_nano);
                    update_reason = Some(SpikeUpdateReason::Heartbeat);
                    AnomalyTransition::Update
                } else {
                    AnomalyTransition::None
                }
            }
        } else {
            state.consecutive_clean = 0;
            AnomalyTransition::None
        };

        Some(TransitionVerdict {
            verdict,
            transition,
            episode,
            clear_reason,
            update_reason,
            reopen_count: state.spike_reopen_count,
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
            .or_insert_with(|| SeriesState::new(observed_at_unix_nano));

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
