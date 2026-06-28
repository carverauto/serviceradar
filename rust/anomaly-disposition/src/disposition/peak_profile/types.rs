// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Peak-profile disposition data carriers.
//!
//! DORMANT — not yet wired (no Rustler ABI). This is the matched-resolution peak
//! disposition (spike peak vs the hour-of-week PEAK profile over
//! `timeseries_metrics_hourly.max_value`) that the `refactor-anomaly-engine-rigor`
//! change wires when it closes the disposition loop: once the edge forwards the spike
//! peak + window and the robust peak-profile stability gate is calibrated. Kept (not
//! deleted) because that wiring is the next step; it does no causal inference.

/// Read-only peak-profile knobs — the `Context` channel.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PeakProfileConfig {
    /// Inner-band sigma multiplier: inside `center ± Z_sup * s_inner * k_n`
    /// recommends suppression.
    pub suppress_n_sigma: f64,
    /// Outer-band sigma multiplier: outside `center ± Z_esc * s_outer * k_n`
    /// recommends escalation.
    pub escalate_n_sigma: f64,
    /// Minimum `(series, hod)` cell sample count before the profile can suppress.
    pub min_cell_samples: usize,
    /// Poison cap: `s_inner = min(s_cell, CAP * s_prior)`.
    pub cap_scale: f64,
    /// Sigma-relative low-n inflation: `k_n = 1 + A / sqrt(n)`.
    pub low_n_inflation: f64,
    /// Over-dispersion guard: `s_cell > D * s_prior` passes through.
    pub over_dispersion_ratio: f64,
    /// Tiny absolute scale used only when a robust scale is effectively zero.
    pub absolute_scale_floor: f64,
    /// Percentage ceiling for utilization metrics. `INFINITY` disables the
    /// ceiling-proximity guard for non-percentage callers.
    pub ceiling: f64,
    /// Report-only kill switch: compute the recommendation, but surface
    /// `PassThrough` so live alert behavior is unchanged.
    pub report_only: bool,
    /// Per-class kill switch for suppression/downgrade once report-only is off.
    pub suppression_enabled: bool,
    /// Leaky-bucket decay for recurring expected spikes; never reset to zero.
    pub suppress_decay_slots: usize,
}

impl Default for PeakProfileConfig {
    fn default() -> Self {
        Self {
            suppress_n_sigma: 2.0,
            escalate_n_sigma: 3.0,
            min_cell_samples: 6,
            cap_scale: 2.0,
            low_n_inflation: 2.0,
            over_dispersion_ratio: 8.0,
            absolute_scale_floor: 0.5,
            ceiling: 100.0,
            report_only: true,
            suppression_enabled: false,
            suppress_decay_slots: 1,
        }
    }
}

/// One edge-spike row plus its matching SQL-precomputed peak-profile summary.
///
/// The profile is the matched-resolution `(series, hod)` robust aggregate over
/// `timeseries_metrics_hourly.max_value`: median center, p05-p95 scale already
/// converted to a stddev-equivalent, q95 for the ceiling guard, and the per-series
/// prior scale.
#[derive(Clone, Debug, PartialEq)]
pub struct PeakProfileRow {
    /// Stable canonical series identifier.
    pub series_key: String,
    /// Hour-of-day bucket (0-23). The kernel does not re-bucket; SQL owns that.
    pub hod: u8,
    /// Edge-forwarded episode peak magnitude.
    pub peak_value: f64,
    /// Excluded-history samples in the `(series, hod)` peak cell.
    pub cell_sample_count: usize,
    /// Robust cell center (median of hourly max_value).
    pub cell_center: f64,
    /// Robust cell scale `(p95 - p05) * 0.30398`.
    pub cell_scale: f64,
    /// Per-series, series-overall robust scale. This is the poison cap reference.
    pub series_prior_scale: f64,
    /// Cell q95 of hourly max_value. Used only for the ceiling-proximity guard.
    pub cell_q95: f64,
    /// Carried confirmation counter from the correlation layer.
    pub consecutive_anomalous: usize,
}

/// Operator-facing peak-profile action.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeakProfileAction {
    /// The edge finding should remain edge-governed because the profile is not
    /// allowed to decide.
    PassThrough,
    /// The peak is expected for this series/hour and can be suppressed once
    /// activation is enabled.
    Suppress,
    /// The peak is outside the suppression band but not outside the escalation
    /// band; keep it visible at reduced confidence/severity.
    Downgrade,
    /// The peak is outside the matched-resolution normal peak profile.
    Escalate,
}

/// Computed band telemetry. This is calibration evidence, not an alert payload.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PeakProfileBand {
    pub center: f64,
    pub inner_scale: f64,
    pub outer_scale: f64,
    pub low_n_multiplier: f64,
    pub inner_lower: f64,
    pub inner_upper: f64,
    pub outer_lower: f64,
    pub outer_upper: f64,
}

/// One peak-profile result.
#[derive(Clone, Debug, PartialEq)]
pub struct PeakProfileDisposition {
    pub series_key: String,
    /// The kernel's calibrated recommendation.
    pub recommended_action: PeakProfileAction,
    /// The action allowed to surface under report-only / kill-switch gates.
    pub surfaced_action: PeakProfileAction,
    /// Stable machine-readable reason for gates and recommendations.
    pub reason: String,
    /// Signed z-like distance from the inner-band center/scale.
    pub score: f64,
    /// Confirmation counter to persist after leaky-bucket handling.
    pub next_consecutive_anomalous: usize,
    /// Computed band when the profile was scoreable.
    pub band: Option<PeakProfileBand>,
}

pub(super) struct PeakProfileState {
    pub(super) row: PeakProfileRow,
    pub(super) band: Option<PeakProfileBand>,
}

pub(super) enum PeakProfileValue {
    Evaluate,
    Disposed(PeakProfileEvaluation),
}

pub(super) struct PeakProfileEvaluation {
    pub(super) recommended_action: PeakProfileAction,
    pub(super) surfaced_action: PeakProfileAction,
    pub(super) reason: String,
    pub(super) score: f64,
    pub(super) next_consecutive_anomalous: usize,
    pub(super) band: Option<PeakProfileBand>,
}
