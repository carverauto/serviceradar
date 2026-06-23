// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! Data carriers for the peak-disposition Uncertainty-Aware Shrinkage Band (UASB).
//!
//! UASB judges an edge **spike peak** against the series' normal hour-of-day peak
//! at *matched resolution* (the hourly `max_value` profile), unlike the seasonal
//! kernel which judges the hourly *mean*. The 168→24 bucket aggregation (median,
//! `p95−p05`, the `(series,hod)`-localized prior) runs in SQL (data gravity); this
//! kernel receives the per-cell summary and makes an O(1) decision.
//!
//! Design + invariants: `openspec/changes/add-anomaly-finding-disposition`.

/// Read-only UASB knobs — the `Context` channel. Every field is calibration
/// (see the proposal's task 6.6); the *invariants* the kernel enforces are not.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PeakConfig {
    /// Low-`n` uncertainty inflation coefficient `A` in `k_n = 1 + A/√n`.
    pub a: f64,
    /// Suppression (inner) band half-width in robust-scale units.
    pub z_sup: f64,
    /// Escalation (outer) band half-width in robust-scale units.
    pub z_esc: f64,
    /// Cap on the inner-band scale relative to the localized prior:
    /// `s_inner = min(s_cell, cap·s_prior)`. Bounds the suppression region ABOVE
    /// so a poisoned/thin cell cannot widen it (the load-bearing poison fix).
    pub cap: f64,
    /// Cold-cell threshold: below this the cell passes through (no suppression).
    pub n_min: usize,
    /// Over-dispersion factor: `s_cell > d_overdispersion·s_prior` ⇒ the cell looks
    /// anomalous vs its own class ⇒ pass through (treat as poisoned/degenerate).
    pub d_overdispersion: f64,
    /// Absolute scale floor applied ONLY when the robust scale is ≈ 0 (a flat
    /// cell), never universally — so a genuinely tight series is not blinded.
    pub scale_floor: f64,
    /// Utilization ceiling for the no-upward-headroom guard (e.g. `Some(100.0)`
    /// for percent metrics; `None` for unbounded metrics).
    pub ceiling: Option<f64>,
}

impl Default for PeakConfig {
    fn default() -> Self {
        Self {
            a: 1.5,
            z_sup: 3.0,
            z_esc: 4.5,
            cap: 2.0,
            n_min: 4,
            d_overdispersion: 3.0,
            scale_floor: 0.5,
            ceiling: Some(100.0),
        }
    }
}

/// One spike-under-test row: the forwarded peak plus the SQL-aggregated robust
/// summary for its `(series, hod)` cell and that cell's localized prior.
///
/// The prior scale MUST be computed by SQL localized to `(series, hod)` (collapse
/// only DOW; never pool across `hod`) — invariant I3 lives in the SQL, not here;
/// this kernel only consumes `prior_scale`.
#[derive(Clone, Debug, PartialEq)]
pub struct PeakRow {
    /// Stable series identifier (echoed back so the worker can re-key verdicts).
    pub series_key: String,
    /// Hour-of-day bucket (0–23) the spike falls in.
    pub hod: u8,
    /// The spike peak under test (the forwarded edge peak / the cell's latest max).
    pub peak: f64,
    /// Effective sample count of the `(series, hod)` cell (latest-excluded).
    pub n: usize,
    /// Robust center = median of the cell's per-hour maxima.
    pub cell_center: f64,
    /// Robust cell scale = `(p95 − p05)·0.30398` (Gaussian-consistent, two-sided).
    pub cell_scale: f64,
    /// Robust scale of the `(series, hod)`-localized prior.
    pub prior_scale: f64,
    /// Cell `q95` (upper percentile) — for the ceiling-proximity guard.
    pub q95: f64,
}

/// Why a row passed through instead of being disposed against the band.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PassReason {
    /// A non-finite input (peak/center).
    NonFinite,
    /// `n < n_min` — not enough cell samples yet.
    Cold,
    /// `s_cell > d_overdispersion·s_prior` — cell anomalously dispersed vs class.
    OverDispersed,
    /// `q95 + inner_band ≥ ceiling` — no upward headroom to discriminate.
    CeilingProximity,
}

/// The peak disposition — the `Value` channel of the UASB decision.
///
/// Deliberately self-contained (not the shared seasonal/capacity `Disposition`),
/// so adding peak disposition does not perturb the shared enum. The NIF ABI
/// mapping is a separate concern (a later task).
#[derive(Clone, Debug, PartialEq)]
pub enum PeakDisposition {
    /// Peak is within the (poison-bounded) normal range — silence it.
    Suppress,
    /// Elevated but not clearly novel — keep visible at lower severity.
    Downgrade { score: f64 },
    /// Clearly off-profile (either direction) — raise it.
    Escalate { score: f64 },
    /// Not eligible for suppression — pass through unchanged (edge-governed).
    PassThrough { reason: PassReason },
}
