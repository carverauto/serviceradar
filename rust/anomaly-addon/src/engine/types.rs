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

/// Why a rolling-spike episode cleared. Kept distinct from the drift enum so
/// downstream consumers can distinguish a rolling-baseline adoption from a
/// CUSUM level adoption without inferring it from free-form text.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SpikeClearReason {
    Recovered,
    Adopted,
    FlapMerged,
}

impl SpikeClearReason {
    pub fn as_str(self) -> &'static str {
        match self {
            SpikeClearReason::Recovered => "recovered",
            SpikeClearReason::Adopted => "level adopted as new baseline",
            SpikeClearReason::FlapMerged => "flap merged",
        }
    }
}

/// Why an existing rolling-spike episode emitted an update rather than a new
/// open.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SpikeUpdateReason {
    Flapping,
    Heartbeat,
}

impl SpikeUpdateReason {
    pub fn as_str(self) -> &'static str {
        match self {
            SpikeUpdateReason::Flapping => "flapping",
            SpikeUpdateReason::Heartbeat => "still open",
        }
    }
}

/// A scored verdict plus the edge lifecycle transition it caused.
#[derive(Debug, PartialEq)]
pub struct TransitionVerdict {
    pub verdict: ReasonVerdict,
    pub transition: AnomalyTransition,
    pub episode: Option<AnomalyEpisode>,
    pub clear_reason: Option<SpikeClearReason>,
    pub update_reason: Option<SpikeUpdateReason>,
    pub reopen_count: u64,
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
    /// Absolute practical-significance floor in the metric's own units. It is
    /// used for counter-rate severity calibration; zero preserves the legacy
    /// relative-only behavior for other classes.
    pub abs_effect_floor: f64,
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
    /// Class-local rolling-spike adoption horizon. `None` uses the engine-wide
    /// default; counters set a shorter value because their day/night regimes
    /// change far faster than a sustained capacity incident.
    pub spike_adopt_after_samples: Option<u64>,
}

/// Optional class-level score bands and severity ceiling. Score bands never
/// create Critical directly; the existing impact/duration gates remain the only
/// path to Critical. This keeps operator overrides from bypassing safety gates.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SeverityPolicy {
    pub cap: Option<i64>,
    pub medium_at: Option<f64>,
    pub high_at: Option<f64>,
}

impl SeverityPolicy {
    pub fn capped(self, severity_id: i64) -> i64 {
        self.cap.map_or(severity_id, |cap| severity_id.min(cap))
    }

    pub fn bands(self) -> (f64, f64) {
        let medium_at = self
            .medium_at
            .filter(|value| value.is_finite() && *value > 0.0);
        let high_at = self
            .high_at
            .filter(|value| value.is_finite() && *value > 0.0);

        match (medium_at, high_at) {
            (Some(medium), Some(high)) if high > medium => (medium, high),
            // A medium override may be above the default high threshold. Keep
            // bands ordered rather than accidentally classifying sub-medium
            // scores as High.
            (Some(medium), _) => (medium, (medium + 4.0).max(8.0)),
            (_, Some(high)) if high > 4.0 => (4.0, high),
            _ => (4.0, 8.0),
        }
    }
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
    /// Optional relative dispersion floor applied only to CUSUM drift scoring.
    pub drift_min_cv: Option<f64>,
    pub abs_effect_floor: Option<f64>,
    pub spike_adopt_after_samples: Option<u64>,
    pub severity_policy: SeverityPolicy,
}
