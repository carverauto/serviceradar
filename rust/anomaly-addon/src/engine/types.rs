// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Public verdict/lifecycle value types produced by the edge detector engine:
//! the lifecycle transition, the transition verdict envelope, the CUSUM drift
//! alarm, the anomaly episode metadata, and the per-series fidelity profile.

use serviceradar_anomaly_core::{ReasonVerdict, SaturationGate};

/// Sustained-drift detector mode for one metric class.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum DriftMode {
    /// Do not run CUSUM drift detection for this series.
    #[default]
    Off,
    /// Run CUSUM only when a delivered seasonal center resolves for this sample.
    DeseasonalizedOnly,
    /// Run CUSUM against a rolling anchor when no seasonal center is available.
    Always,
}

/// Lifecycle transition produced by edge state after scoring one sample.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AnomalyTransition {
    /// No externally visible lifecycle change.
    None,
    /// A series moved from clean/inactive into confirmed anomalous.
    Open,
    /// An already-open episode emitted a bounded lifecycle update.
    Update,
    /// A previously active anomaly returned clean.
    Clear,
}

/// A scored verdict plus the edge lifecycle transition it caused.
#[derive(Debug, PartialEq)]
pub struct TransitionVerdict {
    pub verdict: ReasonVerdict,
    pub transition: AnomalyTransition,
    pub episode: Option<AnomalyEpisode>,
    /// A sustained-drift alarm from the CUSUM detector for this sample, when the
    /// drift detector is enabled and fired AND the point z-score did NOT itself
    /// breach this sample (so a drift finding captures exactly what the z-score
    /// misses, never duplicating an obvious spike). `None` otherwise.
    pub cusum_drift: Option<CusumDrift>,
}

/// Which side of the two-sided CUSUM crossed the decision interval.
#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum CusumDirection {
    /// The upper accumulator `S+` crossed: a sustained UPWARD drift / leak.
    Up,
    /// The lower accumulator `S-` crossed: a sustained DOWNWARD drift.
    Down,
}

impl CusumDirection {
    pub fn as_str(self) -> &'static str {
        match self {
            CusumDirection::Up => "upward",
            CusumDirection::Down => "downward",
        }
    }
}

/// Why an open CUSUM drift episode cleared.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DriftClearReason {
    Recovered,
    Adopted,
    Stale,
    FlapMerged,
}

impl DriftClearReason {
    pub fn as_str(self) -> &'static str {
        match self {
            DriftClearReason::Recovered => "recovered",
            DriftClearReason::Adopted => "level adopted as new baseline",
            DriftClearReason::Stale => "stale",
            DriftClearReason::FlapMerged => "flap merged",
        }
    }
}

/// Why an open CUSUM drift episode emitted an update.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DriftUpdateReason {
    SeverityEscalated,
    Heartbeat,
    Flapping,
}

impl DriftUpdateReason {
    pub fn as_str(self) -> &'static str {
        match self {
            DriftUpdateReason::SeverityEscalated => "severity escalated",
            DriftUpdateReason::Heartbeat => "still open",
            DriftUpdateReason::Flapping => "flapping",
        }
    }
}

/// A CUSUM sustained-drift alarm: the (pre-reset) accumulators that crossed the
/// decision interval and the direction of the drift. Distinct from the z-score
/// SPIKE — this is the slow drift/leak the point z-score absorbs into its rolling
/// mean and never flags.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CusumDrift {
    pub pos: f64,
    pub neg: f64,
    pub direction: CusumDirection,
    pub shift_estimate: f64,
    pub transition: AnomalyTransition,
    pub episode: Option<AnomalyEpisode>,
    pub clear_reason: Option<DriftClearReason>,
    pub update_reason: Option<DriftUpdateReason>,
    pub reopen_count: u64,
}

impl CusumDrift {
    /// The bounded drift evidence score: an estimate of the sustained shift in
    /// sigma units (`k + S/N`) at the alarm point. This deliberately is not the
    /// raw accumulator, which can grow without bound.
    pub fn magnitude(self) -> f64 {
        self.shift_estimate
    }
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
    /// Sustained-drift mode for this metric class.
    pub drift_mode: DriftMode,
    /// Drift-only relative dispersion floor. This lets counter-rate drift use a
    /// safe denominator without changing rolling z-score behavior.
    pub drift_min_cv: f64,
}

/// Resolved operator override for one metric class. This is the load-bearing
/// runtime projection of `metric_classes.<class>` after config validation.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MetricClassOverride {
    /// `Some(false)` disables all detector evaluation for the class.
    pub enabled: Option<bool>,
    /// Optional override for the class' sustained-drift mode.
    pub drift_mode: Option<DriftMode>,
    /// Optional class-specific dispersion floors. They only raise the built-in
    /// profile floor, preserving safe gauge defaults.
    pub min_std_floor: Option<f64>,
    pub min_cv: Option<f64>,
}
