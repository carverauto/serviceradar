// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The disposition Value channel and its configuration carriers.
//!
//! [`Disposition`] is the `Value` channel of every disposition `CausalFlow` (D4):
//! the only thing an intervene arm writes. Its `rustler` feature gate makes it the
//! typed NIF ABI directly (a `NifTaggedEnum`) without forcing a JSON string at the
//! boundary, while keeping the kernel crate rustler-free for bazel/tests.

pub mod seasonal;

/// The disposition a kernel assigns to the latest complete bucket under test.
///
/// This is the `Value` channel of the seasonal `CausalFlow` (design D4). It is the
/// *only* channel the intervene/breach arm writes, and it is the typed result the
/// NIF marshals back to the BEAM. Every gate — insufficient baseline, zero
/// variance, non-finite sample — resolves to one of these variants, **never** a
/// panic (graft #1), so a malformed input degrades to a value, not an FFI unwind.
///
/// With the crate's `rustler` feature on, this derives `NifTaggedEnum`, so on the
/// Elixir side a unit variant encodes as e.g. `:suppress` and a payload variant as
/// `{:seasonal_breach, %{score: 4.2}}`. That is the typed ABI the spec mandates in
/// place of a JSON string.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifTaggedEnum))]
pub enum Disposition {
    /// The bucket is within its seasonal baseline; withhold (no surface). Maps to
    /// the clean arm of the underlying `CausalFlow` branch.
    Suppress,
    /// The deseasonalized residual z cleared `seasonal_n_sigma` for the latest
    /// complete bucket. `score` is the residual z-score.
    SeasonalBreach { score: f64 },
    /// The residual cleared the breach threshold but has not yet met the
    /// confirm-slot hysteresis (carried `consecutive_anomalous`), so it is a
    /// pending drift rather than a confirmed breach. `score` is the residual z.
    SeasonalDrift { score: f64 },
    /// The matching `(dow,hod)` bucket has fewer than `min_bucket_samples`
    /// effective samples (after the latest-bucket exclusion, D6), so no verdict
    /// can be issued. The baseline-sufficiency gate, returned as a value.
    InsufficientSeasonalBaseline,
    /// A guard short-circuited the evaluation (zero-variance / non-finite sample /
    /// missing config / empty bucket). Carries a stable machine reason string.
    /// This is the error channel surfaced as a value (graft #1) — never a panic.
    Skipped { reason: String },
}

impl Disposition {
    /// Whether this disposition should surface upstream as an anomaly verdict.
    /// `Suppress` / `InsufficientSeasonalBaseline` / `Skipped` are withheld; only a
    /// confirmed `SeasonalBreach` surfaces. `SeasonalDrift` is pending and does not
    /// surface until confirmed (the worker carries `consecutive_anomalous`).
    pub fn surfaces(&self) -> bool {
        matches!(self, Disposition::SeasonalBreach { .. })
    }

    /// The residual z-score, when one was computed (`SeasonalBreach`/`SeasonalDrift`).
    pub fn score(&self) -> Option<f64> {
        match self {
            Disposition::SeasonalBreach { score } | Disposition::SeasonalDrift { score } => {
                Some(*score)
            }
            _ => None,
        }
    }
}

/// Robust-statistic selection for the seasonal residual (D6 / task 3.4).
///
/// `MeanStddev` is the default and consumes the per-bucket mean/stddev SQL already
/// aggregates. `MedianMad` and `P05P95` consume the per-bucket **order statistics**
/// SQL computes (`percentile_cont` / MAD via `percentile_disc` of abs-deviation),
/// keeping the boundary small: the kernel never sees raw points, only the per-bucket
/// summary statistics for the chosen estimator.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[cfg_attr(feature = "rustler", derive(rustler::NifUnitEnum))]
pub enum RobustStatistic {
    /// Mean / stddev z-score (default). Center = mean, scale = stddev.
    #[default]
    MeanStddev,
    /// Median / MAD (median absolute deviation). Center = median, scale = MAD
    /// rescaled to a stddev-equivalent by 1.4826 (the normal-consistency constant).
    MedianMad,
    /// p05–p95 inter-percentile band. Center = median, scale = (p95 − p05) mapped
    /// to a stddev-equivalent by the 90%-coverage normal constant (≈3.2897).
    P05P95,
}

/// 1.4826: rescales MAD to a stddev-equivalent under normality so the same
/// `n_sigma` threshold applies across robust statistics. `1 / Φ⁻¹(0.75)`.
pub(crate) const MAD_TO_STDDEV: f64 = 1.482_602_218_505_602;

/// ≈3.2897: maps a p05–p95 (90%-coverage) inter-percentile range to a
/// stddev-equivalent under normality. `1 / (Φ⁻¹(0.95) − Φ⁻¹(0.05))` =
/// `1 / (2 · 1.644853...)`, so the band width is divided by `2·1.644853`.
pub(crate) const P05P95_TO_STDDEV: f64 = 3.289_707_253_902_94;
